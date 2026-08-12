#!/usr/bin/env bash
# Checks that the marketplace manifest and the plugins in this repository agree
# with each other:
#
#   * every JSON manifest parses;
#   * plugins/ and the marketplace plugin list hold the same names, so a new
#     plugin cannot be left out of either one;
#   * every marketplace entry points at an existing directory whose plugin.json
#     declares the same name;
#   * the `all` bundle plugin depends on every other plugin.
#
# Reports every problem it finds rather than stopping at the first one.
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
marketplace="$root/.claude-plugin/marketplace.json"
status=0

pass() { printf 'ok: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; status=1; }

# Every manifest has to parse before anything else can be trusted, so bail out
# instead of letting later checks report confusing follow-on errors.
invalid=()
while IFS= read -r file; do
  jq empty "$file" 2>/dev/null || invalid+=("${file#"$root"/}")
done < <(find "$root/.claude-plugin" "$root/plugins" -name '*.json' | sort)
if [ "${#invalid[@]}" -gt 0 ]; then
  for file in "${invalid[@]}"; do
    fail "not valid JSON: $file"
  done
  exit 1
fi
pass 'all JSON manifests parse'

listed=$(jq -r '.plugins[].name' "$marketplace" | sort)
present=$(for dir in "$root"/plugins/*/; do basename "$dir"; done | sort)
if [ "$listed" = "$present" ]; then
  pass 'plugins/ and marketplace.json list the same plugins'
else
  fail 'plugins/ and marketplace.json list different plugins:'
  diff -u --label 'marketplace.json' --label 'plugins/' \
    <(printf '%s\n' "$listed") <(printf '%s\n' "$present") >&2 || true
fi

entries_ok=true
while IFS=$'\t' read -r name source; do
  # Only relative paths point into this repository; a github or npm source has
  # nothing local to check.
  case "$source" in
    ./*) ;;
    *) continue ;;
  esac

  dir="$root/${source#./}"
  if [ ! -d "$dir" ]; then
    fail "$name: source directory does not exist: $source"
    entries_ok=false
    continue
  fi

  # The manifest itself is optional; Claude Code then derives the name from the
  # directory. Only check it when the plugin ships one.
  plugin_manifest="$dir/.claude-plugin/plugin.json"
  [ -f "$plugin_manifest" ] || continue

  declared=$(jq -r '.name // empty' "$plugin_manifest")
  if [ "$declared" != "$name" ]; then
    fail "$name: plugin.json declares the name \"$declared\""
    entries_ok=false
  fi
done < <(jq -r '.plugins[] | [.name, .source] | @tsv' "$marketplace")
if "$entries_ok"; then
  pass 'every marketplace entry matches its plugin'
fi

if "$root/script/sync-all-plugin-dependencies.sh" --check; then
  pass 'the `all` plugin depends on every other plugin'
else
  fail 'the `all` plugin dependency list is out of date'
fi

exit "$status"
