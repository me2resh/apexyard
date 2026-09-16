#!/usr/bin/env bash
# Smoke tests for bin/install-cursor-adapter.sh — the install/uninstall
# lifecycle wrapper around `bin/sync-cursor-adapter.sh --user` (AgDR-0151).

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$ROOT/bin/install-cursor-adapter.sh"

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

assert_file() {
  local path="$1" label="$2"
  [ -f "$path" ] && mark_pass "$label" || mark_fail "$label" "missing $path"
}

unset CLAUDE_CODE_SESSION_ID

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/install-cursor-adapter-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

mkdir -p "$TMPROOT/.claude/hooks" "$TMPROOT/bin"
touch "$TMPROOT/.apexyard-fork"

cp "$ROOT/bin/sync-cursor-adapter.sh" "$TMPROOT/bin/sync-cursor-adapter.sh"
chmod +x "$TMPROOT/bin/sync-cursor-adapter.sh"
cp "$ROOT/.claude/hooks/cursor-session-pin.sh" "$TMPROOT/.claude/hooks/cursor-session-pin.sh"
chmod +x "$TMPROOT/.claude/hooks/cursor-session-pin.sh"

USERDIR="$TMPROOT/fake-home/.cursor"

echo "== install-cursor-adapter.sh install"

if bash "$SCRIPT" --root "$TMPROOT" --user-dir "$USERDIR" >/tmp/_install_cursor.out 2>&1; then
  mark_pass "default invocation installs into --user-dir"
else
  mark_fail "default invocation installs into --user-dir" "$(cat /tmp/_install_cursor.out)"
fi

assert_file "$USERDIR/hooks.json" "user hooks.json exists after install"
assert_file "$TMPROOT/.cursor/rules/apexyard.mdc" "project rules bridge exists after install"

if jq -e '[.hooks.sessionStart[] | select(.command | contains("cursor-session-pin.sh"))] | length == 1' "$USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_pass "installed hooks.json carries the session-pin overlay"
else
  mark_fail "installed hooks.json carries the session-pin overlay" "$(jq '.hooks' "$USERDIR/hooks.json")"
fi

if grep -F "Include third-party" /tmp/_install_cursor.out >/dev/null 2>&1 && grep -F "cursor-agent" /tmp/_install_cursor.out >/dev/null 2>&1; then
  mark_pass "install output names the native-loader toggle and CLI-not-covered limit"
else
  mark_fail "install output names the native-loader toggle and CLI-not-covered limit" "$(cat /tmp/_install_cursor.out)"
fi

if grep -F "MainThreadShellExec" /tmp/_install_cursor.out >/dev/null 2>&1; then
  mark_fail "install output no longer claims the July failClosed limitation" "found MainThreadShellExec"
else
  mark_pass "install output no longer claims the July failClosed limitation"
fi

echo "== install-cursor-adapter.sh preserves a foreign hook across re-install"

jq '.hooks.beforeShellExecution = [{"command": "some-other-tool --scan"}]' "$USERDIR/hooks.json" > "$USERDIR/hooks.json.tmp"
mv "$USERDIR/hooks.json.tmp" "$USERDIR/hooks.json"

if bash "$SCRIPT" --root "$TMPROOT" --user-dir "$USERDIR" >/tmp/_install_cursor_reinstall.out 2>&1; then
  mark_pass "re-install succeeds"
else
  mark_fail "re-install succeeds" "$(cat /tmp/_install_cursor_reinstall.out)"
fi

if jq -e '[.hooks.beforeShellExecution[] | select(.command == "some-other-tool --scan")] | length == 1' "$USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_pass "re-install preserves the foreign hook entry"
else
  mark_fail "re-install preserves the foreign hook entry" "$(jq '.hooks.beforeShellExecution' "$USERDIR/hooks.json")"
fi

if jq -e '[.hooks.sessionStart[] | select(.command | contains("cursor-session-pin.sh"))] | length == 1' "$USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_pass "re-install keeps a single session-pin overlay"
else
  mark_fail "re-install keeps a single session-pin overlay" "$(jq '.hooks.sessionStart' "$USERDIR/hooks.json")"
fi

echo "== install-cursor-adapter.sh --uninstall"

if bash "$SCRIPT" --user-dir "$USERDIR" --uninstall >/tmp/_uninstall_cursor.out 2>&1; then
  mark_pass "--uninstall succeeds"
else
  mark_fail "--uninstall succeeds" "$(cat /tmp/_uninstall_cursor.out)"
fi

if jq -e '[.hooks.sessionStart[]? | select(.command | contains("cursor-session-pin.sh"))] | length == 0' "$USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_pass "--uninstall removes the apexyard-owned overlay"
else
  mark_fail "--uninstall removes the apexyard-owned overlay" "$(jq '.hooks' "$USERDIR/hooks.json")"
fi

if jq -e '[.hooks.beforeShellExecution[]? | select(.command == "some-other-tool --scan")] | length == 1' "$USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_pass "--uninstall leaves the foreign hook entry alone"
else
  mark_fail "--uninstall leaves the foreign hook entry alone" "$(jq '.hooks.beforeShellExecution' "$USERDIR/hooks.json")"
fi

if compgen -G "$USERDIR/hooks.json.bak-*" >/dev/null 2>&1; then
  mark_pass "--uninstall writes a backup before modifying"
else
  mark_fail "--uninstall writes a backup before modifying" "no hooks.json.bak-* found"
fi

echo "== install-cursor-adapter.sh --uninstall is a no-op with nothing installed"

EMPTY_USERDIR="$TMPROOT/fake-home-empty/.cursor"
if bash "$SCRIPT" --user-dir "$EMPTY_USERDIR" --uninstall >/tmp/_uninstall_cursor_empty.out 2>&1; then
  mark_pass "--uninstall on a missing user config exits cleanly"
else
  mark_fail "--uninstall on a missing user config exits cleanly" "$(cat /tmp/_uninstall_cursor_empty.out)"
fi
if [ -f "$EMPTY_USERDIR/hooks.json" ]; then
  mark_fail "--uninstall does not fabricate a hooks.json when none existed" "hooks.json was created"
else
  mark_pass "--uninstall does not fabricate a hooks.json when none existed"
fi

echo
echo "===== test_install_cursor_adapter.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED"
  exit 1
fi
exit 0
