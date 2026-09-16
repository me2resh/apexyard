#!/usr/bin/env bash
# Smoke tests for .claude/hooks/cursor-session-pin.sh.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PIN="$ROOT/.claude/hooks/cursor-session-pin.sh"

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

unset CLAUDE_CODE_SESSION_ID

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/cursor-session-pin-test.XXXXXX")
PLAIN=$(mktemp -d "${TMPDIR:-/tmp}/cursor-session-pin-plain.XXXXXX")
trap 'rm -rf "$TMPROOT" "$PLAIN"' EXIT

HOOKDIR="$TMPROOT/.claude/hooks"
mkdir -p "$HOOKDIR"
touch "$TMPROOT/.apexyard-fork"
git -C "$TMPROOT" init -q >/dev/null 2>&1 || true

cp "$PIN" "$HOOKDIR/cursor-session-pin.sh"
cp "$ROOT/.claude/hooks/_lib-ops-root.sh" "$HOOKDIR/_lib-ops-root.sh"
chmod +x "$HOOKDIR/cursor-session-pin.sh"

PIN_LOG="$TMPROOT/pin.log"
cat > "$HOOKDIR/pin-ops-root.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${CLAUDE_CODE_SESSION_ID:-UNSET}" > "$PIN_LOG"
exit 0
SH
chmod +x "$HOOKDIR/pin-ops-root.sh"

echo "== cursor-session-pin.sh"

out=$(printf '%s' '{}' | (cd "$TMPROOT" && bash "$HOOKDIR/cursor-session-pin.sh") )
if [ "$out" = "{}" ]; then
  mark_pass "empty stdin prints {}"
else
  mark_fail "empty stdin prints {}" "got [$out]"
fi

out=$(printf '%s' '{"session_id":"sess-abc"}' | (cd "$TMPROOT" && bash "$HOOKDIR/cursor-session-pin.sh") )
if printf '%s' "$out" | jq -e '.env.CLAUDE_CODE_SESSION_ID == "sess-abc"' >/dev/null 2>&1; then
  mark_pass "session_id maps onto env.CLAUDE_CODE_SESSION_ID"
else
  mark_fail "session_id maps onto env.CLAUDE_CODE_SESSION_ID" "got [$out]"
fi

if [ -f "$PIN_LOG" ] && [ "$(cat "$PIN_LOG")" = "sess-abc" ]; then
  mark_pass "pin-ops-root.sh runs with CLAUDE_CODE_SESSION_ID set"
else
  mark_fail "pin-ops-root.sh runs with CLAUDE_CODE_SESSION_ID set" "log=$(cat "$PIN_LOG" 2>/dev/null || echo missing)"
fi

rm -f "$PIN_LOG"
out=$(printf '%s' '{"conversation_id":"conv-xyz"}' | (cd "$TMPROOT" && bash "$HOOKDIR/cursor-session-pin.sh") )
if printf '%s' "$out" | jq -e '.env.CLAUDE_CODE_SESSION_ID == "conv-xyz"' >/dev/null 2>&1; then
  mark_pass "conversation_id is accepted as a session id fallback"
else
  mark_fail "conversation_id is accepted as a session id fallback" "got [$out]"
fi

out=$(printf '%s' '{"session_id":"sess-plain"}' | (cd "$PLAIN" && bash "$HOOKDIR/cursor-session-pin.sh") )
if [ "$out" = "{}" ]; then
  mark_pass "non-ops tree prints {}"
else
  mark_fail "non-ops tree prints {}" "got [$out]"
fi

echo
echo "===== test_cursor_session_pin.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED"
  exit 1
fi
exit 0
