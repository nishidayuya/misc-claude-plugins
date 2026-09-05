#!/usr/bin/env bash
# Stop hook: write the turn to ~/.claude/last_responses/<session id>_<nnn>.md,
# one file per Stop, with <nnn> a zero padded 3 digit counter that starts at 001
# for every session: the prompt the human typed as a level 3 heading, then every
# AskUserQuestion of the turn with the answer that came back, then Claude's final
# response text, then the turn duration line the UI shows.
# ~/.claude/last_responses/<session id>.md is a relative symlink to the newest
# turn of that session, and ~/.claude/last_responses/last.md a relative symlink
# to the <session id>.md of the session that stopped most recently.
#
# Input: hook JSON on stdin, including .session_id and .transcript_path (a JSONL
# file).
#
# Caveat: the spinner verb the UI picks ("Churned", "Cooked", ...) is chosen at
# render time and never recorded in the transcript, so it cannot be reproduced.
# Override the word with LAST_RESPONSE_VERB; set LAST_RESPONSE_VERB="" to drop
# the duration line entirely. LAST_RESPONSE_HEADING_SHIFT controls how many
# levels every Markdown heading of the response is pushed down (0 disables the
# rewrite); the prompt heading is always level 3 and is never shifted.
set -u

dir="$HOME/.claude/last_responses"
verb="${LAST_RESPONSE_VERB-Cooked}"
hshift="${LAST_RESPONSE_HEADING_SHIFT-2}"

input=$(cat)
tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ -z "$tp" ] || [ ! -f "$tp" ] && exit 0

# Session ids are uuids; anything else would be a path traversal waiting to
# happen, so fall back to the transcript's basename and then to a fixed name.
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
case "$sid" in
  "" | *[!A-Za-z0-9._-]* | .*) sid=$(basename "$tp" .jsonl) ;;
esac
case "$sid" in
  "" | *[!A-Za-z0-9._-]* | .*) sid=unknown ;;
esac

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

# Builds everything that goes above the final response: the prompt of this turn
# as a level 3 heading, then one "question, answer, ---" block per
# AskUserQuestion the turn made. A prompt that spans several lines gets a "---"
# of its own, since only its first line is the heading.
read -r -d '' PREFIX <<'JQ' || true
def txt:
  (.message.content) as $c
  | if ($c|type) == "string" then $c
    elif ($c|type) == "array" then ($c | map(select(.type=="text") | .text) | join("\n"))
    else ""
    end;

# The transcript records more as a user entry than the human typing: hook and
# skill context (isMeta), local command echoes and output, task notifications,
# interruptions, and the tool_result of every tool call.
def isprompt:
  .type == "user"
  and (.isMeta != true)
  and (.isSidechain != true)
  and (.isCompactSummary != true)
  and (
    (txt) as $t
    | ($t | length) > 0
      and (
        ($t | startswith("<local-command-caveat>"))
        or ($t | startswith("<local-command-stdout>"))
        or ($t | startswith("<task-notification>"))
        or ($t | startswith("[Request interrupted"))
        | not
      )
  );

def istext:
  .type == "assistant"
  and (.isSidechain != true)
  and (.message.content | type == "array")
  and (.message.content | any(.type == "text"));

# A slash command reaches the transcript as an XML envelope rather than as what
# was typed, so put it back together as "/name args".
def prompttext:
  (txt) as $t
  | if ($t | test("<command-name>")) then
      (try ($t | capture("<command-name>(?<v>[^<]*)</command-name>") | .v) catch "") as $n
      | (try ($t | capture("<command-args>(?<v>[^<]*)</command-args>") | .v) catch "") as $a
      | ([$n, $a] | map(select(. != "")) | join(" "))
    else $t
    end
  | sub("[[:space:]]+$"; "");

# The questions with their options, then the answers in the same order, so a
# call that asked several questions still reads top to bottom.
def block($qs; $ans; $notes):
  [ ($qs | map(
      "**" + .question + "**"
      + ( (.options // [])
          | map("\n- " + .label
                + (if ((.description // "") == "") then "" else ": " + .description end))
          | if length == 0 then "" else "\n" + join("") end )
    ) | join("\n\n")),
    ($qs | map(
      .question as $q
      | "→ " + (($ans[$q] // "(unanswered)") | tostring)
        + (($notes[$q].notes // "") | if . == "" then "" else " — " + . end)
    ) | join("\n"))
  ] | join("\n\n");

. as $all
| ([ $all | to_entries[] | select(.value | istext) ] | last) as $last
| ($last.key // (($all | length) - 1)) as $li
| ([ $all | to_entries[] | select(.key < $li) | select(.value | isprompt) ] | last) as $p
| ($p.value | prompttext) as $pt
| [ ( if $p == null then empty
      else "### " + $pt + (if ($pt | contains("\n")) then "\n\n---" else "" end)
      end ) ]
  + ( [ $all | to_entries[]
        | select(.key > ($p.key // -1) and .key < $li)
        | .value
        | select((.isSidechain != true)
                 and .type == "assistant"
                 and (.message.content | type == "array"))
        | .message.content[]
        | select(.type == "tool_use" and .name == "AskUserQuestion") ]
      | map(
          .id as $id
          | .input.questions as $asked
          # The answers live on the tool_result entry, not on the tool_use.
          | ([ $all[]
               | select(.type == "user"
                        and (.message.content | type == "array")
                        and (.message.content
                             | any(.type == "tool_result" and .tool_use_id == $id)))
               | .toolUseResult ] | last) as $r
          | block(($r.questions // $asked // []); ($r.answers // {}); ($r.annotations // {}))
            + "\n\n---"
        ) )
| join("\n\n")
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

prefix=$(jq -rs "$PREFIX" "$tp" 2>/dev/null)

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

mkdir -p "$dir" || exit 0

# One file per Stop, so pick up where this session left off. The counter is kept
# per session, which keeps concurrent sessions out of each other's numbering, and
# `10#` keeps a zero padded number from being read as octal.
n=0
for f in "$dir/$sid"_[0-9][0-9][0-9]*.md; do
  [ -e "$f" ] || continue
  b=${f##*/}
  b=${b%.md}
  b=${b##*_}
  case "$b" in
    "" | *[!0-9]*) continue ;;
  esac
  [ "$((10#$b))" -gt "$n" ] && n=$((10#$b))
done
base=$(printf '%s_%03d.md' "$sid" "$((n + 1))")
out="$dir/$base"

{
  if [ -n "$prefix" ]; then
    printf '%s\n\n' "$prefix"
  fi
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

# Relative targets, so the directory stays movable. -n keeps ln from following an
# existing symlink and creating <name>.md/<target> underneath it, and -f replaces
# the plain <session id>.md file that older versions of this hook wrote.
ln -sfn "$base" "$dir/$sid.md"
ln -sfn "$sid.md" "$dir/last.md"
exit 0
