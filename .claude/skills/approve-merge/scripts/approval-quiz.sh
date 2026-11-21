#!/bin/bash
# approval-quiz.sh - opt-in comprehension-check helpers (#1997).
#
# Does NOT write markers, merge, or change gate logic. Read-only helpers for
# /approve-merge (when --quiz or config turns the quiz on) and /explain-pr.
#
# Usage:
#   approval-quiz.sh should-run <marker_home> [--quiz]
#     Prints "yes" or "no". Exit 0. Config key: merge.approval_quiz (default false).
#   approval-quiz.sh pack <diff-file> <body-file>
#     Prints a JSON evidence pack with file:line anchors from a unified diff.
#   approval-quiz.sh sample-questions <pack-json-file>
#     Prints three grounded questions as JSON (for fixtures / offline tests).
#   approval-quiz.sh show-lines <pack-json-file> <file> <line>
#     Prints the packed lines around file:line. Exit 1 when the anchor is absent.
#
# Bash 3.2 compatible. ASCII only. No network.
set -u

fail() { printf '%s\n' "$2" >&2; exit "$1"; }

cmd=${1:-}
[ -n "$cmd" ] || fail 1 'Usage: approval-quiz.sh <should-run|pack|sample-questions|show-lines> ...'

# ---------------------------------------------------------------------------
# should-run <marker_home> [--quiz]
# ---------------------------------------------------------------------------
if [ "$cmd" = 'should-run' ]; then
  MARKER_HOME=${2:-}
  FLAG=${3:-}
  [ -n "$MARKER_HOME" ] || fail 1 'Usage: approval-quiz.sh should-run <marker_home> [--quiz]'
  [ -f "$MARKER_HOME/.claude/hooks/_lib-read-config.sh" ] || fail 1 'Cannot load config from marker_home.'
  # shellcheck source=/dev/null
  source "$MARKER_HOME/.claude/hooks/_lib-read-config.sh" >&2 || fail 1 'Cannot load config library.'
  _CONFIG_ROOT_CACHE="$MARKER_HOME"
  _CONFIG_ROOT_CACHE_SET=1
  QUIZ_CFG=$(config_get_or '.merge.approval_quiz' 'false') || fail 1 'Cannot read merge.approval_quiz.'
  if [ "$FLAG" = '--quiz' ] || [ "$QUIZ_CFG" = 'true' ]; then
    printf '%s\n' 'yes'
  else
    printf '%s\n' 'no'
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# pack <diff-file> <body-file>
# ---------------------------------------------------------------------------
# Emits: {"body":"...","anchors":[{"file":"...","line":N,"text":"..."}, ...]}
# Anchors name every added (+) line in the unified diff with its new-file line.
# ---------------------------------------------------------------------------
if [ "$cmd" = 'pack' ]; then
  DIFF=${2:-}
  BODY=${3:-}
  [ -f "$DIFF" ] && [ -f "$BODY" ] || fail 1 'Usage: approval-quiz.sh pack <diff-file> <body-file>'
  command -v jq >/dev/null 2>&1 || fail 1 'jq is required.'

  BODY_TEXT=$(cat "$BODY") || fail 1 'Cannot read body file.'
  ANCHORS_FILE=$(mktemp) || fail 1 'Cannot create temp file.'
  printf '%s\n' '[]' > "$ANCHORS_FILE"

  cur_file=''
  new_line=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '+++ '*)
        # +++ b/path  or  +++ /dev/null
        rest=${line#+++ }
        case "$rest" in
          '/dev/null') cur_file='' ;;
          b/*) cur_file=${rest#b/} ;;
          *) cur_file=$rest ;;
        esac
        new_line=0
        ;;
      '@@ '*)
        # @@ -a,b +c,d @@  or  @@ -a +c @@
        plus=${line#*+}
        plus=${plus%% *}
        start=${plus%%,*}
        case "$start" in
          ''|*[!0-9]*) new_line=0 ;;
          *) new_line=$start ;;
        esac
        # The hunk header itself is not a content line; next content uses start.
        # Decrement so the first content line increments to `start`.
        if [ "$new_line" -gt 0 ] 2>/dev/null; then
          new_line=$((new_line - 1))
        fi
        ;;
      '+'*)
        # Added line (not +++ header - already handled).
        if [ -n "$cur_file" ]; then
          new_line=$((new_line + 1))
          text=${line#+}
          # Skip pure file-header noise already handled; keep content.
          tmp=$(mktemp) || fail 1 'Cannot create temp file.'
          jq -c --arg f "$cur_file" --argjson n "$new_line" --arg t "$text" \
            '. + [{"file":$f,"line":$n,"text":$t}]' \
            "$ANCHORS_FILE" > "$tmp" || fail 1 'Cannot append anchor.'
          mv "$tmp" "$ANCHORS_FILE"
        fi
        ;;
      '-'*)
        # Deleted line: does not advance new-file line counter.
        ;;
      ' '*)
        # Context line: advances new-file line counter.
        if [ -n "$cur_file" ] && [ "$new_line" -ge 0 ] 2>/dev/null; then
          new_line=$((new_line + 1))
        fi
        ;;
      "\\"*)
        # "\ No newline at end of file" - ignore.
        ;;
    esac
  done < "$DIFF"

  jq -cn --arg body "$BODY_TEXT" --slurpfile anchors "$ANCHORS_FILE" \
    '{body:$body, anchors:$anchors[0]}' || fail 1 'Cannot build pack JSON.'
  rm -f "$ANCHORS_FILE"
  exit 0
fi

# ---------------------------------------------------------------------------
# sample-questions <pack-json-file>
# ---------------------------------------------------------------------------
# Builds three multiple-choice questions from the first three distinct
# file:line anchors. Each question names the file and line. Options are
# grounded in pack text only (correct + up to two other pack lines).
# ---------------------------------------------------------------------------
if [ "$cmd" = 'sample-questions' ]; then
  PACK=${2:-}
  [ -f "$PACK" ] || fail 1 'Usage: approval-quiz.sh sample-questions <pack-json-file>'
  command -v jq >/dev/null 2>&1 || fail 1 'jq is required.'

  COUNT=$(jq '.anchors | length' "$PACK") || fail 1 'Cannot read pack anchors.'
  [ "$COUNT" -ge 1 ] || fail 1 'Pack has no anchors; cannot build questions.'

  # Pick up to three anchors with non-empty text.
  qs=$(mktemp) || fail 1 'Cannot create temp file.'
  printf '%s\n' '[]' > "$qs"
  i=0
  while [ "$i" -lt "$COUNT" ]; do
    file=$(jq -r --argjson i "$i" '.anchors[$i].file' "$PACK")
    line=$(jq -r --argjson i "$i" '.anchors[$i].line' "$PACK")
    text=$(jq -r --argjson i "$i" '.anchors[$i].text' "$PACK")
    i=$((i + 1))
    [ -n "$text" ] || continue
    # Distractors: other non-empty texts from the pack, not equal to correct.
    d1=$(jq -r --arg t "$text" '[.anchors[].text | select(length>0 and . != $t)][0] // empty' "$PACK")
    d2=$(jq -r --arg t "$text" '[.anchors[].text | select(length>0 and . != $t)][1] // empty' "$PACK")
    opts=$(jq -cn --arg a "$text" --arg b "$d1" --arg c "$d2" \
      '[ $a, $b, $c ] | map(select(length>0)) | unique')
    prompt="In ${file} at line ${line}, which added line is in this change?"
    tmp=$(mktemp) || fail 1 'Cannot create temp file.'
    jq -c --arg q "$prompt" --arg f "$file" --argjson n "$line" --arg ans "$text" --argjson o "$opts" \
      '. + [{"question":$q,"file":$f,"line":$n,"answer":$ans,"options":$o}]' \
      "$qs" > "$tmp" || fail 1 'Cannot append question.'
    mv "$tmp" "$qs"
    qcount=$(jq 'length' "$qs")
    [ "$qcount" -ge 3 ] && break
  done

  qcount=$(jq 'length' "$qs")
  [ "$qcount" -ge 1 ] || fail 1 'Could not build any question from the pack.'
  # Pad by repeating the last question shape only when the pack is tiny:
  # refuse to invent facts; emit what we have (1..3). Skill asks three when
  # three exist; tests pin "at least one names file and line".
  jq -c '.' "$qs"
  rm -f "$qs"
  exit 0
fi

# ---------------------------------------------------------------------------
# show-lines <pack-json-file> <file> <line>
# ---------------------------------------------------------------------------
if [ "$cmd" = 'show-lines' ]; then
  PACK=${2:-}
  FILE=${3:-}
  LINE=${4:-}
  [ -f "$PACK" ] && [ -n "$FILE" ] && [ -n "$LINE" ] || \
    fail 1 'Usage: approval-quiz.sh show-lines <pack-json-file> <file> <line>'
  command -v jq >/dev/null 2>&1 || fail 1 'jq is required.'
  hit=$(jq -r --arg f "$FILE" --argjson n "$LINE" \
    '.anchors[] | select(.file==$f and .line==$n) | .text' "$PACK")
  if [ -z "$hit" ]; then
    printf '%s\n' "No packed line for ${FILE}:${LINE}." >&2
    exit 1
  fi
  printf '%s:%s: %s\n' "$FILE" "$LINE" "$hit"
  exit 0
fi

fail 1 "Unknown command: $cmd"
