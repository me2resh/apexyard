#!/usr/bin/env bash
# Text-pin test for the fresh-spawn default (me2resh/apexyard#1774 / ac2-3).
#
# Pins the contracts in:
#   - .claude/rules/parallel-work.md  — fresh role-appropriate spawn + written brief;
#                                       fork only when facts are not yet in a file
#   - .claude/skills/fan-out/SKILL.md — same default; no general-purpose default;
#                                       rule 8 names a role-appropriate editing agent
#
# Style matches test_pr_quality_narrative_rule.sh — plain bash + grep, no framework.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RULE_FILE="${FRESH_SPAWN_RULE:-$SRC_ROOT/.claude/rules/parallel-work.md}"
FANOUT_FILE="${FRESH_SPAWN_FANOUT:-$SRC_ROOT/.claude/skills/fan-out/SKILL.md}"

PASS=0
FAIL=0
FAILED=""

assert() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS [$label]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [$label]" >&2
    FAIL=$((FAIL + 1))
    FAILED="${FAILED}${label} "
  fi
}

assert_absent() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if grep -qF -- "$pattern" "$file" 2>/dev/null; then
    echo "FAIL [$label]" >&2
    FAIL=$((FAIL + 1))
    FAILED="${FAILED}${label} "
  else
    echo "PASS [$label]"
    PASS=$((PASS + 1))
  fi
}

# --- parallel-work.md ---------------------------------------------------------

assert "rule:file-exists" test -f "$RULE_FILE"

assert "rule:fresh-spawn-heading" \
  grep -qE '^## Spawn mode — fresh by default$' "$RULE_FILE"

assert "rule:fresh-role-appropriate" \
  grep -qF 'fresh, role-appropriate spawn with a written brief' "$RULE_FILE"

assert "rule:fork-only-when-facts-not-in-file" \
  grep -qF 'facts the agent needs are not yet in a file' "$RULE_FILE"

# --- fan-out SKILL.md ---------------------------------------------------------

assert "fanout:file-exists" test -f "$FANOUT_FILE"

assert "fanout:fresh-role-appropriate" \
  grep -qF 'fresh, role-appropriate spawn with a written brief' "$FANOUT_FILE"

assert "fanout:spawn-mode-fresh" \
  grep -qF 'default a fresh spawn with a written brief' "$FANOUT_FILE"

assert "fanout:fork-only-when-facts-not-in-file" \
  grep -qF 'facts the agent needs are not yet in a file' "$FANOUT_FILE"

# Rule 8 must name a role-appropriate editing agent, not general-purpose.
assert "fanout:rule8-backend-engineer" \
  grep -qF 'backend-engineer' "$FANOUT_FILE"

assert "fanout:rule8-frontend-engineer" \
  grep -qF 'frontend-engineer' "$FANOUT_FILE"

assert "fanout:rule8-platform-engineer" \
  grep -qF 'platform-engineer' "$FANOUT_FILE"

assert "fanout:rule8-fresh-spawn" \
  grep -qF 'Default to a fresh role-appropriate spawn with a written brief' "$FANOUT_FILE"

# Must not bring back the old general-purpose default wording.
assert_absent "fanout:no-default-general-purpose" \
  'default `general-purpose`' "$FANOUT_FILE"

assert_absent "fanout:no-recommend-general-purpose-first" \
  'Recommend `general-purpose` first' "$FANOUT_FILE"

assert_absent "fanout:no-suggest-general-purpose" \
  'suggest `general-purpose`' "$FANOUT_FILE"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "All fresh-spawn-default text-pin tests passed ($PASS passed)."
  exit 0
else
  echo "$FAIL fresh-spawn-default text-pin test(s) FAILED ($PASS passed): $FAILED" >&2
  exit 1
fi
