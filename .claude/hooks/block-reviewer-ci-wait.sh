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
#   - sleep of 60 seconds or more
#   - a second gh pr checks in the same review run
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
# This hook does not read or change block-unreviewed-merge.sh or
# block-merge-on-red-ci.sh. Those merge gates stay as they are (C1).

set -u

INPUT=$(cat)

# The review agent allowlist lives in _lib-review-markers.sh
# (REVIEW_AGENT_SLUGS). Add a slug there when a review-class agent is created.

command -v jq >/dev/null 2>&1 || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null || true)
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -n "$COMMAND" ] || exit 0

# Cheap exit: none of the watched words appear.
case "$COMMAND" in
  *sleep*|*"gh pr checks"*|*"gh run watch"*) ;;
  *) exit 0 ;;
esac

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
if [ -f "$HOOK_DIR/_lib-review-markers.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-review-markers.sh"
fi

find_ops_root() {
  local root="${APEXYARD_REVIEW_OPS_ROOT:-}"
  if [ -z "$root" ] || [ ! -d "$root/.claude/session" ]; then
    root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    while [ -n "$root" ] && [ "$root" != / ]; do
      if [ -f "$root/.apexyard-fork" ] || { [ -f "$root/onboarding.yaml" ] && [ -f "$root/apexyard.projects.yaml" ]; }; then
        break
      fi
      root=$(dirname "$root")
    done
  fi
  [ "$root" = / ] && root=""
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

# Whole seconds for one sleep argument. Prints -1 for "infinity".
sleep_arg_seconds() {
  local a="$1" num unit
  case "$a" in
    infinity|inf) printf '%s' -1; return ;;
  esac
  num="${a%%[!0-9.]*}"
  unit="${a#"$num"}"
  [ -n "$num" ] || { printf '%s' 0; return; }
  num="${num%%.*}"
  [ -n "$num" ] || num=0
  case "$unit" in
    ""|s) printf '%s' "$num" ;;
    m) printf '%s' $((num * 60)) ;;
    h) printf '%s' $((num * 3600)) ;;
    d) printf '%s' $((num * 86400)) ;;
    *) printf '%s' 0 ;;
  esac
}

# One segment per line: split on ; & and |.
# shellcheck disable=SC2020
SEGMENTS=$(printf '%s\n' "$SCAN" | tr ';&|' '\n\n\n')

CHECKS_IN_COMMAND=0
while IFS= read -r seg; do
  # Drop leading blanks, a grouping character, and a loop keyword.
  seg=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*(\(|\{)?[[:space:]]*((do|then|else)[[:space:]]+)?//')
  case "$seg" in
    "gh run watch"|"gh run watch "*)
      block "gh run watch is not allowed in a review agent."
      ;;
    "gh pr checks"|"gh pr checks "*)
      case " $seg " in
        *" --watch "*|*" --watch="*) block "gh pr checks --watch is not allowed in a review agent." ;;
      esac
      CHECKS_IN_COMMAND=$((CHECKS_IN_COMMAND + 1))
      if [ "$CHECKS_IN_COMMAND" -gt 1 ]; then
        block "A second gh pr checks in one review run is not allowed."
      fi
      ;;
    "sleep "*)
      total=0
      set -f
      # shellcheck disable=SC2086
      set -- ${seg#sleep }
      set +f
      for arg in "$@"; do
        case "$arg" in -*) continue ;; esac
        s=$(sleep_arg_seconds "$arg")
        if [ "$s" = "-1" ]; then
          block "sleep infinity is not allowed in a review agent."
        fi
        total=$((total + s))
      done
      if [ "$total" -ge 60 ]; then
        block "sleep of 60 seconds or more is not allowed in a review agent."
      fi
      ;;
  esac
done <<EOS
$SEGMENTS
EOS

# Per-run counter for a second gh pr checks across separate commands.
if [ "$CHECKS_IN_COMMAND" -ge 1 ]; then
  [ -n "$ROOT" ] || ROOT=$(find_ops_root)
  if [ -n "$ROOT" ]; then
    key="${SESSION:-nosession}-${AGENT_ID:-$AGENT_TYPE}"
    key=$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')
    dir="$ROOT/.claude/session/review-ci-checks"
    if [ -f "$dir/$key" ]; then
      block "A second gh pr checks in one review run is not allowed."
    fi
    mkdir -p "$dir" 2>/dev/null && : > "$dir/$key"
  fi
fi
exit 0
