#!/usr/bin/env bash
# WorktreeCreate hook: create the worktree that `claude -w`, EnterWorktree and
# worktree-isolated agents ask for, but on a branch named
# "<miscClaudePlugins.worktreePrefix><worktree name>" instead of the built-in
# "worktree-<worktree name>".
#
# Configuring any WorktreeCreate hook makes Claude Code hand the whole creation
# over to it, so this script reproduces the parts of the built-in behaviour that
# matter: the same .claude/worktrees/<name> location, the same
# origin/<default branch> base, and resuming a worktree that is already there.
# See the plugin section in README.md for what is deliberately left out.
#
# Input: hook JSON on stdin, with .name (already validated by Claude Code) and
# .cwd.
# Output: the absolute path of the worktree directory. Claude Code reads the last
# non-empty line of stdout, so everything else goes to stderr.
set -uo pipefail

. "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

input=$(cat)
name=$(printf '%s' "$input" | jq -r '.name // empty') \
  || wtp_die 'cannot parse the hook input (is jq installed?)'
[ -n "$name" ] || wtp_die 'the hook input carries no worktree name'

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd=$PWD

root=$(wtp_repo_root "$cwd") || wtp_die \
  "not a git repository: $cwd. Disable the worktree-prefix plugin to use worktrees outside git."

dir_name=$(wtp_dir_name "$name")
# Claude Code validates the name before running the hook; check again, because
# the name ends up in both a path and a ref.
case $dir_name in
  "" | .* | *..* | *[!A-Za-z0-9._+-]*) wtp_die "invalid worktree name: $name" ;;
esac

prefix=$(wtp_prefix "$root")
branch="$prefix$dir_name"
case $branch in
  -*) wtp_die "invalid branch prefix \"$prefix\": a branch name must not start with a dash" ;;
esac
git check-ref-format "refs/heads/$branch" \
  || wtp_die "invalid branch prefix \"$prefix\": \"$branch\" is not a valid branch name"

worktrees_dir="$root/.claude/worktrees"
dir="$worktrees_dir/$dir_name"

# Resuming: the worktree is already registered, so hand back its path the way the
# built-in implementation does. Its branch is whatever it was created with, which
# may predate a change of the prefix.
if [ -e "$dir" ]; then
  top=$(git -C "$dir" rev-parse --path-format=absolute --show-toplevel 2>/dev/null)
  if [ -n "$top" ] && [ "$(wtp_realpath "$top")" = "$(wtp_realpath "$dir")" ]; then
    printf 'Resuming existing worktree at: %s\n' "$dir" >&2
    printf '%s\n' "$dir"
    exit 0
  fi
  wtp_die "$dir already exists but is not a worktree of $root. Remove it, or pass a different worktree name."
fi

# Base ref. "auto" mirrors Claude Code's default (`worktree.baseRef: fresh`):
# branch off origin/<default branch>, refreshed once. "head" branches off the
# local HEAD; anything else is used as a ref verbatim.
base_ref=$(git -C "$root" config --get miscClaudePlugins.worktreeBaseRef || printf '%s' auto)
case $base_ref in
  "" | auto)
    base=HEAD
    default_branch=$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
    default_branch=${default_branch#origin/}
    if [ -n "$default_branch" ]; then
      # Best effort: a stale origin/<default branch> is still a better base than
      # a local HEAD that may sit on an unrelated branch. Never prompt.
      GIT_TERMINAL_PROMPT=0 git -C "$root" fetch --quiet origin "$default_branch" \
        </dev/null >&2 \
        || printf 'worktree-prefix: fetch of origin/%s failed; using what is already fetched\n' \
             "$default_branch" >&2
      git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$default_branch" >/dev/null \
        && base="origin/$default_branch"
    fi
    ;;
  head | HEAD) base=HEAD ;;
  *) base=$base_ref ;;
esac

mkdir -p -- "$worktrees_dir" || wtp_die "cannot create $worktrees_dir"

# --no-track and -B match the built-in implementation: the branch is (re)pointed
# at the base and does not become a tracking branch of it. core.fsmonitor is
# cleared because a repository-configured monitor would be started in a
# directory that does not exist yet.
git -C "$root" -c core.fsmonitor= worktree add --no-track -B "$branch" "$dir" "$base" >&2 \
  || wtp_die "git worktree add failed for branch \"$branch\" at $dir"

printf 'Created worktree at: %s on branch: %s\n' "$dir" "$branch" >&2
printf '%s\n' "$dir"
