#!/bin/bash
# Guard against #1008 — a directly-invoked hook committed non-executable.
#
# Bug shape: .claude/hooks/reindex-on-session-start.sh was committed with
# mode 100644 (non-executable), but its SessionStart wiring in
# .claude/settings.json invokes it via `exec "$r/.claude/hooks/<name>.sh"`,
# which requires the execute bit. Every session start on a fresh clone
# failed with "Permission denied" — and because a mode-only change produces
# an EMPTY content diff, the regression is invisible in a normal code
# review (`git diff` shows nothing to look at).
#
# This test closes that blind spot mechanically: every hook settings.json
# invokes via `exec "$r/.claude/hooks/<name>.sh"` MUST be committed 100755
# in git's index. It deliberately does NOT check the `_lib-*.sh` files —
# those are `source`d by other hooks, never exec'd directly, so 100644 is
# correct for them (see #1008's own notes + the six 100644 files audited
# during the fix: five _lib-*.sh + this one).
#
# Cases covered:
#   1. Every hook exec'd from settings.json is 100755 in the git index
#   2. No _lib-*.sh file is accidentally required to be 100755 by this test
#      (negative control — confirms the extraction logic doesn't overreach)
#
# Exit 0 if all cases pass; 1 on first failure.

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

echo "== Directly-exec'd hook exec-bit invariants (#1008 regression guard)"

# --- Extract every hook path settings.json invokes via `exec "$r/.../<name>.sh"`
EXEC_HOOKS=$(grep -oE '\.claude/hooks/[A-Za-z0-9_-]+\.sh' "$SETTINGS" | sort -u)

if [ -z "$EXEC_HOOKS" ]; then
  mark_fail "wrapper extraction" "found 0 exec'd hooks in settings.json — extraction regex may have drifted"
else
  mark_pass "extracted $(echo "$EXEC_HOOKS" | wc -l | tr -d ' ') directly-exec'd hook path(s) from settings.json"
fi

# --- Invariant 1: every exec'd hook is 100755 in git's index -----------------
cd "$ROOT" || exit 1
bad=""
checked=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  checked=$((checked+1))
  mode=$(git ls-files -s -- "$rel" 2>/dev/null | awk '{print $1}')
  if [ -z "$mode" ]; then
    bad="$bad $rel(untracked)"
  elif [ "$mode" != "100755" ]; then
    bad="$bad $rel($mode)"
  fi
done <<EOF
$EXEC_HOOKS
EOF

if [ "$checked" -gt 0 ] && [ -z "$bad" ]; then
  mark_pass "all $checked directly-exec'd hooks are 100755 in the git index"
else
  mark_fail "exec-bit regression" "non-executable or untracked hook(s) directly invoked by settings.json:$bad"
fi

# --- Invariant 2 (negative control): _lib-*.sh files are never in the exec set
lib_leak=$(echo "$EXEC_HOOKS" | grep -c '/_lib-' || true)
if [ "${lib_leak:-0}" = "0" ]; then
  mark_pass "no _lib-*.sh file appears in the directly-exec'd set (sourced, not exec'd — 100644 is correct for them)"
else
  mark_fail "_lib leak" "found ${lib_leak} _lib-*.sh file(s) in the exec'd set — extraction regex is over-matching"
fi

# --- Summary ---
echo
echo "===== test_hook_exec_bits.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED"
  exit 1
fi
exit 0
