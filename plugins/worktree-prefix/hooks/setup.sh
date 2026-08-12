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

# Adds or repoints one event's entry. Only an entry whose command names this
# plugin's script is touched; hooks the user configured next to it are left
# alone.
sync_hook() {
  local event=$1 script=$2 status=$3
  local marker="worktree-prefix/hooks/$script"
  local command="bash \"$plugin_root/hooks/$script\""
  local actual updated

  actual=$(printf '%s' "$settings" | jq -r \
    --arg event "$event" --arg marker "$marker" \
    '[.hooks[$event][]?.hooks[]?.command // empty | select(contains($marker))] | .[0] // empty'
  ) || return 0
  [ "$actual" = "$command" ] && return 0

  updated=$(printf '%s' "$settings" | jq \
    --arg event "$event" --arg marker "$marker" \
    --arg command "$command" --arg status "$status" '
      def ours: (.command // "") | contains($marker);
      .hooks //= {}
      | .hooks[$event] //= []
      | if [.hooks[$event][]?.hooks[]? | select(ours)] | length == 0
        then .hooks[$event] += [{
          hooks: [{type: "command", command: $command, statusMessage: $status}]
        }]
        else (.hooks[$event][]?.hooks[]? | select(ours) | .command) = $command
        end
    ') || return 0

  settings=$updated
  if [ -n "$actual" ]; then
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
