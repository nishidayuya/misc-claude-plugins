#!/usr/bin/env bash
# Stop hook: write Claude's final response text to ~/.claude/last_response.txt
# (always overwritten), followed by the turn duration line the UI shows.
#
# Input: hook JSON on stdin, including .transcript_path (a JSONL file).
#
# Caveat: the spinner verb the UI picks ("Churned", "Cooked", ...) is chosen at
# render time and never recorded in the transcript, so it cannot be reproduced.
# Override the word with LAST_RESPONSE_VERB; set LAST_RESPONSE_VERB="" to drop
# the duration line entirely. LAST_RESPONSE_HEADING_SHIFT controls how many
# levels every Markdown heading is pushed down (0 disables the rewrite).
set -u

out="$HOME/.claude/last_response.txt"
verb="${LAST_RESPONSE_VERB-Cooked}"
hshift="${LAST_RESPONSE_HEADING_SHIFT-2}"

input=$(cat)
tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ -z "$tp" ] || [ ! -f "$tp" ] && exit 0

# Selects the last main-thread assistant entry that actually contains text,
# skipping trailing tool_use entries and subagent output.
read -r -d '' LASTTEXT <<'JQ' || true
def lasttext:
  [ .[]
    | select(.type=="assistant"
             and (.isSidechain != true)
             and (.message.content|type=="array")
             and (.message.content|any(.type=="text"))) ]
  | last;
JQ

# Pushes every ATX heading down by `shift` levels, clamped at 6. Fenced code
# blocks are tracked so that shell comments inside them are left alone; indented
# code blocks are safe already, since a heading must start at column 1.
read -r -d '' SHIFT_HEADINGS <<'AWK' || true
BEGIN { infence = 0; fch = "" }
{
  if (match($0, /^[ ]*(```|~~~)/)) {
    m = substr($0, RSTART, RLENGTH)
    ch = substr(m, length(m), 1)
    if (!infence) { infence = 1; fch = ch }
    else if (ch == fch) { infence = 0 }
    print; next
  }
  if (!infence && shift > 0 && match($0, /^#+([ \t]|$)/)) {
    n = 0
    while (substr($0, n + 1, 1) == "#") n++
    if (n <= 6) {
      lvl = n + shift
      if (lvl > 6) lvl = 6
      pre = ""
      while (length(pre) < lvl) pre = pre "#"
      print pre substr($0, n + 1)
      next
    }
  }
  print
}
AWK

# The hook starts before Claude Code has flushed the final response to the
# transcript, so without waiting we would read the *previous* response. Poll
# until the last main-thread assistant entry carries a text block (up to ~5s).
for _ in $(seq 1 50); do
  ready=$(jq -rs '
    [ .[] | select(.type=="assistant" and (.isSidechain != true)) ]
    | last
    | (.message.content // [])
    | if type=="array" then any(.type=="text") else false end
  ' "$tp" 2>/dev/null)
  [ "$ready" = "true" ] && break
  sleep 0.1
done

msg=$(jq -rs "$LASTTEXT"'
  lasttext
  | .message.content
  | map(select(.type=="text") | .text)
  | join("\n")
' "$tp" 2>/dev/null)
[ -z "$msg" ] && exit 0

# The turn_duration entry lands right after the final response (~100ms later),
# so give it a moment. Only accept one newer than the response itself, or we
# would report the *previous* turn's duration.
ms=""
if [ -n "$verb" ]; then
  for _ in $(seq 1 20); do
    ms=$(jq -rs "$LASTTEXT"'
      (lasttext | .timestamp) as $ts
      | [ .[] | select(.type=="system"
                       and .subtype=="turn_duration"
                       and .timestamp > $ts) ]
      | last | .durationMs // empty
    ' "$tp" 2>/dev/null)
    [ -n "$ms" ] && break
    sleep 0.1
  done
fi

{
  printf '%s\n' "$msg" | awk -v shift="$hshift" "$SHIFT_HEADINGS"
  if [ -n "$ms" ]; then
    total=$(( (${ms%%.*} + 500) / 1000 ))
    h=$(( total / 3600 )); m=$(( total % 3600 / 60 )); s=$(( total % 60 ))
    if   [ "$h" -gt 0 ]; then d=$(printf '%dh %dm %ds' "$h" "$m" "$s")
    elif [ "$m" -gt 0 ]; then d=$(printf '%dm %ds' "$m" "$s")
    else                      d=$(printf '%ds' "$s")
    fi
    printf '\n✻ %s for %s\n' "$verb" "$d"
  fi
} > "$out"
exit 0
