#!/bin/bash
# CLASS: CONTROL - blocks CI waiting by review agents (me2resh/apexyard#1625).
#
# A review agent checks CI once and never waits. The orchestrator waits for
# green CI with a Monitor and only then spawns the reviewer. A reviewer that
# polls CI keeps its whole context warm for minutes and pays for every poll.
#
# Blocked for a review agent only:
#   - gh pr checks ... --watch
#   - gh run watch
#   - polling loops with sleep or gh pr checks
#   - total sleep of 60 seconds or more
#   - a second gh pr checks in the same review run
# A brace body { ... } of a for loop is read like do ... done. Commands in a for header count toward the totals.
# The orchestrator is never blocked.
#
# Review-agent detection, in order:
#   1. The hook input carries agent_type. Claude Code sets it to the agent
#      name for a tool call made inside a sub-agent (hooks reference,
#      PreToolUse input). A review agent is one whose type is in the
#      allowlist in the shared lib. Any other type is not a review agent: allow.
#   2. The input carries agent_id but no agent_type (a sub-agent with no
#      type). Fall back to the session's active-reviewer marker
#      (active_reviewer_marker_path in _lib-review-markers.sh). Marker
#      present: review agent. Marker absent: allow.
#   3. The input carries neither: this is the orchestrator. Allow.
#
# The second-check counter is one file per review run under
# .claude/session/review-ci-checks/. A run is keyed on session and agent_id,
# so each new reviewer spawn starts at zero. A typed call with no agent_id
# is keyed on session and agent_type.
#
# The dispatcher supplies APEXYARD_REVIEW_OPS_ROOT. This hook never searches
# the current directory for markers or counters.
#
# This hook does not read or change block-unreviewed-merge.sh or
# block-merge-on-red-ci.sh. Those merge gates stay as they are (C1).

set -u

INPUT=$(cat)

# Check raw JSON before starting jq.
case "$INPUT" in
  *sleep*|*checks*|*watch*) ;;
  *) exit 0 ;;
esac

# The review agent allowlist lives in _lib-review-markers.sh.
# Adopters add exact types through review_markers.extra_review_agents.

command -v jq >/dev/null 2>&1 || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -er '.tool_input.command | select(type == "string")' 2>/dev/null || true)
AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null || true)
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -n "$COMMAND" ] || exit 0

# Reject malformed field types before classifying the caller.
printf '%s' "$INPUT" | jq -e '
  type == "object" and
  (.tool_input.command | type == "string") and
  ([.agent_type, .agent_id, .session_id] | all(. == null or type == "string"))
' >/dev/null 2>&1 || exit 0
SESSION="${SESSION:-${CLAUDE_CODE_SESSION_ID:-}}"

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
if [ -f "$HOOK_DIR/_lib-review-markers.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-review-markers.sh"
fi

find_ops_root() {
  local root="${APEXYARD_REVIEW_OPS_ROOT:-}"
  [ -d "$root" ] || root=""
  printf '%s' "$root"
}

ROOT=""
IS_REVIEWER=0
# Shared detection (review_caller_class in _lib-review-markers.sh): the
# harness agent_type first, the marker only for a sub-agent with no type.
if command -v review_caller_class >/dev/null 2>&1; then
  ROOT=$(find_ops_root)
  [ "$(review_caller_class "$INPUT" "$ROOT")" = "reviewer" ] && IS_REVIEWER=1
fi
[ "$IS_REVIEWER" -eq 1 ] || exit 0

# Scrub quoted data when the scrubber is present, so a commit message that
# only mentions a watch command does not block.
SCAN="$COMMAND"
if [ -r "$HOOK_DIR/_lib-command-scrub.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-command-scrub.sh"
  SCAN=$(scrub_bash_command "$COMMAND")
fi

block() {
  echo "BLOCKED: $1" >&2
  echo "A review agent checks CI once and never waits. Report the CI state you saw and finish the review. The orchestrator waits for green CI with a Monitor before it spawns the reviewer (me2resh/apexyard#1625)." >&2
  exit 2
}

# Cap values before arithmetic. -1 means over the limit.
# Round exponent forms up. Preserve truncation for ordinary decimal arguments.
# Decimal shifting avoids powers and integer overflow, including negative powers.
sleep_arg_seconds() {
  local a="${1%\}}" num unit exp=0 digits point whole tail sign=1 round=0
  case "$a" in infinity|inf) printf '%s' -1; return ;; esac
  if [[ "$a" =~ ^0[xX]([0-9a-fA-F]+)$ ]]; then
    digits="${BASH_REMATCH[1]}"
    while [[ "$digits" = 0* ]] && [ "${#digits}" -gt 1 ]; do digits="${digits#0}"; done
    [ "${#digits}" -le 2 ] || { printf '%s' -1; return; }
    printf '%s' "$((16#$digits))"
    return
  fi
  if [[ "$a" =~ ^([0-9]+([.][0-9]+)?)[eE]([+-]?[0-9]+)$ ]]; then
    num="${BASH_REMATCH[1]}"
    exp="${BASH_REMATCH[3]}"
    unit=s
    round=1
  else
    num="${a%%[!0-9.]*}"
    unit="${a#"$num"}"
    [[ "$num" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '%s' 0; return; }
  fi
  case "$unit" in ""|s|m|h|d) ;; *) printf '%s' 0; return ;; esac
  digits="${num//./}"
  point=${#num}
  if [[ "$num" = *.* ]]; then whole="${num%%.*}"; point=${#whole}; fi
  while [[ "$digits" = 0* ]] && [ -n "$digits" ]; do
    digits="${digits#0}"
    point=$((point - 1))
  done
  [ -n "$digits" ] || { printf '%s' 0; return; }
  case "$exp" in -*) sign=-1; exp="${exp#-}" ;; +*) exp="${exp#+}" ;; esac
  while [[ "$exp" = 0* ]] && [ "${#exp}" -gt 1 ]; do exp="${exp#0}"; done
  # Reject powers too large to compute instead of attempting shell arithmetic.
  [ "${#exp}" -le 6 ] || { printf '%s' -1; return; }
  point=$((point + sign * 10#$exp))
  [ "$point" -le 2 ] || { printf '%s' -1; return; }
  if [ "$point" -le 0 ]; then
    whole=$round
  else
    while [ "${#digits}" -lt "$point" ]; do digits="${digits}0"; done
    whole="${digits:0:point}"
    tail="${digits:point}"
    whole=$((10#$whole))
    if [ "$round" -eq 1 ] && [[ "$tail" =~ [1-9] ]]; then whole=$((whole + 1)); fi
  fi
  case "$unit" in
    ""|s) printf '%s' "$whole" ;;
    m) printf '%s' $((whole * 60)) ;;
    h) printf '%s' $((whole * 3600)) ;;
    d) printf '%s' $((whole * 86400)) ;;
  esac
}

# Flatten executable wrappers after scrubbing literal data.
# shellcheck disable=SC2020
SEGMENTS=$(printf '%s\n' "$SCAN" | tr -d "'\"\\\\" | tr ';&|()`' '\n' | sed 's/[[:blank:]][[:blank:]]*/ /g')

CHECKS_IN_COMMAND=0
LOOP_DEPTH=0
LOOP_FOR_HEADER=0
IN_HEADER=0
POLLING_LOOP=0
TOTAL=0
# A for header runs once per outer iteration. The for itself raised the depth.
mark_polling_loop() {
  local eff=$LOOP_DEPTH
  [ "$IN_HEADER" -eq 0 ] || eff=$((eff - 1))
  [ "$eff" -le 0 ] || POLLING_LOOP=1
}
while IFS= read -r seg; do
  read -r -a words <<< "$seg"
  i=0
  n=${#words[@]}
  IN_HEADER=0
  if [ "$LOOP_FOR_HEADER" -eq 1 ] && [ "${words[0]:-}" != "do" ] && [ "${words[0]:-}" != "{" ]; then
    IN_HEADER=1
  fi
  while [ "$i" -lt "$n" ]; do
    w="${words[$i]##*/}"
    case "$w" in
      while|until) LOOP_DEPTH=$((LOOP_DEPTH + 1)) ;;
      for) LOOP_DEPTH=$((LOOP_DEPTH + 1)); LOOP_FOR_HEADER=1; i=$n; break ;;
      do) LOOP_FOR_HEADER=0 ;;
      '{') LOOP_FOR_HEADER=0 ;;
      done) [ "$LOOP_DEPTH" -le 0 ] || LOOP_DEPTH=$((LOOP_DEPTH - 1)) ;;
      '!'|then|else|elif|if|time|command|builtin|exec|nohup|eval) ;;
      env)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${words[$i]}" in -*|*=*) i=$((i + 1)) ;; *) break ;; esac
        done
        continue ;;
      nice)
        i=$((i + 1))
        if [ "$i" -lt "$n" ]; then
          case "${words[$i]}" in -n) i=$((i + 2)) ;; -[0-9]*) i=$((i + 1)) ;; esac
        fi
        continue ;;
      timeout)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${words[$i]}" in
            -k|-s|--kill-after|--signal) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        i=$((i + 1))
        continue ;;
      bash|sh|zsh|dash|ksh)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${words[$i]}" in -*) i=$((i + 1)) ;; *) break ;; esac
        done
        continue ;;
      *)
        if [[ "${words[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
          i=$((i + 1))
          continue
        fi
        break ;;
    esac
    i=$((i + 1))
  done
  [ "$i" -lt "$n" ] || continue
  case "${words[$i]##*/}" in
    gh)
      if [ "${words[$((i + 1))]:-}" = run ] && [ "${words[$((i + 2))]:-}" = watch ]; then
        block "gh run watch is not allowed in a review agent."
      fi
      if [ "${words[$((i + 1))]:-}" = pr ] && [ "${words[$((i + 2))]:-}" = checks ]; then
        for arg in "${words[@]}"; do
          case "$arg" in --watch|--watch=*) block "gh pr checks --watch is not allowed in a review agent." ;; esac
        done
        CHECKS_IN_COMMAND=$((CHECKS_IN_COMMAND + 1))
        mark_polling_loop
      fi ;;
    sleep)
      mark_polling_loop
      i=$((i + 1))
      while [ "$i" -lt "$n" ]; do
        arg="${words[$i]}"
        i=$((i + 1))
        case "$arg" in -*) continue ;; esac
        seconds=$(sleep_arg_seconds "$arg")
        [ "$seconds" != -1 ] || block "Sleep exceeds the review-agent limit or is too large to compute."
        # Stop before the sum can overflow, even with many arguments.
        [ "$seconds" -lt 60 ] || block "Sleep of 60 seconds or more is not allowed in a review agent."
        TOTAL=$((TOTAL + seconds))
        [ "$TOTAL" -lt 60 ] || block "Total sleep of 60 seconds or more is not allowed in a review agent."
      done ;;
  esac
done <<EOS
$SEGMENTS
EOS

if [ "$POLLING_LOOP" -eq 1 ]; then
  block "A polling loop is not allowed in a review agent."
fi
[ "$TOTAL" -lt 60 ] || block "Total sleep of 60 seconds or more is not allowed in a review agent."
[ "$CHECKS_IN_COMMAND" -le 1 ] || block "A second gh pr checks in one review run is not allowed."

# Count separate calls only when the run has a session or agent id.
if [ "$CHECKS_IN_COMMAND" -ge 1 ] && [ -n "$ROOT" ] && { [ -n "$SESSION" ] || [ -n "$AGENT_ID" ]; }; then
  key="${SESSION:-nosession}-${AGENT_ID:-$AGENT_TYPE}"
  key=$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')
  dir="$ROOT/.claude/session/review-ci-checks"
  if mkdir -p "$dir" 2>/dev/null; then
    # No hook runs when a review ends. Remove counters older than one day.
    find "$dir" -type f -mtime +0 -exec rm -f {} + 2>/dev/null
    if ! ( set -C; : > "$dir/$key" ) 2>/dev/null && [ -e "$dir/$key" ]; then
      block "A second gh pr checks in one review run is not allowed."
    fi
  fi
fi
exit 0
