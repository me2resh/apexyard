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

# --- Report ----------------------------------------------------------------
echo ""
echo "suggest-mcp-search: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
