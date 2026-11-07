#!/usr/bin/env bash
# The deterministic half of /pr-ci: one iteration of watching the CI of every
# commit of a GitHub pull request or a GitLab merge request, and the clean-up
# that ends the watch.
#
#   pr-ci.sh step    [--data-dir <dir>] <pull request or merge request URL>
#   pr-ci.sh cleanup [--data-dir <dir>] [--delete] <URL>
#
# step
#   1. Looks at every temporary branch pr-ci/<number>/<sha> on the remote. One
#      whose CI has finished is deleted; one on which no CI started within
#      PR_CI_TRIGGER_TIMEOUT seconds (default 600) is deleted and given up on.
#   2. Works out the CI state of every commit of the pull request. A commit that
#      is not the head and has no CI at all, or whose CI was cancelled, gets a
#      temporary branch pointing at it, pushed so that CI runs on it. A commit is
#      pushed at most PR_CI_MAX_ATTEMPTS times (default 3).
#   3. Prints a JSON report of the pull request, every commit and every action.
#
# cleanup
#   Lists the temporary branches of the pull request; with --delete, deletes
#   them.
#
# Only GitHub Actions workflow runs (GitHub) and pipelines (GitLab) count as CI.
# Pushing goes through HTTPS with the credential helper of gh or glab, from a
# bare, blob-less cache repository under the data directory, so the repository
# the session is in is never touched.
#
# What has been pushed is recorded in the git config of that cache repository:
#   prci.<branch>.attempts  how many times the commit was pushed
#   prci.<branch>.pushedat  when it was pushed last (epoch seconds)
#   prci.<branch>.outcome   pending | done | cancelled | untriggered
set -euo pipefail

readonly branch_root=pr-ci
max_attempts=${PR_CI_MAX_ATTEMPTS:-3}
trigger_timeout=${PR_CI_TRIGGER_TIMEOUT:-600}

die() {
  printf 'pr-ci: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '6,7p' "$0" | sed 's/^# //' >&2
  exit 2
}

# Sets forge, host, project, number, encoded_project, git_url and head_ref.
parse_url() {
  local url=${1%%[?#]*} rest
  case "$url" in
    https://*) ;;
    *) die "not an https URL: $1" ;;
  esac
  rest=${url#https://}
  host=${rest%%/*}
  rest=${rest#*/}
  if [[ "$rest" =~ ^(.+)/-/merge_requests/([0-9]+)(/.*)?$ ]]; then
    forge=gitlab
    head_ref_prefix=refs/merge-requests
  elif [[ "$rest" =~ ^([^/]+/[^/]+)/pull/([0-9]+)(/.*)?$ ]]; then
    forge=github
    head_ref_prefix=refs/pull
  else
    die "neither a pull request nor a merge request URL: $1"
  fi
  project=${BASH_REMATCH[1]}
  number=${BASH_REMATCH[2]}
  encoded_project=$(jq -rn --arg p "$project" '$p | @uri')
  git_url="https://$host/$project.git"
  head_ref="$head_ref_prefix/$number/head"
  branch_prefix="$branch_root/$number/"
}

api() {
  case "$forge" in
    github) gh api --hostname "$host" "$@" ;;
    gitlab) glab api --hostname "$host" "$@" ;;
  esac
}

# Every page of a list endpoint, as one JSON array.
api_all() {
  api --paginate "$@" | jq -s 'add // []'
}

# {state: open|merged|closed, head: <sha>, commits: [{sha, subject}]}, the
# commits oldest first.
fetch_pull_request() {
  local pr commits
  case "$forge" in
    github)
      pr=$(api "repos/$project/pulls/$number" |
        jq '{state: (if .merged then "merged" else .state end), head: .head.sha}')
      commits=$(api_all "repos/$project/pulls/$number/commits?per_page=100" |
        jq 'map({sha, subject: (.commit.message | split("\n")[0])})')
      ;;
    gitlab)
      pr=$(api "projects/$encoded_project/merge_requests/$number" |
        jq '{state: ({"opened": "open", "merged": "merged"}[.state] // "closed"), head: .sha}')
      commits=$(api_all "projects/$encoded_project/merge_requests/$number/commits?per_page=100" |
        jq 'map({sha: .id, subject: .title}) | reverse')
      ;;
  esac
  jq -n --argjson pr "$pr" --argjson commits "$commits" '$pr + {commits: $commits}'
}

# Every CI run of a commit as [{id, workflow, name, ref, url, status, conclusion}].
# status is pending or completed. conclusion is success, skipped, failure,
# cancelled, action_required, manual or other, and null while pending.
fetch_runs() {
  local sha=$1
  case "$forge" in
    github)
      # Each page is an object holding a page of workflow_runs, not an array.
      api --paginate "repos/$project/actions/runs?head_sha=$sha&per_page=100" |
        jq -s 'map(.workflow_runs[]) | map({
          id, workflow: (.workflow_id | tostring), name, ref: .head_branch, url: .html_url,
          status: (if .status == "completed" then "completed" else "pending" end),
          conclusion: (if .status != "completed" then null else ({
            success: "success", neutral: "success", skipped: "skipped",
            failure: "failure", timed_out: "failure", startup_failure: "failure",
            cancelled: "cancelled", stale: "cancelled",
            action_required: "action_required"
          }[.conclusion] // "other") end)
        })'
      ;;
    gitlab)
      api_all "projects/$encoded_project/pipelines?sha=$sha&per_page=100" |
        jq 'map({
          id, workflow: "pipeline", name: "pipeline #\(.id)", ref, url: .web_url,
          status: (if .status | IN("success", "failed", "canceled", "skipped", "manual")
            then "completed" else "pending" end),
          conclusion: ({
            success: "success", skipped: "skipped", failed: "failure",
            canceled: "cancelled", manual: "manual"
          }[.status])
        })'
      ;;
  esac
}

# The newest run of every workflow, and the verdict over them.
readonly jq_defs='
  def latest: group_by(.workflow) | map(max_by(.id));
  def verdict:
    if length == 0 then "none"
    elif any(.status == "pending") then "pending"
    else map(.conclusion) as $c
      | ["cancelled", "failure", "action_required", "manual", "other"]
      | map(select(IN($c[]))) | first // "success"
    end;
'

list_branches() {
  case "$forge" in
    github)
      api_all "repos/$project/git/matching-refs/heads/$branch_prefix" |
        jq -r '.[].ref | ltrimstr("refs/heads/")'
      ;;
    gitlab)
      api_all "projects/$encoded_project/repository/branches?search=%5E$(jq -rn --arg p "$branch_prefix" '$p | @uri')&per_page=100" |
        jq -r '.[].name'
      ;;
  esac | grep -E "^${branch_prefix}[0-9a-f]{40}\$" || true
}

delete_branch() {
  local branch=$1
  case "$forge" in
    github) api -X DELETE "repos/$project/git/refs/heads/$branch" >/dev/null ;;
    gitlab)
      api -X DELETE "projects/$encoded_project/repository/branches/$(jq -rn --arg b "$branch" '$b | @uri')" >/dev/null
      ;;
  esac
}

# The cache repository and its state.
open_cache() {
  cache="$data_dir/repositories/$host/$project.git"
  [ -d "$cache" ] && return
  mkdir -p "$cache"
  git init --bare --quiet "$cache"
  git -C "$cache" remote add origin "$git_url"
}

state_get() {
  git -C "$cache" config --get "prci.$1.$2" || true
}

state_set() {
  git -C "$cache" config "prci.$1.$2" "$3"
}

git_remote() {
  local helper
  case "$forge" in
    github) helper='!gh auth git-credential' ;;
    gitlab) helper='!glab auth git-credential' ;;
  esac
  git -C "$cache" -c credential.helper= -c "credential.helper=$helper" "$@"
}

push_branches() {
  local refspecs=() sha
  for sha in "$@"; do
    refspecs+=("$sha:refs/heads/$branch_prefix$sha")
  done
  git_remote fetch --quiet --filter=blob:none origin "+$head_ref:refs/pr-ci/$number/head"
  git_remote push --quiet origin "${refspecs[@]}"
}

cmd_step() {
  local now pr pr_state head_sha sha runs branch temp verdict outcome attempts pushed_at
  local -A runs_of=() branch_result=() deleted=()
  local branch_reports=() commit_reports=() to_push=()

  now=$(date +%s)
  open_cache
  pr=$(fetch_pull_request)
  pr_state=$(jq -r .state <<<"$pr")
  head_sha=$(jq -r .head <<<"$pr")

  runs_for() {
    [ -n "${runs_of[$1]:-}" ] || runs_of[$1]=$(fetch_runs "$1")
    printf '%s' "${runs_of[$1]}"
  }

  # 1. Temporary branches already on the remote.
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    sha=${branch##*/}
    temp=$(runs_for "$sha" | jq --arg b "$branch" "$jq_defs"'map(select(.ref == $b)) | latest')
    verdict=$(jq -r "$jq_defs"'verdict' <<<"$temp")
    if [ "$verdict" = none ]; then
      pushed_at=$(state_get "$branch" pushedat)
      if [ -z "$pushed_at" ]; then
        pushed_at=$now
        state_set "$branch" pushedat "$now"
      fi
      if [ $((now - pushed_at)) -lt "$trigger_timeout" ]; then
        branch_result[$sha]=waiting
      else
        delete_branch "$branch"
        state_set "$branch" outcome untriggered
        deleted[$sha]=1
        branch_result[$sha]=untriggered
      fi
    elif [ "$verdict" = pending ]; then
      branch_result[$sha]=running
    else
      delete_branch "$branch"
      if [ "$verdict" = cancelled ]; then
        state_set "$branch" outcome cancelled
      else
        state_set "$branch" outcome done
      fi
      deleted[$sha]=1
      branch_result[$sha]=finished
    fi
    branch_reports+=("$(jq -n --arg name "$branch" --arg sha "$sha" \
      --arg result "${branch_result[$sha]}" --argjson runs "$temp" \
      '{name: $name, sha: $sha, result: $result, deleted: ($result | IN("finished", "untriggered")), runs: $runs}')")
  done < <(list_branches)

  # 2. Every commit of the pull request.
  local head_verdict
  head_verdict=$(runs_for "$head_sha" | jq -r "$jq_defs"'latest | verdict')
  local commit subject is_head reason note
  while IFS= read -r commit; do
    sha=$(jq -r .sha <<<"$commit")
    subject=$(jq -r .subject <<<"$commit")
    is_head=false
    [ "$sha" = "$head_sha" ] && is_head=true
    runs=$(runs_for "$sha" | jq "$jq_defs"'latest')
    verdict=$(jq -r "$jq_defs"'verdict' <<<"$runs")
    branch="$branch_prefix$sha"
    reason=
    note=

    if [ "$verdict" = cancelled ]; then
      reason=cancelled
    elif [ "$verdict" = none ] && ! "$is_head" && [ "$head_verdict" != none ]; then
      reason=no_ci
    fi

    if [ -z "$reason" ]; then
      :
    elif [ "$pr_state" != open ]; then
      note=pull_request_not_open
    elif [ -n "${branch_result[$sha]:-}" ]; then
      # Waiting on a branch, or a branch deleted just now: the next step decides.
      note=branch_${branch_result[$sha]}
    else
      outcome=$(state_get "$branch" outcome)
      attempts=$(state_get "$branch" attempts)
      attempts=${attempts:-0}
      if [ "$outcome" = untriggered ]; then
        note=untriggered
      elif [ "$outcome" = done ]; then
        note=not_covered_by_push
      elif [ "$attempts" -ge "$max_attempts" ]; then
        note=attempts_exhausted
      else
        to_push+=("$sha")
        note=push
      fi
    fi

    commit_reports+=("$(jq -n --arg sha "$sha" --arg subject "$subject" \
      --argjson head "$is_head" --arg ci "$verdict" --argjson runs "$runs" \
      --arg reason "$reason" --arg note "$note" \
      '{sha: $sha, short: $sha[0:7], subject: $subject, head: $head, ci: $ci,
        runs: ($runs | map({name, ref, status, conclusion, url})),
        needs_rerun: (if $reason == "" then null else $reason end),
        action: (if $note == "" then null else $note end)}')")
  done < <(jq -c '.commits[]' <<<"$pr")

  # 3. Push what needs CI, in one push.
  if [ "${#to_push[@]}" -gt 0 ]; then
    push_branches "${to_push[@]}"
    for sha in "${to_push[@]}"; do
      branch="$branch_prefix$sha"
      attempts=$(state_get "$branch" attempts)
      state_set "$branch" attempts $((${attempts:-0} + 1))
      state_set "$branch" pushedat "$now"
      state_set "$branch" outcome pending
    done
  fi

  local pushed_json
  pushed_json=$(printf '%s\n' "${to_push[@]}" | jq -R 'select(. != "")' | jq -s --arg p "$branch_prefix" 'map({sha: ., branch: ($p + .)})')
  jq -n --arg url "$url" --arg forge "$forge" --arg project "$project" \
    --argjson number "$number" --arg state "$pr_state" --arg head "$head_sha" \
    --argjson commits "$(printf '%s\n' "${commit_reports[@]}" | jq -s .)" \
    --argjson branches "$(printf '%s\n' "${branch_reports[@]}" | jq -s 'map(select(. != null))')" \
    --argjson pushed "$pushed_json" \
    '{url: $url, forge: $forge, project: $project, number: $number, state: $state, head: $head,
      commits: $commits, branches: $branches, pushed: $pushed,
      settled: (($commits | all(.ci != "pending")) and ($branches | all(.deleted)) and ($pushed | length == 0))}'
}

cmd_cleanup() {
  local delete=$1 branch reports=()
  open_cache
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    if "$delete"; then
      delete_branch "$branch"
      state_set "$branch" outcome cancelled
    fi
    reports+=("$(jq -n --arg name "$branch" --argjson deleted "$delete" \
      '{name: $name, sha: ($name | split("/") | last), deleted: $deleted}')")
  done < <(list_branches)
  jq -n --arg url "$url" --argjson branches "$(printf '%s\n' "${reports[@]}" | jq -s 'map(select(. != null))')" \
    '{url: $url, branches: $branches}'
}

main() {
  local command=${1:-}
  [ -n "$command" ] || usage
  shift
  data_dir=${XDG_CACHE_HOME:-$HOME/.cache}/misc-claude-plugins/pr-ci
  local delete=false
  url=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --data-dir) data_dir=${2:?--data-dir needs a directory}; shift 2 ;;
      --delete) delete=true; shift ;;
      -*) usage ;;
      *) [ -z "$url" ] || usage; url=$1; shift ;;
    esac
  done
  [ -n "$url" ] || usage
  parse_url "$url"

  case "$command" in
    step) cmd_step ;;
    cleanup) cmd_cleanup "$delete" ;;
    *) usage ;;
  esac
}

main "$@"
