#!/bin/bash
# Tests for suggest-mcp-search.sh advisory hook (#418, #469, #489).
# Run: bash .claude/hooks/tests/test_suggest_mcp_search.sh
#
# #469: the hook now (a) emits its advisory as hookSpecificOutput.additional
# Context JSON on STDOUT (exit 0, non-blocking) so the model actually reads it,
# and (b) is install-gated — it only fires when `apexyard-search` is configured
# in a resolvable .mcp.json. These tests inject the gate via a temp
# $APEXYARD_PORTFOLIO_ROOT/.mcp.json fixture.
#
# #489: the hook also fires on Read/Glob/Grep when the target path is inside
# a managed-project workspace clone (workspace/<project>/). The install-gate
# applies equally — free adopters without apexyard-search see nothing.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/suggest-mcp-search.sh"
PASS=0
FAIL=0

# --- Fixtures: a portfolio root WITH apexyard-search, and one WITHOUT --------
MCP_DIR=$(mktemp -d)
printf '%s' '{"mcpServers":{"apexyard-search":{"command":"apexyard-search"}}}' > "$MCP_DIR/.mcp.json"

NO_MCP_DIR=$(mktemp -d)
printf '%s' '{"mcpServers":{"some-other-server":{}}}' > "$NO_MCP_DIR/.mcp.json"

cleanup() { rm -rf "$MCP_DIR" "$NO_MCP_DIR"; }
trap cleanup EXIT

# run_hook <input-json> <portfolio_root>  → prints the hook's stdout
run_hook() {
  echo "$1" | APEXYARD_PORTFOLIO_ROOT="$2" bash "$HOOK"
}

# assert the hook emitted a well-formed additionalContext advisory on stdout
assert_advisory() {
  local desc="$1" input="$2"
  local out
  out=$(run_hook "$input" "$MCP_DIR")
  if echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
        and (.hookSpecificOutput.additionalContext | test("search_code"))' >/dev/null 2>&1; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc — expected additionalContext JSON, got: $out"
  fi
}

# assert the hook stayed silent (no output) under the given portfolio root
assert_silent() {
  local desc="$1" input="$2" portfolio="$3"
  local out
  out=$(run_hook "$input" "$portfolio")
  if [ -z "$out" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc — expected silence, got: $out"
  fi
}

# --- Gate OPEN (apexyard-search configured) + a workspace/framework search ---

assert_advisory "grep -r on roles/" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -r \"activation\" roles/"}}'

assert_advisory "grep -rn on workspace/<proj>" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -rn \"export\" workspace/example-app/src/"}}'

assert_advisory "grep on docs/agdr" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -r \"migration\" docs/agdr/"}}'

assert_advisory "find on templates/" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"find templates/ -name \"*.md\""}}'

assert_advisory "piped grep on skills/" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat skills/debug/SKILL.md | grep hypothesis"}}'

# --- Non-blocking: the advisory is valid JSON (jq parses) -------------------
adv_out=$(run_hook '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -rn x workspace/p/"}}' "$MCP_DIR")
if echo "$adv_out" | jq -e . >/dev/null 2>&1; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: advisory output must be valid JSON, got: $adv_out"
fi

# --- Gate CLOSED (apexyard-search NOT configured) → silent even on a match ---

assert_silent "gate closed: no apexyard-search in .mcp.json" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -rn \"export\" workspace/example-app/src/"}}' \
  "$NO_MCP_DIR"

# --- Should NOT fire even with the gate open --------------------------------

assert_silent "non-search command (ls)" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls workspace/"}}' "$MCP_DIR"

assert_silent "search but not a framework/workspace path" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -r \"TODO\" src/"}}' "$MCP_DIR"

assert_silent "Bash: non-grep command (ls)" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls workspace/"}}' "$MCP_DIR"

assert_silent "Bash: non-grep bash command (npm)" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm test"}}' "$MCP_DIR"

# --- Read / Glob / Grep: fire on workspace/ paths (gate OPEN) ---------------

assert_advisory "Read on workspace/<proj> path" \
  '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"workspace/example-app/src/index.ts"}}'

assert_advisory "Glob on workspace/<proj> path" \
  '{"hook_event_name":"PreToolUse","tool_name":"Glob","tool_input":{"path":"workspace/example-app/src/","pattern":"**/*.ts"}}'

assert_advisory "Grep on workspace/<proj> path" \
  '{"hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"path":"workspace/example-app/","pattern":"export"}}'

# --- Read / Glob / Grep: gate CLOSED (free adopter) → silent ----------------

assert_silent "Read: gate closed (no apexyard-search)" \
  '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"workspace/example-app/src/index.ts"}}' \
  "$NO_MCP_DIR"

assert_silent "Glob: gate closed (no apexyard-search)" \
  '{"hook_event_name":"PreToolUse","tool_name":"Glob","tool_input":{"path":"workspace/example-app/src/","pattern":"**/*.ts"}}' \
  "$NO_MCP_DIR"

assert_silent "Grep: gate closed (no apexyard-search)" \
  '{"hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"path":"workspace/example-app/","pattern":"export"}}' \
  "$NO_MCP_DIR"

# --- Read / Glob / Grep: paths OUTSIDE workspace/ → silent even gate open ---

assert_silent "Read: path outside workspace/ (framework file)" \
  '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"roles/engineering/tech-lead.md"}}' "$MCP_DIR"

assert_silent "Read: path outside workspace/ (src/)" \
  '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"src/something.ts"}}' "$MCP_DIR"

assert_silent "Glob: path outside workspace/" \
  '{"hook_event_name":"PreToolUse","tool_name":"Glob","tool_input":{"path":"src/","pattern":"**/*.ts"}}' "$MCP_DIR"

assert_silent "Grep: path outside workspace/" \
  '{"hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"path":"src/","pattern":"export"}}' "$MCP_DIR"

# --- Other tool types → always silent --------------------------------------

assert_silent "Write tool: not triggered" \
  '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"workspace/example-app/src/foo.ts","content":"x"}}' "$MCP_DIR"

assert_silent "Edit tool: not triggered" \
  '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"workspace/example-app/src/foo.ts","old_string":"x","new_string":"y"}}' "$MCP_DIR"

# ===========================================================================
# Gate mode (#651, AgDR-0070): opt-in soft-block (exit 2) on gate-eligible
# Bash searches, with a per-call escape hatch. Read/Glob/Grep never blocked.
# ===========================================================================

# A temp ops root the config lib will resolve to (via the `.apexyard-fork`
# anchor) with mcp_search.gate_mode enabled + apexyard-search configured.
GATE_ROOT=$(mktemp -d)
touch "$GATE_ROOT/.apexyard-fork"
mkdir -p "$GATE_ROOT/.claude"
printf '%s' '{"mcp_search":{"gate_mode":false}}' > "$GATE_ROOT/.claude/project-config.defaults.json"
printf '%s' '{"mcp_search":{"gate_mode":true}}' > "$GATE_ROOT/.claude/project-config.json"
printf '%s' '{"mcpServers":{"apexyard-search":{"command":"apexyard-search"}}}' > "$GATE_ROOT/.mcp.json"
cleanup_gate() { rm -rf "$GATE_ROOT"; }
trap 'cleanup; cleanup_gate' EXIT

# run from cwd=GATE_ROOT so config resolves gate_mode=true; APEXYARD_PORTFOLIO_ROOT
# points the install-gate at the apexyard-search .mcp.json. Pin disabled so the
# resolver walks up to the GATE_ROOT anchor rather than a session pin.
# args: <input-json> [extra env assignment]  → echoes exit code
gate_exit() {
  local input="$1" extra="${2:-}"
  ( cd "$GATE_ROOT" && echo "$input" | \
      env APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_PORTFOLIO_ROOT="$GATE_ROOT" $extra bash "$HOOK" >/dev/null 2>&1 )
  echo $?
}

assert_exit() {
  local desc="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc — expected exit $want, got $got"
  fi
}

SEARCH_CMD='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -r \"activation\" roles/"}}'
ESCAPE_CMD='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"APEXYARD_MCP_FALLBACK=1 grep -r \"activation\" roles/"}}'
READ_CMD='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"workspace/example-app/src/index.ts"}}'

assert_exit "gate ON: exploratory Bash search soft-blocks (exit 2)" 2 "$(gate_exit "$SEARCH_CMD")"
assert_exit "gate ON + per-call escape token → proceeds (exit 0)" 0 "$(gate_exit "$ESCAPE_CMD")"
assert_exit "gate ON + env escape APEXYARD_MCP_FALLBACK=1 → proceeds (exit 0)" 0 "$(gate_exit "$SEARCH_CMD" "APEXYARD_MCP_FALLBACK=1")"
assert_exit "gate ON: Read on workspace/ is NOT blocked (read→edit, exit 0)" 0 "$(gate_exit "$READ_CMD")"

# Gate ON but apexyard-search NOT configured → install-gate keeps it silent (0).
NOGATE_ROOT=$(mktemp -d)
touch "$NOGATE_ROOT/.apexyard-fork"; mkdir -p "$NOGATE_ROOT/.claude"
printf '%s' '{"mcp_search":{"gate_mode":false}}' > "$NOGATE_ROOT/.claude/project-config.defaults.json"
printf '%s' '{"mcp_search":{"gate_mode":true}}' > "$NOGATE_ROOT/.claude/project-config.json"
printf '%s' '{"mcpServers":{"other":{}}}' > "$NOGATE_ROOT/.mcp.json"
nogate_exit=$( cd "$NOGATE_ROOT" && echo "$SEARCH_CMD" | env APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_PORTFOLIO_ROOT="$NOGATE_ROOT" bash "$HOOK" >/dev/null 2>&1; echo $? )
assert_exit "gate ON but no apexyard-search → install-gate silent (exit 0)" 0 "$nogate_exit"
rm -rf "$NOGATE_ROOT"

# Gate OFF (default) + exploratory search → advisory, never blocks (exit 0).
GATEOFF_ROOT=$(mktemp -d)
touch "$GATEOFF_ROOT/.apexyard-fork"; mkdir -p "$GATEOFF_ROOT/.claude"
printf '%s' '{"mcp_search":{"gate_mode":false}}' > "$GATEOFF_ROOT/.claude/project-config.defaults.json"
printf '%s' '{"mcp_search":{"gate_mode":false}}' > "$GATEOFF_ROOT/.claude/project-config.json"
printf '%s' '{"mcpServers":{"apexyard-search":{"command":"apexyard-search"}}}' > "$GATEOFF_ROOT/.mcp.json"
gateoff_exit=$( cd "$GATEOFF_ROOT" && echo "$SEARCH_CMD" | env APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_PORTFOLIO_ROOT="$GATEOFF_ROOT" bash "$HOOK" >/dev/null 2>&1; echo $? )
assert_exit "gate OFF (default) → advisory, never blocks (exit 0)" 0 "$gateoff_exit"
rm -rf "$GATEOFF_ROOT"

# --- Report ----------------------------------------------------------------
echo ""
echo "suggest-mcp-search: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
