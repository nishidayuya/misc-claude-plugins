#!/usr/bin/env bash
# WorktreeRemove hook: remove a worktree created by worktree-create.sh, together
# with its branch.
#
# Claude Code only knows the branch of a worktree it created itself, so after a
# hook-based creation its own fallback (`git worktree remove`) would leave the
# branch behind. This hook deletes it, but only when the branch is exactly the
# one worktree-create.sh would have made for that directory.
#
# Input: hook JSON on stdin, with .worktree_path.
# Exiting non-zero tells Claude Code the worktree was not removed, which makes it
# keep the directory instead of guessing.
set -uo pipefail

. "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

input=$(cat)
path=$(printf '%s' "$input" | jq -r '.worktree_path // empty') \
  || wtp_die 'cannot parse the hook input (is jq installed?)'
[ -n "$path" ] || wtp_die 'the hook input carries no worktree path'
[ -d "$path" ] || wtp_die "not a directory: $path"

root=$(wtp_repo_root "$path") || wtp_die "not a git repository: $path"

# Only ever touch worktrees where this plugin puts them.
path_real=$(wtp_realpath "$path") || wtp_die "cannot resolve $path"
worktrees_dir_real=$(wtp_realpath "$root/.claude/worktrees") \
  || wtp_die "$root/.claude/worktrees does not exist"
[ "$(dirname -- "$path_real")" = "$worktrees_dir_real" ] \
  || wtp_die "refusing to remove $path: it is not under $worktrees_dir_real"

# Read the branch before the worktree goes away, and only delete it when it is
# the one this plugin would have created for this directory.
branch=$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null)
expected="$(wtp_prefix "$root")$(basename -- "$path_real")"

git -C "$root" worktree remove --force "$path" >&2 \
  || wtp_die "git worktree remove failed for $path"

if [ -n "$branch" ] && [ "$branch" = "$expected" ]; then
  git -C "$root" branch -D --end-of-options "$branch" >&2 \
    || printf 'worktree-prefix: could not delete branch %s\n' "$branch" >&2
fi

printf 'Removed worktree at: %s\n' "$path" >&2
