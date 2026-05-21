#!/bin/bash
# Settings.json hook-wrapper invariants — protects against the #370 regression
# where wrappers crashed with "No such file or directory" when Claude Code
# was launched outside an apexyard ancestry.
#
# Bug shape: every wrapper has a walk-up loop terminating with `done;exec
# "$r/.claude/hooks/<name>.sh"`. When `$r` walks all the way to `/`, the
# exec lands on `/.claude/hooks/<name>.sh` — which doesn't exist. Result:
# one "Failed with non-blocking status code" message per wrapper, per
# tool call, flooding the UI.
#
# Fix shape: insert an anchor-found guard between `done;` and `exec`:
#   done;[ -f "$r/.apexyard-fork" ] || [ -f "$r/onboarding.yaml" ] || exit 0;exec ...
# When the anchor isn't found, the wrapper silently exits 0 — which is
# the correct behaviour outside an ops fork.
#
# This test enforces:
#   1. Every wrapper has the anchor-found guard (no unguarded `done;exec`)
#   2. A representative wrapper invoked from /tmp (no apexyard ancestry)
#      exits 0 with no stderr output
#   3. The same wrapper invoked from the ops fork exits 0 (negative
#      control — confirms the guard doesn't accidentally block in-fork
#      invocations)

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SETTINGS="$ROOT/.claude/settings.json"

[ -f "$SETTINGS" ] || { echo "FAIL: settings.json not at $SETTINGS" >&2; exit 1; }

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

PASS=0
FAIL=0
FAILED=""

mark_pass() { green "  ok   $1"; PASS=$((PASS+1)); }
mark_fail() {
  red "  FAIL $1: $2" >&2
  FAIL=$((FAIL+1))
  FAILED="$FAILED $1"
}

echo "== Settings.json hook-wrapper invariants (#370 regression guard)"

# --- Invariant 1: every wrapper has the anchor-found guard --------------------
# Count wrappers (each `r=$PWD` line is one wrapper) vs guards present.
total=$(grep -cF 'r=$PWD' "$SETTINGS")
guarded=$(grep -cF '|| exit 0;exec' "$SETTINGS")
unguarded=$(grep -cF 'done;exec' "$SETTINGS")

if [ "$total" = "0" ]; then
  mark_fail "wrapper count" "expected ≥1 wrapper matching the r=\$PWD shape; found 0 — settings.json may have drifted"
fi

if [ "$guarded" = "$total" ] && [ "$unguarded" = "0" ]; then
  mark_pass "all $total wrappers have the anchor-found guard (no unguarded done;exec)"
else
  mark_fail "wrapper guards" "total=$total guarded=$guarded unguarded=$unguarded — every wrapper must have '|| exit 0;exec' (#370 regression)"
fi

# --- Invariant 2: wrapper invoked outside the fork exits 0 silently ----------
# Extract the canonical wrapper shape + substitute a real hook name
WRAPPER='r=$PWD;while [ ! -f "$r/.apexyard-fork" ] && [ ! -f "$r/onboarding.yaml" ] && [ -n "$r" ] && [ "$r" != / ];do r=${r%/*};done;[ -f "$r/.apexyard-fork" ] || [ -f "$r/onboarding.yaml" ] || exit 0;exec "$r/.claude/hooks/detect-role-trigger.sh"'

OUT=$(mktemp)
ERR=$(mktemp)
(
  cd /tmp || exit 1
  echo '' | bash -c "$WRAPPER" >"$OUT" 2>"$ERR"
)
rc=$?

if [ "$rc" = "0" ] && [ ! -s "$ERR" ]; then
  mark_pass "wrapper invoked from /tmp (no fork ancestry) exits 0 with empty stderr"
else
  mark_fail "outside-fork silent no-op" "rc=$rc stderr=[$(cat "$ERR")]"
fi
rm -f "$OUT" "$ERR"

# --- Invariant 3: wrapper invoked INSIDE the fork still works (negative control)
# The guard must not block legitimate in-fork invocations. Use a path that
# WON'T trigger any role-trigger banner so we get a clean exit-0 baseline.
OUT=$(mktemp)
ERR=$(mktemp)
(
  cd "$ROOT" || exit 1
  echo '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/utils/format.ts"}}' \
    | bash -c "$WRAPPER" >"$OUT" 2>"$ERR"
)
rc=$?

if [ "$rc" = "0" ] && [ ! -s "$ERR" ]; then
  mark_pass "wrapper invoked from inside the fork still exits 0 silently on non-trigger path"
else
  mark_fail "inside-fork still works" "rc=$rc stderr=[$(cat "$ERR")]"
fi
rm -f "$OUT" "$ERR"

# --- Summary ---
echo
echo "===== test_settings_wrappers_silent_noop.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED"
  exit 1
fi
exit 0
