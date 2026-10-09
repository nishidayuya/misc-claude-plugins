#!/usr/bin/env bash
# SessionStart hook: keep this plugin's WorktreeCreate/WorktreeRemove hooks
# registered in the user settings file.
#
# Two measurements on Claude Code 2.1.228 dictate where they have to live:
#
#   * `claude -w` creates its worktree ~20ms *before* "Loading hooks from plugin"
#     shows up in the debug log, for marketplace and --plugin-dir plugins alike,
#     so a WorktreeCreate hook shipped in this plugin's hooks.json never fires
#     for a `claude -w` launch. Hooks configured in settings.json are read early
#     enough.
#   * WorktreeRemove is only looked up in the user (and managed/CLI) settings; an
#     entry in a project's .claude/settings.json is ignored, which would remove
#     the worktree but leak its branch.
#
# So the entries go into the user settings file, and they are rewritten whenever
# they do not point at the current plugin root — a plugin update or a moved
# installation heals itself on the next session.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

plugin_root=${CLAUDE_PLUGIN_ROOT:-}
[ -n "$plugin_root" ] || exit 0

. "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

# Only write once this plugin is really installed: its own entry in
# enabledPlugins, or the `all` bundle that depends on it. Without one of those
# this is a --plugin-dir style session, where touching the user's settings would
# be a surprise.
enabled_here='
  .enabledPlugins // {}
  | to_entries
  | any(.value == true and ((.key | split("@") | .[0]) as $n
                           | $n == "worktree-prefix" or $n == "all"))
'

# The project root is the main checkout, so that a project-scoped installation is
# still found while the session runs inside a worktree.
project_root=$(wtp_repo_root "$PWD") || project_root=$PWD

config_dir=${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}
settings_file="$config_dir/settings.json"

enabled=false
for candidate in \
  "$project_root/.claude/settings.local.json" \
  "$project_root/.claude/settings.json" \
  "$settings_file"; do
  [ -f "$candidate" ] || continue
  jq -e "$enabled_here" "$candidate" >/dev/null 2>&1 || continue
  enabled=true
  break
done
"$enabled" || exit 0

if [ -f "$settings_file" ]; then
  settings=$(cat "$settings_file") || exit 0
else
  [ -d "$config_dir" ] || exit 0
  settings='{}'
fi
changes=

# Adds, repoints or deduplicates one event's entry. Only a hook whose command
# runs this plugin's script is touched; hooks the user configured next to it are
# left alone.
#
# The script is recognised under a `--plugin-dir` root
# (.../worktree-prefix/hooks/<script>) as well as under a marketplace cache
# root, which has a version directory in between
# (.../worktree-prefix/1.0.0/hooks/<script>). Matching only the former made
# every session append another copy.
sync_hook() {
  local event=$1 script=$2 status=$3
  local command="bash \"$plugin_root/hooks/$script\""
  local ours='def ours: (.command // "")
    | test("/worktree-prefix/([^/\"]+/)?hooks/" + ($script | gsub("\\."; "\\.")) + "\"$");'
  local actual count updated

  actual=$(printf '%s' "$settings" | jq -c \
    --arg event "$event" --arg script "$script" \
    "$ours"' [.hooks[$event][]?.hooks[]? | select(ours) | .command]'
  ) || return 0
  [ "$actual" = "$(jq -cn --arg command "$command" '[$command]')" ] && return 0
  count=$(printf '%s' "$actual" | jq 'length') || return 0

  # Drop every copy of our hook, then append exactly one. An entry left with no
  # hook at all is removed too, so stale copies do not linger as empty entries.
  updated=$(printf '%s' "$settings" | jq \
    --arg event "$event" --arg script "$script" \
    --arg command "$command" --arg status "$status" "$ours"'
      .hooks //= {}
      | .hooks[$event] = (
          [(.hooks[$event] // [])[]
           | .hooks |= map(select(ours | not))
           | select(.hooks | length > 0)]
          + [{hooks: [{type: "command", command: $command, statusMessage: $status}]}]
        )
    ') || return 0

  settings=$updated
  if [ "$count" -gt 1 ]; then
    changes="${changes:+$changes, }deduplicated $event"
  elif [ "$count" -eq 1 ]; then
    changes="${changes:+$changes, }repointed $event"
  else
    changes="${changes:+$changes, }added $event"
  fi
}

sync_hook WorktreeCreate worktree-create.sh 'Creating the worktree'
sync_hook WorktreeRemove worktree-remove.sh 'Removing the worktree'

[ -n "$changes" ] || exit 0

tmp=$(mktemp "$settings_file.tmp.XXXXXX") || exit 0
if printf '%s\n' "$settings" | jq '.' > "$tmp" && mv -- "$tmp" "$settings_file"; then
  jq -n --arg msg "worktree-prefix: $changes in $settings_file. \`claude -w\` creates its worktree before plugin hooks are registered, so these hooks cannot ship in the plugin itself; delete them from that file to uninstall." \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $msg}}'
else
  rm -f -- "$tmp"
  printf 'worktree-prefix: could not update %s\n' "$settings_file" >&2
  exit 1
fi
