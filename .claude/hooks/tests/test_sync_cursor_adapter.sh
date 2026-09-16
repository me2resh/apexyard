#!/usr/bin/env bash
# Smoke tests for the thin native-first Cursor overlay generator.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$ROOT/bin/sync-cursor-adapter.sh"

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

assert_contains() {
  local path="$1" pattern="$2" label="$3"
  grep -F "$pattern" "$path" >/dev/null 2>&1 && mark_pass "$label" || mark_fail "$label" "missing pattern [$pattern] in $path"
}

assert_not_contains() {
  local path="$1" pattern="$2" label="$3"
  if grep -F "$pattern" "$path" >/dev/null 2>&1; then
    mark_fail "$label" "unexpected pattern [$pattern] in $path"
  else
    mark_pass "$label"
  fi
}

unset CLAUDE_CODE_SESSION_ID

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/cursor-adapter-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

mkdir -p "$TMPROOT/.claude/hooks"
touch "$TMPROOT/.apexyard-fork"
cp "$ROOT/.claude/hooks/cursor-session-pin.sh" "$TMPROOT/.claude/hooks/cursor-session-pin.sh"
chmod +x "$TMPROOT/.claude/hooks/cursor-session-pin.sh"
cp "$ROOT/.claude/hooks/_lib-ops-root.sh" "$TMPROOT/.claude/hooks/_lib-ops-root.sh"
cat > "$TMPROOT/.claude/hooks/pin-ops-root.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMPROOT/.claude/hooks/pin-ops-root.sh"

# settings.json is NOT an overlay input. Keep a fixture so a regression
# that starts copying gates from it would be visible.
cat > "$TMPROOT/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash -c 'exec .claude/hooks/check-secrets.sh'" }
        ]
      }
    ]
  }
}
JSON

echo "== Cursor overlay sync smoke"

if bash "$SCRIPT" --root "$TMPROOT" >/tmp/_cursor_adapter_sync.out 2>&1; then
  mark_pass "generator writes overlay output"
else
  mark_fail "generator writes overlay output" "$(cat /tmp/_cursor_adapter_sync.out)"
fi

assert_file "$TMPROOT/.cursor/hooks.json" "hooks.json exists"
assert_file "$TMPROOT/.cursor/rules/apexyard.mdc" "rules bridge exists"

if jq -e '.version == 1' "$TMPROOT/.cursor/hooks.json" >/dev/null 2>&1; then
  mark_pass "hooks.json has version 1"
else
  mark_fail "hooks.json has version 1" "wrong or missing .version"
fi

if jq -e '.hooks.sessionStart | length == 1' "$TMPROOT/.cursor/hooks.json" >/dev/null 2>&1; then
  mark_pass "overlay has exactly one sessionStart entry"
else
  mark_fail "overlay has exactly one sessionStart entry" "$(jq '.hooks.sessionStart' "$TMPROOT/.cursor/hooks.json")"
fi

if jq -e '.hooks.sessionStart[0].command == ".claude/hooks/cursor-session-pin.sh"' "$TMPROOT/.cursor/hooks.json" >/dev/null 2>&1; then
  mark_pass "project overlay command is the session pin script"
else
  mark_fail "project overlay command is the session pin script" "$(jq '.hooks.sessionStart[0].command' "$TMPROOT/.cursor/hooks.json")"
fi

if jq -e '(.hooks | keys) == ["sessionStart"]' "$TMPROOT/.cursor/hooks.json" >/dev/null 2>&1; then
  mark_pass "overlay has no other Cursor events"
else
  mark_fail "overlay has no other Cursor events" "$(jq '.hooks | keys' "$TMPROOT/.cursor/hooks.json")"
fi

if jq -e '.. | objects | select(has("failClosed"))' "$TMPROOT/.cursor/hooks.json" >/dev/null 2>&1; then
  mark_fail "overlay omits failClosed" "found failClosed"
else
  mark_pass "overlay omits failClosed"
fi

assert_not_contains "$TMPROOT/.cursor/hooks.json" "check-secrets.sh" "overlay does not copy settings.json gates"
assert_not_contains "$TMPROOT/.cursor/hooks.json" "beforeShellExecution" "overlay does not emit beforeShellExecution"
assert_not_contains "$TMPROOT/.cursor/hooks.json" "APEXYARD_CURSOR_HOOK_GLOB" "overlay does not emit the stdin remap"
assert_not_contains "$TMPROOT/.cursor/hooks.json" "$TMPROOT" "hooks.json has no absolute fixture path"
assert_not_contains "$TMPROOT/.cursor/rules/apexyard.mdc" "$TMPROOT" "rules bridge has no absolute fixture path"

assert_contains "$TMPROOT/.cursor/rules/apexyard.mdc" "alwaysApply: true" "rules bridge sets alwaysApply"
assert_contains "$TMPROOT/.cursor/rules/apexyard.mdc" "CLAUDE.md" "rules bridge points at CLAUDE.md"
assert_contains "$TMPROOT/.cursor/rules/apexyard.mdc" ".claude/rules/evidence-grounding.md" "rules bridge carries evidence-grounding contract"
assert_contains "$TMPROOT/.cursor/rules/apexyard.mdc" ".claude/rules/right-size-ceremony.md" "rules bridge carries proportionate-work rule"
assert_contains "$TMPROOT/.cursor/rules/apexyard.mdc" ".claude/rules/writing-standard.md" "rules bridge carries writing standard"
assert_contains "$TMPROOT/.cursor/rules/apexyard.mdc" ".claude/rules/reporting-style.md" "rules bridge carries reporting style"
assert_contains "$TMPROOT/.cursor/rules/apexyard.mdc" "sync-cursor-adapter.sh" "rules bridge documents regeneration"
assert_contains "$TMPROOT/.cursor/rules/apexyard.mdc" "thin overlay" "rules bridge names the thin overlay"

if bash "$SCRIPT" --root "$TMPROOT" --check >/tmp/_cursor_adapter_check.out 2>&1; then
  mark_pass "--check passes when generated output is current"
else
  mark_fail "--check passes when generated output is current" "$(cat /tmp/_cursor_adapter_check.out)"
fi

jq '.hooks.sessionStart += [{"command": "manual-tamper"}]' "$TMPROOT/.cursor/hooks.json" > "$TMPROOT/.cursor/hooks.json.tmp"
mv "$TMPROOT/.cursor/hooks.json.tmp" "$TMPROOT/.cursor/hooks.json"
if bash "$SCRIPT" --root "$TMPROOT" --check >/tmp/_cursor_adapter_check_drift.out 2>&1; then
  mark_fail "--check detects drift" "expected non-zero exit"
else
  mark_pass "--check detects drift"
fi

if bash "$SCRIPT" --root "$TMPROOT" --clean >/tmp/_cursor_adapter_clean.out 2>&1; then
  mark_pass "--clean regenerates .cursor"
else
  mark_fail "--clean regenerates .cursor" "$(cat /tmp/_cursor_adapter_clean.out)"
fi
assert_file "$TMPROOT/.cursor/hooks.json" "hooks.json exists after --clean"
if jq -e '.hooks.sessionStart | length == 1' "$TMPROOT/.cursor/hooks.json" >/dev/null 2>&1; then
  mark_pass "--clean restores the single sessionStart overlay"
else
  mark_fail "--clean restores the single sessionStart overlay" "$(jq '.hooks' "$TMPROOT/.cursor/hooks.json")"
fi

echo "== Cursor overlay --user merge"

USERDIR="$TMPROOT/fake-home/.cursor"
mkdir -p "$USERDIR"

cat > "$USERDIR/hooks.json" <<'JSON'
{
  "version": 1,
  "hooks": {
    "beforeShellExecution": [
      { "command": "some-other-tool --check" },
      { "command": "bash -c 'exec /some/old/path/.claude/hooks/stale-hook.sh'", "failClosed": true }
    ],
    "preToolUse": [
      { "command": "bash -c 'APEXYARD_CURSOR_HOOK_GLOB=\"*\"; exec /old/.claude/hooks/require-migration-ticket.sh'", "failClosed": true }
    ],
    "beforeMCPExecution": [
      { "command": "unrelated-mcp-guard" }
    ]
  }
}
JSON

if bash "$SCRIPT" --root "$TMPROOT" --user --user-dir "$USERDIR" >/tmp/_cursor_adapter_user.out 2>&1; then
  mark_pass "--user merges into the user-level hooks.json"
else
  mark_fail "--user merges into the user-level hooks.json" "$(cat /tmp/_cursor_adapter_user.out)"
fi

assert_file "$USERDIR/hooks.json" "user hooks.json exists after --user"

if grep -F "full generated apexyard adapter" /tmp/_cursor_adapter_user.out >/dev/null 2>&1; then
  mark_pass "--user warns when a leftover full adapter is present"
else
  mark_fail "--user warns when a leftover full adapter is present" "$(cat /tmp/_cursor_adapter_user.out)"
fi

if jq -e '[.hooks.beforeShellExecution[] | select(.command == "some-other-tool --check")] | length == 1' "$USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_pass "--user preserves a pre-existing non-apexyard hook entry"
else
  mark_fail "--user preserves a pre-existing non-apexyard hook entry" "$(jq '.hooks.beforeShellExecution' "$USERDIR/hooks.json")"
fi

if jq -e '[.hooks.beforeShellExecution[]? | select(.command | contains("stale-hook.sh"))] | length == 0' "$USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_pass "--user drops the stale apexyard-owned entry it replaces"
else
  mark_fail "--user drops the stale apexyard-owned entry it replaces" "stale-hook.sh entry still present"
fi

if jq -e '[.hooks.preToolUse[]? | select(.command | contains("require-migration-ticket.sh"))] | length == 0' "$USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_pass "--user strips leftover failClosed gate copies"
else
  mark_fail "--user strips leftover failClosed gate copies" "$(jq '.hooks.preToolUse' "$USERDIR/hooks.json")"
fi

if jq -e '[.hooks.sessionStart[] | select(.command | contains("cursor-session-pin.sh"))] | length == 1' "$USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_pass "--user installs the thin session-pin overlay"
else
  mark_fail "--user installs the thin session-pin overlay" "$(jq '.hooks.sessionStart' "$USERDIR/hooks.json")"
fi

if jq -e '.. | objects | select(has("failClosed"))' "$USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_fail "--user overlay does not reintroduce failClosed" "found failClosed after merge"
else
  mark_pass "--user overlay does not reintroduce failClosed"
fi

if jq -e '.hooks.beforeMCPExecution[0].command == "unrelated-mcp-guard"' "$USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_pass "--user leaves an untouched, unrelated event array alone"
else
  mark_fail "--user leaves an untouched, unrelated event array alone" "$(jq '.hooks.beforeMCPExecution' "$USERDIR/hooks.json")"
fi

if compgen -G "$USERDIR/hooks.json.bak-*" >/dev/null 2>&1; then
  mark_pass "--user backs up the pre-existing user hooks.json before overwriting"
else
  mark_fail "--user backs up the pre-existing user hooks.json before overwriting" "no hooks.json.bak-* found"
fi

assert_file "$TMPROOT/.cursor/rules/apexyard.mdc" "--user still refreshes the project-level rules bridge"

before_count=$(jq '[.hooks.sessionStart[]] | length' "$USERDIR/hooks.json")
if bash "$SCRIPT" --root "$TMPROOT" --user --user-dir "$USERDIR" >/tmp/_cursor_adapter_user2.out 2>&1; then
  mark_pass "--user re-run succeeds"
else
  mark_fail "--user re-run succeeds" "$(cat /tmp/_cursor_adapter_user2.out)"
fi
after_count=$(jq '[.hooks.sessionStart[]] | length' "$USERDIR/hooks.json")
if [ "$before_count" = "$after_count" ]; then
  mark_pass "--user re-run is idempotent (no duplicate entries)"
else
  mark_fail "--user re-run is idempotent (no duplicate entries)" "count went from $before_count to $after_count"
fi

if bash "$SCRIPT" --root "$TMPROOT" --user --user-dir "$USERDIR" --check >/tmp/_cursor_adapter_user_check.out 2>&1; then
  mark_pass "--user --check passes when the user config is current"
else
  mark_fail "--user --check passes when the user config is current" "$(cat /tmp/_cursor_adapter_user_check.out)"
fi

jq '.hooks.beforeShellExecution += [{"command": "manual-tamper"}]' "$USERDIR/hooks.json" > "$USERDIR/hooks.json.tmp"
mv "$USERDIR/hooks.json.tmp" "$USERDIR/hooks.json"
if bash "$SCRIPT" --root "$TMPROOT" --user --user-dir "$USERDIR" --check >/tmp/_cursor_adapter_user_check2.out 2>&1; then
  mark_pass "--user --check still passes when only a non-apexyard entry was added"
else
  mark_fail "--user --check still passes when only a non-apexyard entry was added" "$(cat /tmp/_cursor_adapter_user_check2.out)"
fi

jq '.hooks.sessionStart |= map(select((.command | contains("cursor-session-pin.sh")) | not))' "$USERDIR/hooks.json" > "$USERDIR/hooks.json.tmp"
mv "$USERDIR/hooks.json.tmp" "$USERDIR/hooks.json"
if bash "$SCRIPT" --root "$TMPROOT" --user --user-dir "$USERDIR" --check >/tmp/_cursor_adapter_user_check3.out 2>&1; then
  mark_fail "--user --check detects drift when the overlay is removed" "expected non-zero exit"
else
  mark_pass "--user --check detects drift when the overlay is removed"
fi

FRESH_USERDIR="$TMPROOT/fake-home-fresh/.cursor"
if bash "$SCRIPT" --root "$TMPROOT" --user --user-dir "$FRESH_USERDIR" >/tmp/_cursor_adapter_user_fresh.out 2>&1; then
  mark_pass "--user creates the user config from scratch when absent"
else
  mark_fail "--user creates the user config from scratch when absent" "$(cat /tmp/_cursor_adapter_user_fresh.out)"
fi
assert_file "$FRESH_USERDIR/hooks.json" "fresh user hooks.json exists"
if jq -e '[.hooks.sessionStart[] | select(.command | contains("cursor-session-pin.sh"))] | length == 1' "$FRESH_USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_pass "fresh user config carries the session-pin overlay"
else
  mark_fail "fresh user config carries the session-pin overlay" "$(jq '.hooks' "$FRESH_USERDIR/hooks.json")"
fi

echo "== user-level overlay command execution"

user_cmd=$(jq -r '.hooks.sessionStart[0].command' "$FRESH_USERDIR/hooks.json")
PLAIN=$(mktemp -d "${TMPDIR:-/tmp}/cursor-adapter-plain.XXXXXX")
YAMLONLY=$(mktemp -d "${TMPDIR:-/tmp}/cursor-adapter-yaml.XXXXXX")
PINDIR=$(mktemp -d "${TMPDIR:-/tmp}/cursor-adapter-pin.XXXXXX")
mkdir -p "$YAMLONLY/.claude/hooks"
touch "$YAMLONLY/onboarding.yaml"

out=$(printf '%s' '{"session_id":"sess-user"}' | (cd "$TMPROOT" && unset CURSOR_PROJECT_DIR CLAUDE_CODE_SESSION_ID && bash -c "$user_cmd") )
if printf '%s' "$out" | jq -e '.env.CLAUDE_CODE_SESSION_ID == "sess-user"' >/dev/null 2>&1; then
  mark_pass "user overlay command maps session_id from the fixture fork"
else
  mark_fail "user overlay command maps session_id from the fixture fork" "got [$out]"
fi

out=$(printf '%s' '{"session_id":"sess-plain"}' | (cd "$PLAIN" && unset CURSOR_PROJECT_DIR CLAUDE_CODE_SESSION_ID && bash -c "$user_cmd") )
if [ "$out" = "{}" ]; then
  mark_pass "user overlay command prints {} outside an ops fork"
else
  mark_fail "user overlay command prints {} outside an ops fork" "got [$out]"
fi

out=$(printf '%s' '{"session_id":"sess-yaml"}' | (cd "$YAMLONLY" && unset CURSOR_PROJECT_DIR CLAUDE_CODE_SESSION_ID && bash -c "$user_cmd") )
if [ "$out" = "{}" ]; then
  mark_pass "user overlay command does not treat onboarding.yaml alone as an ops fork"
else
  mark_fail "user overlay command does not treat onboarding.yaml alone as an ops fork" "got [$out]"
fi

printf '%s\n' "$TMPROOT" > "$PINDIR/ops-root-sess-pin"
out=$(printf '%s' '{"session_id":"sess-pin"}' | (
  cd "$PLAIN" || exit 1
  unset CURSOR_PROJECT_DIR
  export CLAUDE_CODE_SESSION_ID=sess-pin
  export APEXYARD_OPS_PIN_DIR="$PINDIR"
  bash -c "$user_cmd"
) )
if printf '%s' "$out" | jq -e '.env.CLAUDE_CODE_SESSION_ID == "sess-pin"' >/dev/null 2>&1; then
  mark_pass "user overlay command passes the pinned root into the session pin script"
else
  mark_fail "user overlay command passes the pinned root into the session pin script" "got [$out]"
fi
rm -rf "$PLAIN" "$YAMLONLY" "$PINDIR"

echo
echo "===== test_sync_cursor_adapter.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED"
  exit 1
fi
exit 0
