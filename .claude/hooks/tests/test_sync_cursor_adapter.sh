#!/usr/bin/env bash
# Smoke tests for bin/sync-cursor-adapter.sh.

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

# Neutralize the Claude Code session-pin artifact so the generated wrapper's
# ops-root resolution falls through to the directory-walk branch, same as it
# would under a real Cursor session (which never sets this var).
unset CLAUDE_CODE_SESSION_ID

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/cursor-adapter-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

mkdir -p "$TMPROOT/.claude/hooks"
touch "$TMPROOT/.apexyard-fork"

cat > "$TMPROOT/.claude/hooks/block-test.sh" <<'SH'
#!/usr/bin/env bash
input=$(cat)
case "$input" in
  *deny*) exit 2 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$TMPROOT/.claude/hooks/block-test.sh"

cat > "$TMPROOT/.claude/hooks/unconditional-test.sh" <<'SH'
#!/usr/bin/env bash
input=$(cat)
case "$input" in
  *unconditional-deny*) exit 2 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$TMPROOT/.claude/hooks/unconditional-test.sh"

cat > "$TMPROOT/.claude/hooks/check-secrets.sh" <<'SH'
#!/usr/bin/env bash
input=$(cat)
case "$input" in
  *secret*) exit 2 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$TMPROOT/.claude/hooks/check-secrets.sh"

cat > "$TMPROOT/.claude/hooks/require-active-ticket.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 0
SH
chmod +x "$TMPROOT/.claude/hooks/require-active-ticket.sh"

cat > "$TMPROOT/.claude/hooks/pin-ops-root.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 0
SH
chmod +x "$TMPROOT/.claude/hooks/pin-ops-root.sh"

cat > "$TMPROOT/.claude/hooks/require-migration-ticket.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 0
SH
chmod +x "$TMPROOT/.claude/hooks/require-migration-ticket.sh"

# Fixture settings.json exercises: a Bash(glob) predicate hook, an
# unconditional Bash hook (no `if`), a fail-closed-eligible hook
# (check-secrets.sh), an Edit|Write|MultiEdit hook, a second
# Edit|Write|MultiEdit hook that is ALSO fail-closed-eligible
# (require-migration-ticket.sh — #840 B3), and a SessionStart hook —
# covering every branch the generator's event-mapping table has to handle.
cat > "$TMPROOT/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "bash -c 'r=\"\";if [ -n \"${CLAUDE_CODE_SESSION_ID:-}\" ];then p=\"${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID}\";[ -f \"$p\" ] && IFS= read -r r < \"$p\" && [ -d \"$r/.claude/hooks\" ] || r=\"\";fi;if [ -z \"$r\" ];then r=$PWD;while [ -n \"$r\" ] && [ \"$r\" != / ];do { [ -f \"$r/.apexyard-fork\" ] || [ -f \"$r/onboarding.yaml\" ]; } && [ -d \"$r/.claude/hooks\" ] && break;r=${r%/*};done;fi;[ -d \"$r/.claude/hooks\" ] || exit 0;exec \"$r/.claude/hooks/pin-ops-root.sh\"'" }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "if": "Bash(policy *)",
            "command": "bash -c 'r=\"\";if [ -n \"${CLAUDE_CODE_SESSION_ID:-}\" ];then p=\"${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID}\";[ -f \"$p\" ] && IFS= read -r r < \"$p\" && [ -d \"$r/.claude/hooks\" ] || r=\"\";fi;if [ -z \"$r\" ];then r=$PWD;while [ -n \"$r\" ] && [ \"$r\" != / ];do { [ -f \"$r/.apexyard-fork\" ] || [ -f \"$r/onboarding.yaml\" ]; } && [ -d \"$r/.claude/hooks\" ] && break;r=${r%/*};done;fi;[ -d \"$r/.claude/hooks\" ] || exit 0;exec \"$r/.claude/hooks/block-test.sh\"'"
          },
          {
            "type": "command",
            "command": "bash -c 'r=\"\";if [ -n \"${CLAUDE_CODE_SESSION_ID:-}\" ];then p=\"${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID}\";[ -f \"$p\" ] && IFS= read -r r < \"$p\" && [ -d \"$r/.claude/hooks\" ] || r=\"\";fi;if [ -z \"$r\" ];then r=$PWD;while [ -n \"$r\" ] && [ \"$r\" != / ];do { [ -f \"$r/.apexyard-fork\" ] || [ -f \"$r/onboarding.yaml\" ]; } && [ -d \"$r/.claude/hooks\" ] && break;r=${r%/*};done;fi;[ -d \"$r/.claude/hooks\" ] || exit 0;exec \"$r/.claude/hooks/unconditional-test.sh\"'"
          },
          {
            "type": "command",
            "if": "Bash(git commit *)",
            "command": "bash -c 'r=\"\";if [ -n \"${CLAUDE_CODE_SESSION_ID:-}\" ];then p=\"${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID}\";[ -f \"$p\" ] && IFS= read -r r < \"$p\" && [ -d \"$r/.claude/hooks\" ] || r=\"\";fi;if [ -z \"$r\" ];then r=$PWD;while [ -n \"$r\" ] && [ \"$r\" != / ];do { [ -f \"$r/.apexyard-fork\" ] || [ -f \"$r/onboarding.yaml\" ]; } && [ -d \"$r/.claude/hooks\" ] && break;r=${r%/*};done;fi;[ -d \"$r/.claude/hooks\" ] || exit 0;exec \"$r/.claude/hooks/check-secrets.sh\"'"
          }
        ]
      },
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash -c 'r=\"\";if [ -n \"${CLAUDE_CODE_SESSION_ID:-}\" ];then p=\"${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID}\";[ -f \"$p\" ] && IFS= read -r r < \"$p\" && [ -d \"$r/.claude/hooks\" ] || r=\"\";fi;if [ -z \"$r\" ];then r=$PWD;while [ -n \"$r\" ] && [ \"$r\" != / ];do { [ -f \"$r/.apexyard-fork\" ] || [ -f \"$r/onboarding.yaml\" ]; } && [ -d \"$r/.claude/hooks\" ] && break;r=${r%/*};done;fi;[ -d \"$r/.claude/hooks\" ] || exit 0;exec \"$r/.claude/hooks/require-active-ticket.sh\"'"
          },
          {
            "type": "command",
            "command": "bash -c 'r=\"\";if [ -n \"${CLAUDE_CODE_SESSION_ID:-}\" ];then p=\"${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID}\";[ -f \"$p\" ] && IFS= read -r r < \"$p\" && [ -d \"$r/.claude/hooks\" ] || r=\"\";fi;if [ -z \"$r\" ];then r=$PWD;while [ -n \"$r\" ] && [ \"$r\" != / ];do { [ -f \"$r/.apexyard-fork\" ] || [ -f \"$r/onboarding.yaml\" ]; } && [ -d \"$r/.claude/hooks\" ] && break;r=${r%/*};done;fi;[ -d \"$r/.claude/hooks\" ] || exit 0;exec \"$r/.claude/hooks/require-migration-ticket.sh\"'"
          }
        ]
      }
    ]
  }
}
JSON

echo "== Cursor adapter sync smoke"

if bash "$SCRIPT" --root "$TMPROOT" >/tmp/_cursor_adapter_sync.out 2>&1; then
  mark_pass "generator writes adapter output"
else
  mark_fail "generator writes adapter output" "$(cat /tmp/_cursor_adapter_sync.out)"
fi

assert_file "$TMPROOT/.cursor/hooks.json" "hooks.json exists"
assert_file "$TMPROOT/.cursor/rules/apexyard.mdc" "rules bridge exists"

# --- config shape -----------------------------------------------------
if jq -e '.version == 1' "$TMPROOT/.cursor/hooks.json" >/dev/null 2>&1; then
  mark_pass "hooks.json has version 1"
else
  mark_fail "hooks.json has version 1" "wrong or missing .version"
fi

if jq -e '.hooks.beforeShellExecution | length == 3' "$TMPROOT/.cursor/hooks.json" >/dev/null 2>&1; then
  mark_pass "beforeShellExecution has one entry per Bash-matcher hook"
else
  mark_fail "beforeShellExecution has one entry per Bash-matcher hook" "$(jq '.hooks.beforeShellExecution | length' "$TMPROOT/.cursor/hooks.json")"
fi

if jq -e '.hooks.preToolUse[0].matcher == "Write"' "$TMPROOT/.cursor/hooks.json" >/dev/null 2>&1; then
  mark_pass "Edit|Write|MultiEdit maps to preToolUse matcher Write"
else
  mark_fail "Edit|Write|MultiEdit maps to preToolUse matcher Write" "unexpected preToolUse[0]"
fi

if jq -e '.hooks.sessionStart | length == 1' "$TMPROOT/.cursor/hooks.json" >/dev/null 2>&1; then
  mark_pass "SessionStart maps to sessionStart"
else
  mark_fail "SessionStart maps to sessionStart" "$(jq '.hooks.sessionStart' "$TMPROOT/.cursor/hooks.json")"
fi

assert_not_contains "$TMPROOT/.cursor/hooks.json" "$TMPROOT" "hooks.json has no absolute fixture path"
assert_not_contains "$TMPROOT/.cursor/rules/apexyard.mdc" "$TMPROOT" "rules bridge has no absolute fixture path"

if jq -e '.. | objects | select(has("if"))' "$TMPROOT/.cursor/hooks.json" >/dev/null 2>&1; then
  mark_fail "hooks.json omits unsupported if fields" "found handler-level if metadata"
else
  mark_pass "hooks.json omits unsupported if fields"
fi

# --- failClosed on the security-critical gate, not on the ticket gate -
if jq -e '[.hooks.beforeShellExecution[] | select(.command | contains("check-secrets.sh")) | .failClosed] == [true]' "$TMPROOT/.cursor/hooks.json" >/dev/null 2>&1; then
  mark_pass "failClosed is set on the security-critical gate (check-secrets.sh)"
else
  mark_fail "failClosed is set on the security-critical gate (check-secrets.sh)" "missing failClosed:true"
fi

if jq -e '[.hooks.beforeShellExecution[] | select(.command | contains("block-test.sh")) | .failClosed] == [null]' "$TMPROOT/.cursor/hooks.json" >/dev/null 2>&1; then
  mark_pass "failClosed is absent on a non-security-critical gate (block-test.sh)"
else
  mark_fail "failClosed is absent on a non-security-critical gate (block-test.sh)" "unexpected failClosed"
fi

# --- failClosed on the migration blast-radius gate (#840 B3) -----------
if jq -e '[.hooks.preToolUse[] | select(.command | contains("require-migration-ticket.sh")) | .failClosed] == [true]' "$TMPROOT/.cursor/hooks.json" >/dev/null 2>&1; then
  mark_pass "failClosed is set on the migration blast-radius gate (require-migration-ticket.sh)"
else
  mark_fail "failClosed is set on the migration blast-radius gate (require-migration-ticket.sh)" "missing failClosed:true"
fi

if jq -e '[.hooks.preToolUse[] | select(.command | contains("require-active-ticket.sh")) | .failClosed] == [null]' "$TMPROOT/.cursor/hooks.json" >/dev/null 2>&1; then
  mark_pass "failClosed is absent on the general ticket-first gate (require-active-ticket.sh)"
else
  mark_fail "failClosed is absent on the general ticket-first gate (require-active-ticket.sh)" "unexpected failClosed"
fi

# --- delegation exec: block / allow / skip across the remap boundary --
predicate_cmd=$(jq -r '.hooks.beforeShellExecution[] | select(.command | contains("block-test.sh")) | .command' "$TMPROOT/.cursor/hooks.json")

printf '{"command":"policy deny","cwd":"/tmp"}' | (cd "$TMPROOT" && bash -c "$predicate_cmd") >/tmp/_cursor_adapter_block.out 2>&1
block_rc=$?
if [ "$block_rc" -eq 2 ]; then
  mark_pass "generated hook command preserves blocking exit (predicate match)"
else
  mark_fail "generated hook command preserves blocking exit (predicate match)" "expected exit 2, got $block_rc: $(cat /tmp/_cursor_adapter_block.out)"
fi

printf '{"command":"policy allow","cwd":"/tmp"}' | (cd "$TMPROOT" && bash -c "$predicate_cmd") >/tmp/_cursor_adapter_allow.out 2>&1
allow_rc=$?
if [ "$allow_rc" -eq 0 ]; then
  mark_pass "generated hook command preserves allowing exit (predicate match)"
else
  mark_fail "generated hook command preserves allowing exit (predicate match)" "expected exit 0, got $allow_rc: $(cat /tmp/_cursor_adapter_allow.out)"
fi

printf '{"command":"other deny","cwd":"/tmp"}' | (cd "$TMPROOT" && bash -c "$predicate_cmd") >/tmp/_cursor_adapter_skip.out 2>&1
skip_rc=$?
if [ "$skip_rc" -eq 0 ]; then
  mark_pass "generated hook command skips nonmatching predicates"
else
  mark_fail "generated hook command skips nonmatching predicates" "expected exit 0, got $skip_rc: $(cat /tmp/_cursor_adapter_skip.out)"
fi

# --- unconditional Bash hook (no `if`) still gets remapped ------------
unconditional_cmd=$(jq -r '.hooks.beforeShellExecution[] | select(.command | contains("unconditional-test.sh")) | .command' "$TMPROOT/.cursor/hooks.json")

printf '{"command":"anything unconditional-deny here","cwd":"/tmp"}' | (cd "$TMPROOT" && bash -c "$unconditional_cmd") >/tmp/_cursor_adapter_uncond_block.out 2>&1
uncond_block_rc=$?
if [ "$uncond_block_rc" -eq 2 ]; then
  mark_pass "unconditional Bash hook still blocks via the remap"
else
  mark_fail "unconditional Bash hook still blocks via the remap" "expected exit 2, got $uncond_block_rc: $(cat /tmp/_cursor_adapter_uncond_block.out)"
fi

printf '{"command":"anything else","cwd":"/tmp"}' | (cd "$TMPROOT" && bash -c "$unconditional_cmd") >/tmp/_cursor_adapter_uncond_allow.out 2>&1
uncond_allow_rc=$?
if [ "$uncond_allow_rc" -eq 0 ]; then
  mark_pass "unconditional Bash hook allows on no match"
else
  mark_fail "unconditional Bash hook allows on no match" "expected exit 0, got $uncond_allow_rc: $(cat /tmp/_cursor_adapter_uncond_allow.out)"
fi

# --- preToolUse (Edit|Write|MultiEdit) passthrough exit-code preservation
write_cmd=$(jq -r '.hooks.preToolUse[0].command' "$TMPROOT/.cursor/hooks.json")
printf '{"tool_name":"Write","tool_input":{"file_path":"foo.txt"}}' | (cd "$TMPROOT" && bash -c "$write_cmd") >/tmp/_cursor_adapter_write.out 2>&1
write_rc=$?
if [ "$write_rc" -eq 0 ]; then
  mark_pass "preToolUse passthrough delegates and preserves exit code"
else
  mark_fail "preToolUse passthrough delegates and preserves exit code" "expected exit 0, got $write_rc: $(cat /tmp/_cursor_adapter_write.out)"
fi

# --- rules bridge sanity -----------------------------------------------
assert_contains "$TMPROOT/.cursor/rules/apexyard.mdc" "alwaysApply: true" "rules bridge sets alwaysApply"
assert_contains "$TMPROOT/.cursor/rules/apexyard.mdc" "CLAUDE.md" "rules bridge points at CLAUDE.md"
assert_contains "$TMPROOT/.cursor/rules/apexyard.mdc" "sync-cursor-adapter.sh" "rules bridge documents regeneration"

# --- drift check ---------------------------------------------------------
if bash "$SCRIPT" --root "$TMPROOT" --check >/tmp/_cursor_adapter_check.out 2>&1; then
  mark_pass "--check passes when generated output is current"
else
  mark_fail "--check passes when generated output is current" "$(cat /tmp/_cursor_adapter_check.out)"
fi

cp "$TMPROOT/.claude/settings.json" "$TMPROOT/.claude/settings.json.bak"
jq '.hooks.PreToolUse[0].hooks[0].if = "Bash(drift *)"' "$TMPROOT/.claude/settings.json" > "$TMPROOT/.claude/settings.json.new"
mv "$TMPROOT/.claude/settings.json.new" "$TMPROOT/.claude/settings.json"
if bash "$SCRIPT" --root "$TMPROOT" --check >/tmp/_cursor_adapter_check_drift.out 2>&1; then
  mark_fail "--check detects drift" "expected non-zero exit"
else
  mark_pass "--check detects drift"
fi
mv "$TMPROOT/.claude/settings.json.bak" "$TMPROOT/.claude/settings.json"

# --- fail-loud hook-count guard on an unrecognized matcher (#840 B2) ----
# generate_hooks_json hardcodes a recognized-matcher allowlist (Bash,
# Edit|Write|MultiEdit, Write, Read|Glob|Grep for PreToolUse; Bash,
# Write|Edit|MultiEdit for PostToolUse). Wire a hook to a matcher shape
# outside that allowlist and confirm the generator now hard-fails instead
# of silently omitting it from .cursor/hooks.json — the exact "silent
# gate-hole" scenario Rex flagged on #838.
cp "$TMPROOT/.claude/settings.json" "$TMPROOT/.claude/settings.json.bak"
jq '.hooks.PreToolUse += [{"matcher": "NotebookEdit", "hooks": [{"type": "command", "command": "bash -c \"exec .claude/hooks/require-active-ticket.sh\""}]}]' \
  "$TMPROOT/.claude/settings.json" > "$TMPROOT/.claude/settings.json.new"
mv "$TMPROOT/.claude/settings.json.new" "$TMPROOT/.claude/settings.json"
if bash "$SCRIPT" --root "$TMPROOT" >/tmp/_cursor_adapter_unmapped.out 2>&1; then
  mark_fail "generator hard-fails on an unrecognized matcher" "expected non-zero exit; generator silently succeeded"
else
  mark_pass "generator hard-fails on an unrecognized matcher"
fi
if grep -F "NotebookEdit" /tmp/_cursor_adapter_unmapped.out >/dev/null 2>&1; then
  mark_pass "hard-fail error names the dropped matcher (NotebookEdit)"
else
  mark_fail "hard-fail error names the dropped matcher (NotebookEdit)" "$(cat /tmp/_cursor_adapter_unmapped.out)"
fi
mv "$TMPROOT/.claude/settings.json.bak" "$TMPROOT/.claude/settings.json"
# Regenerate from the restored (valid) fixture so the subsequent --clean
# test below observes a clean, non-error state.
bash "$SCRIPT" --root "$TMPROOT" >/dev/null 2>&1

# --- --clean removes then regenerates .cursor --------------------------
if bash "$SCRIPT" --root "$TMPROOT" --clean >/tmp/_cursor_adapter_clean.out 2>&1; then
  mark_pass "--clean regenerates .cursor"
else
  mark_fail "--clean regenerates .cursor" "$(cat /tmp/_cursor_adapter_clean.out)"
fi
assert_file "$TMPROOT/.cursor/hooks.json" "hooks.json exists after --clean"

# --- --user mode: merge into a USER-level hooks.json (me2resh/apexyard#840
# finding #3 — Cursor 3.x only loads the user config, not project
# .cursor/hooks.json). Uses --user-dir to point at a throwaway fixture
# directory — MUST NEVER touch a real $HOME. ---------------------------
echo "== Cursor adapter --user merge"

USERDIR="$TMPROOT/fake-home/.cursor"
mkdir -p "$USERDIR"

# Seed the "existing user config" with one entry that is NOT apexyard's
# (must survive every merge) and one stale apexyard-owned entry (must be
# replaced, not duplicated, on every run).
cat > "$USERDIR/hooks.json" <<'JSON'
{
  "version": 1,
  "hooks": {
    "beforeShellExecution": [
      { "command": "some-other-tool --check" },
      { "command": "bash -c 'exec /some/old/path/.claude/hooks/stale-hook.sh'" }
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

if jq -e '[.hooks.beforeShellExecution[] | select(.command == "some-other-tool --check")] | length == 1' "$USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_pass "--user preserves a pre-existing non-apexyard hook entry"
else
  mark_fail "--user preserves a pre-existing non-apexyard hook entry" "$(jq '.hooks.beforeShellExecution' "$USERDIR/hooks.json")"
fi

if jq -e '[.hooks.beforeShellExecution[] | select(.command | contains("stale-hook.sh"))] | length == 0' "$USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_pass "--user drops the stale apexyard-owned entry it replaces"
else
  mark_fail "--user drops the stale apexyard-owned entry it replaces" "stale-hook.sh entry still present"
fi

if jq -e '[.hooks.beforeShellExecution[] | select(.command | contains(".claude/hooks/check-secrets.sh"))] | length == 1' "$USERDIR/hooks.json" >/dev/null 2>&1; then
  mark_pass "--user installs the freshly generated apexyard entries"
else
  mark_fail "--user installs the freshly generated apexyard entries" "$(jq '.hooks.beforeShellExecution' "$USERDIR/hooks.json")"
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

before_count=$(jq '[.hooks.beforeShellExecution[]] | length' "$USERDIR/hooks.json")
if bash "$SCRIPT" --root "$TMPROOT" --user --user-dir "$USERDIR" >/tmp/_cursor_adapter_user2.out 2>&1; then
  mark_pass "--user re-run succeeds"
else
  mark_fail "--user re-run succeeds" "$(cat /tmp/_cursor_adapter_user2.out)"
fi
after_count=$(jq '[.hooks.beforeShellExecution[]] | length' "$USERDIR/hooks.json")
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

jq '.hooks.beforeShellExecution |= map(select((.command | contains(".claude/hooks/check-secrets.sh")) | not))' "$USERDIR/hooks.json" > "$USERDIR/hooks.json.tmp"
mv "$USERDIR/hooks.json.tmp" "$USERDIR/hooks.json"
if bash "$SCRIPT" --root "$TMPROOT" --user --user-dir "$USERDIR" --check >/tmp/_cursor_adapter_user_check3.out 2>&1; then
  mark_fail "--user --check detects drift when an apexyard entry is removed" "expected non-zero exit"
else
  mark_pass "--user --check detects drift when an apexyard entry is removed"
fi

# --- --user mode against a directory with no pre-existing hooks.json ----
FRESH_USERDIR="$TMPROOT/fake-home-fresh/.cursor"
if bash "$SCRIPT" --root "$TMPROOT" --user --user-dir "$FRESH_USERDIR" >/tmp/_cursor_adapter_user_fresh.out 2>&1; then
  mark_pass "--user creates the user config from scratch when absent"
else
  mark_fail "--user creates the user config from scratch when absent" "$(cat /tmp/_cursor_adapter_user_fresh.out)"
fi
assert_file "$FRESH_USERDIR/hooks.json" "fresh user hooks.json exists"

echo
echo "===== test_sync_cursor_adapter.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED"
  exit 1
fi
exit 0
