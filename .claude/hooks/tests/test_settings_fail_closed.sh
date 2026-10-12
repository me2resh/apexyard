#!/usr/bin/env bash
# Settings invariants for the fail-closed gates (me2resh/apexyard#1623).
#
# 1. Dispatcher, ticket-first, and menu-record guard entries set
#    "onFailure": "block".
# 2. Each timeout is at least 5 x the recorded p95 and never under 10 seconds.
#    The p95 values come from docs/perf/hook-fail-closed-profile-2026-10.md.
# 3. Only these entries and the menu-record guard set "onFailure".
# 4. No tracked settings file sets disableAllHooks.
# 5. The marketplace CI workflow pins a Claude Code version of 2.1.295 or later.
# 6. The dispatcher keeps block-reviewer-ci-wait.sh fail open and
#    require-active-ticket.sh fail closed (static check; the behavior is
#    tested in test_dispatch_bash.sh).
#
# bash 3.2 compatible.

set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"
SETTINGS="$ROOT/.claude/settings.json"
PROFILE="$ROOT/docs/perf/hook-fail-closed-profile-2026-10.md"
WORKFLOW="$ROOT/.github/workflows/claude-plugin-validate.yml"
DISPATCH="$ROOT/.claude/hooks/dispatch-bash.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -f "$SETTINGS" ] || fail "settings.json not found at $SETTINGS"
[ -f "$PROFILE" ] || fail "profile not found at $PROFILE"

# entry_field SCRIPT FIELD -> value of FIELD on the single PreToolUse entry
# whose command names SCRIPT. Fails unless exactly one entry matches.
entry_field() {
  local script="$1" field="$2" count
  count=$(jq --arg s "$script" \
    '[.hooks.PreToolUse[].hooks[] | select(.command | contains($s))] | length' "$SETTINGS")
  [ "$count" -eq 1 ] || fail "expected exactly one PreToolUse entry for $script, found $count"
  jq -r --arg s "$script" --arg f "$field" \
    '[.hooks.PreToolUse[].hooks[] | select(.command | contains($s))][0][$f] // empty' "$SETTINGS"
}

profile_p95() {
  # profile: <script> p95_ms=<n>
  local value
  value=$(sed -n "s/^profile: $1 p95_ms=\([0-9][0-9]*\)\$/\1/p" "$PROFILE")
  [ -n "$value" ] || fail "no 'profile: $1 p95_ms=' line in $PROFILE"
  printf '%s' "$value"
}

for script in dispatch-bash.sh require-active-ticket.sh; do
  on_failure=$(entry_field "$script" onFailure)
  [ "$on_failure" = block ] || fail "$script entry must set onFailure to block (got '${on_failure:-unset}')"

  timeout_s=$(entry_field "$script" timeout)
  case "$timeout_s" in
    ''|*[!0-9]*) fail "$script entry must set a numeric timeout (got '${timeout_s:-unset}')" ;;
  esac
  [ "$timeout_s" -ge 10 ] || fail "$script timeout $timeout_s s is under the 10 second floor"

  p95=$(profile_p95 "$script")
  need_ms=$((p95 * 5))
  [ $((timeout_s * 1000)) -ge "$need_ms" ] \
    || fail "$script timeout ${timeout_s}s is under 5 x p95 (${p95} ms x 5 = ${need_ms} ms)"
done

[ "$(entry_field block-forged-menu-approval.sh onFailure)" = block ] \
  || fail "menu-record guard must set onFailure to block"

# Only the three entries may set onFailure.
others=$(jq -r '[.. | objects | select(has("onFailure")) | .command]
  | map(select((contains("dispatch-bash.sh") or contains("require-active-ticket.sh") or contains("block-forged-menu-approval.sh")) | not))
  | length' "$SETTINGS")
[ "$others" -eq 0 ] || fail "$others hook entries outside the fail-closed gates set onFailure"

# Each fail-closed entry occurs once.
total=$(jq '[.. | objects | select(has("onFailure"))] | length' "$SETTINGS")
[ "$total" -eq 3 ] || fail "expected exactly 3 entries with onFailure, found $total"

# Hooks are on by default: no tracked settings file turns them off.
for file in "$ROOT/.claude/settings.json" "$ROOT/.claude/settings.local.json"; do
  [ -f "$file" ] || continue
  if jq -e '.disableAllHooks == true' "$file" >/dev/null 2>&1; then
    fail "$file sets disableAllHooks to true"
  fi
done

# CI pins a Claude Code version that understands onFailure (2.1.295 or later).
[ -f "$WORKFLOW" ] || fail "workflow not found at $WORKFLOW"
pinned=$(sed -n 's/^[[:space:]]*CLAUDE_CODE_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}[[:space:]]*$/\1/p' "$WORKFLOW" | head -1)
[ -n "$pinned" ] || fail "no pinned CLAUDE_CODE_VERSION in $WORKFLOW"
IFS=. read -r major minor patch <<EOF
$pinned
EOF
[ "${major:-0}" -gt 2 ] || { [ "${major:-0}" -eq 2 ] && { [ "${minor:-0}" -gt 1 ] || { [ "${minor:-0}" -eq 1 ] && [ "${patch:-0}" -ge 295 ]; }; }; } \
  || fail "pinned Claude Code $pinned is older than 2.1.295, which added onFailure"
grep -q 'claude plugin validate --strict .claude-plugin/marketplace.json' "$WORKFLOW" \
  || fail "workflow does not run 'claude plugin validate --strict' on the marketplace"

# Static check of the dispatcher routing.
grep -q 'require-active-ticket.sh) run_fail_closed_hook' "$DISPATCH" \
  || fail "dispatcher does not route require-active-ticket.sh through run_fail_closed_hook"
grep -q 'block-forged-menu-approval.sh) run_fail_closed_hook' "$DISPATCH" \
  || fail "dispatcher does not route block-forged-menu-approval.sh through run_fail_closed_hook"
grep -q 'block-reviewer-ci-wait.sh) run_cost_guard_hook' "$DISPATCH" \
  || fail "dispatcher does not route block-reviewer-ci-wait.sh through run_cost_guard_hook"

echo "PASS: fail-closed settings"
