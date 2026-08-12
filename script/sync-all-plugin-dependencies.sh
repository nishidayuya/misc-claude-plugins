#!/usr/bin/env bash
# Regenerates the `dependencies` array of the `all` bundle plugin from the
# plugin list in .claude-plugin/marketplace.json, so that installing
# `all@misc` pulls in every other plugin of this marketplace.
#
# There is no way to declare "depend on everything" in a plugin manifest, so the
# list has to be written out. This script keeps it in sync instead.
#
# Usage:
#   script/sync-all-plugin-dependencies.sh           # rewrite the manifest
#   script/sync-all-plugin-dependencies.sh --check   # exit 1 when out of date
set -euo pipefail

check=false
case "${1-}" in
  --check) check=true ;;
  "") ;;
  *) printf 'usage: %s [--check]\n' "$(basename "$0")" >&2; exit 2 ;;
esac

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
marketplace="$root/.claude-plugin/marketplace.json"
manifest="$root/plugins/all/.claude-plugin/plugin.json"

# Sorted so that the generated list does not depend on the marketplace order.
deps=$(jq '[.plugins[].name] - ["all"] | sort' "$marketplace")
generated=$(jq --argjson deps "$deps" '.dependencies = $deps' "$manifest")

if "$check"; then
  if printf '%s\n' "$generated" | diff -q "$manifest" - >/dev/null; then
    exit 0
  fi
  printf '%s\n' "$generated" \
    | diff -u --label 'plugins/all/.claude-plugin/plugin.json' \
              --label 'expected' "$manifest" - >&2 || true
  printf 'the `all` plugin is out of date; run %s\n' \
    'script/sync-all-plugin-dependencies.sh' >&2
  exit 1
fi

printf '%s\n' "$generated" > "$manifest"
