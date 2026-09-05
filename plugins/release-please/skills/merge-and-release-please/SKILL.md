---
name: merge-and-release-please
description: Merge a pull request, then watch the default branch until CI is green, and — when the repository releases with release-please — merge the release pull request the same way. Re-runs a failing CI run at most three times, and never edits anything to make it pass.
argument-hint: "[pull request URL or number]"
disable-model-invocation: true
allowed-tools:
  - Bash(gh pr view:*)
  - Bash(gh pr list:*)
  - Bash(gh pr checks:*)
  - Bash(gh pr diff:*)
  - Bash(gh repo view:*)
  - Bash(gh run list:*)
  - Bash(gh run view:*)
  - Bash(gh run watch:*)
  - Bash(gh release list:*)
  - Bash(git log:*)
  - Bash(git show:*)
  - Bash(git status:*)
  - Bash(git branch --show-current)
  - Bash(git rev-parse:*)
---

Merge a pull request and take the merge all the way through: the default branch
has to end up green, and when the repository releases with
[release-please](https://github.com/googleapis/release-please-action), the
release pull request it opens is merged the same way.

## Rules that hold for every step

* **Never edit anything to make CI pass.** Not the code, not the workflows, not
  the tests. A failure that survives the re-run budget is investigated and
  reported (step 5), and the repository is left exactly as it was.
* **Never merge past a check.** No `--admin`, no branch-protection bypass, no
  force push, and no direct push to the default branch.
* Anything not described here — reverting, closing a pull request, changing a
  repository setting — is something to ask about, not to do.
* Some `gh` subcommands fail with a GraphQL error about *Projects (classic)*
  being deprecated even though the operation itself is fine. When that happens,
  do the same thing through `gh api` and carry on.

## 1. Decide which pull request

`$ARGUMENTS`:

* **A pull request URL or number was given** — use it, no confirmation needed. A
  URL can name another repository, so derive `owner/repo` from it and pass
  `--repo <owner>/<repo>` to every `gh` call below when it is not the repository
  the session is in.
* **Nothing was given** — work out which pull request this session has been
  working on: what the conversation has been about, the current branch
  (`git branch --show-current`, then
  `gh pr list --head <branch> --state all --json number,title,state`), and
  `gh pr list --author @me --state open`. Then **ask the user to confirm that
  pull request before merging it**, naming its number and title. Never merge an
  unconfirmed guess. If nothing plausible turns up, ask which pull request to
  merge.

## 2. Merge it

`gh pr view <pr> --json state,merged,mergeable,mergeStateStatus,title,headRefName,baseRefName,url`

* Already merged? Say so and go to step 3 with its merge commit.
* `mergeable` is `CONFLICTING`, or the state is blocked by a required review:
  stop and report. Resolving that is not this command's job.

Then look at its checks with `gh pr checks <pr>`:

* Still running — wait for them (`gh pr checks <pr> --watch`, or watch the runs
  as in step 3).
* Red — **stop and report, without merging**. The re-run budget below is for the
  default branch, not for the pull request; merging a red pull request is the
  user's call.
* `action_required` — that is an approval gate, not a failure. Handle it as in
  step 3 and carry on.

Merge with the method the repository actually uses. What is allowed:

```
gh api repos/{owner}/{repo} --jq '{allow_merge_commit, allow_squash_merge, allow_rebase_merge}'
```

and `git log --merges --oneline -5 origin/<default branch>` says what the history
looks like. Prefer a merge commit when both allow it.

```
gh pr merge <pr> --merge      # or --squash / --rebase
```

`gh pr merge` can exit quietly, so confirm it landed and pick up the merge
commit:

```
gh api repos/{owner}/{repo}/pulls/<n> --jq '{merged, merge_commit_sha}'
```

Do not delete the branch unless the user asks. If `gh pr merge` fails with the
Projects (classic) error, merge with
`gh api -X PUT repos/{owner}/{repo}/pulls/<n>/merge -f merge_method=merge`.

## 3. Get the default branch green

The default branch comes from
`gh repo view --json defaultBranchRef -q .defaultBranchRef.name`. The commit to
watch is the merge commit from step 2.

List what the push started — every workflow, not only the one called `CI`:

```
gh run list --branch <default branch> --limit 10 \
  --json databaseId,name,status,conclusion,headSha
```

Filter it to the merge commit's `headSha`. Runs take a few seconds to appear, so
look again once or twice before concluding that the push started nothing. A push
that genuinely starts no workflow is a pass — say so rather than waiting.

Watch each run to completion:

```
gh run watch <run id> --exit-status --interval 10
```

Then, per run:

* **`success`** — done.
* **`action_required`** — the run is waiting for a maintainer to approve it, not
  failing. Approve it and keep watching. **This does not use the re-run budget.**

  ```
  gh api -X POST repos/{owner}/{repo}/actions/runs/<run id>/approve
  ```

* **`failure`, `cancelled`, `timed_out`** — re-run it:

  ```
  gh run rerun <run id> --failed     # `gh run rerun <run id>` when nothing is marked failed
  ```

  and watch it again. **At most three re-runs per run**; the automatic run that
  the push started is not one of them. Say which attempt is running each time.

Once every run for that commit is green, go to step 4. If a run is still red
after its third re-run, stop and go to step 5.

## 4. The release-please pull request

Only when step 3 came out green.

Does this repository use release-please? It does when it has
`release-please-config.json` or `.release-please-manifest.json`, or a workflow
that uses `googleapis/release-please-action`. If it does not, report the result
of step 3 and stop — that is a complete, successful run of this command.

The release pull request is opened or updated by the `release-please` workflow
run that step 3 already waited for, so it exists by now. Find it among the open
pull requests: its head branch is `release-please--branches--<default branch>`
and its title looks like `chore(main): release 1.2.3`.

```
gh pr list --state open --json number,title,headRefName,author
```

No such pull request? That is not a failure. Report which of these it is and
stop:

* nothing releasable landed — release-please only proposes a release for
  user-facing commits, so a merge of `chore:`, `ci:`, `docs:`, `test:` or
  `refactor:` work alone leaves no pull request;
* the workflow ran but could not open one, usually because *Allow GitHub Actions
  to create and approve pull requests* is off — the run log says
  `GitHub Actions is not permitted to create or approve pull requests`.

When it is there, its checks get the same treatment the default branch gets in
step 3, not the stricter reading of step 2: approve a run that sits at
`action_required`, re-run a failing one at most three times, and merge only once
they are green. A failure that survives the budget goes to step 5, and the
release pull request stays open.

Two things to expect here. A pull request opened by the bot's `GITHUB_TOKEN`
frequently has its checks sitting at `action_required`, and sometimes has none at
all — when there are genuinely no check runs and none are required, say so and
merge. And the checks live on the pull request, so
`gh run list --branch release-please--branches--<default branch>` is where the
runs are, rather than on the default branch.

Merge it the way step 2 merges.

After merging it, watch the default branch once more with the rules of step 3 —
the merge pushes another commit — and confirm the release exists:

```
gh release list --limit 3
```

## 5. When CI stays red

Three re-runs and still failing means the command stops changing things and
starts explaining. **Fix nothing.** Investigate and report:

* which run, which job and which step failed — `gh run view <run id> --log-failed`,
  or `gh run view <run id> --json jobs` for the shape of it;
* whether every attempt failed the same way. Identical failures point at the
  merged change; failures that move around point at flakiness or at the runner;
* what the failing command actually says — quote the few lines that matter
  rather than the whole log;
* whether the merged change plausibly caused it, and what a fix would have to
  touch — `git show --stat <merge commit>` when the repository is the one checked
  out, `gh pr diff <pr>` otherwise.

Then say plainly that the default branch is red and nothing was changed, and — if
this happened in step 4 — that the release pull request is still open.

## 6. Report

* the pull request that was merged: number, title, merge commit;
* the default branch runs: which workflows, and how many approvals and re-runs
  each one needed;
* the release pull request: merged (with its number and the release created), or
  why there was none, or why it was left open;
* anything still needing a person: a red run, a repository setting, a pull
  request that could not be merged.
