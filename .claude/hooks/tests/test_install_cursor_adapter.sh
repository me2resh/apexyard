#!/usr/bin/env bash
# Smoke tests for bin/install-cursor-adapter.sh — the install/uninstall
# lifecycle wrapper around `bin/sync-cursor-adapter.sh --user` (#840).
# Complements test_sync_cursor_adapter.sh's --user assertions (which cover
# the merge/idempotency/drift logic in the generator itself); this file
# covers install-cursor-adapter.sh's own surface: default invocation,
# --uninstall, and its scoped-removal / backup guarantees.

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

# Never let this test touch a real $HOME — every invocation below passes an
# explicit --user-dir into a throwaway fixture tree.
unset CLAUDE_CODE_SESSION_ID

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/install-cursor-adapter-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

mkdir -p "$TMPROOT/.claude/hooks" "$TMPROOT/bin"
touch "$TMPROOT/.apexyard-fork"

# install-cursor-adapter.sh's --root is "the repo where bin/ and .claude/
# live together" (the same repo, not a separate framework clone — every
# apexyard-governed project carries its own copy of both). Mirror that
# shape in the fixture: copy the real generator script in alongside a
# synthetic .claude/ tree, so this test drives the real
# sync-cursor-adapter.sh logic without depending on — or mutating — this
# repo's own live .claude/ or .cursor/ state.
cp "$ROOT/bin/sync-cursor-adapter.sh" "$TMPROOT/bin/sync-cursor-adapter.sh"
chmod +x "$TMPROOT/bin/sync-cursor-adapter.sh"
cat > "$TMPROOT/.claude/hooks/check-secrets.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 0
SH
chmod +x "$TMPROOT/.claude/hooks/check-secrets.sh"

cat > "$TMPROOT/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash -c 'exec \"$PWD/.claude/hooks/check-secrets.sh\"'" }
        ]
      }
    ]
  }
}
JSON

USERDIR="$TMPROOT/fake-home/.cursor"

echo "== install-cursor-adapter.sh install"

if bash "$SCRIPT" --root "$TMPROOT" --user-dir "$USERDIR" >/tmp/_install_cursor.out 2>&1; then
  mark_pass "default invocation installs into --user-dir"
else
  mark_fail "default invocation installs into --user-dir" "$(cat /tmp/_install_cursor.out)"
fi

assert_file "$USERDIR/hooks.json" "user hooks.json exists after install"
assert_file "$TMPROOT/.cursor/rules/apexyard.mdc" "project rules bridge exists after install"

if jq -e '[.hooks.beforeShellExecution[] | select(.command | contains("check-secrets.sh"))] | length == 1' "$USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_pass "installed hooks.json carries the generated apexyard entry"
else
  mark_fail "installed hooks.json carries the generated apexyard entry" "$(jq '.hooks' "$USERDIR/hooks.json")"
fi

if grep -F "MainThreadShellExec" /tmp/_install_cursor.out >/dev/null 2>&1 && grep -F "cursor-agent" /tmp/_install_cursor.out >/dev/null 2>&1; then
  mark_pass "install output names the failClosed + CLI-not-covered limitations"
else
  mark_fail "install output names the failClosed + CLI-not-covered limitations" "$(cat /tmp/_install_cursor.out)"
fi

echo "== install-cursor-adapter.sh preserves a foreign hook across re-install"

jq '.hooks.beforeShellExecution += [{"command": "some-other-tool --scan"}]' "$USERDIR/hooks.json" > "$USERDIR/hooks.json.tmp"
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

echo "== install-cursor-adapter.sh --uninstall"

if bash "$SCRIPT" --user-dir "$USERDIR" --uninstall >/tmp/_uninstall_cursor.out 2>&1; then
  mark_pass "--uninstall succeeds"
else
  mark_fail "--uninstall succeeds" "$(cat /tmp/_uninstall_cursor.out)"
fi

if jq -e '[.hooks.beforeShellExecution[]? | select(.command | contains("check-secrets.sh"))] | length == 0' "$USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_pass "--uninstall removes the apexyard-owned entry"
else
  mark_fail "--uninstall removes the apexyard-owned entry" "$(jq '.hooks' "$USERDIR/hooks.json")"
fi

if jq -e '[.hooks.beforeShellExecution[]? | select(.command == "some-other-tool --scan")] | length == 1' "$USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_pass "--uninstall leaves the foreign hook entry alone"
else
  mark_fail "--uninstall leaves the foreign hook entry alone" "$(jq '.hooks' "$USERDIR/hooks.json")"
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
