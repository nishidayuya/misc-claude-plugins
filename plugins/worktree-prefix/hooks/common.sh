#!/usr/bin/env bash
# Shared helpers for the worktree-prefix hooks. Both hooks have to agree on the
# branch name: the create hook writes it, and the remove hook only deletes a
# branch that it can recompute from the worktree directory.
#
# Sourced, never executed.

wtp_die() {
  printf 'worktree-prefix: %s\n' "$1" >&2
  exit 1
}

# Absolute physical path of $1, which has to exist.
wtp_realpath() {
  (cd -- "$1" >/dev/null 2>&1 && pwd -P)
}

# Root of the *main* checkout of the repository $1 belongs to. --git-common-dir
# points at the main checkout's .git even when the session was launched from
# inside another worktree, which is where both the worktrees and the branches
# belong.
wtp_repo_root() {
  local dir=$1 common parent top
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  parent=$(dirname -- "$common")
  # With a separate git directory the parent of .git is not the checkout root,
  # so let git have the last word and only fall back to the parent itself.
  top=$(git -C "$parent" rev-parse --path-format=absolute --show-toplevel 2>/dev/null)
  printf '%s\n' "${top:-$parent}"
}

# The configured branch prefix of the repository rooted at $1, "worktree-" when
# unset. An empty value is honoured and means "no prefix at all".
wtp_prefix() {
  git -C "$1" config --get miscClaudePlugins.worktreePrefix || printf '%s' worktree-
}

# The directory name Claude Code uses for the worktree named $1. Slashes are not
# path separators here, exactly like in the built-in implementation.
wtp_dir_name() {
  printf '%s\n' "${1//\//+}"
}
