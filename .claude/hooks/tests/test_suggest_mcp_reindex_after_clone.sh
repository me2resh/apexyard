#!/bin/bash
# Tests for suggest-mcp-reindex-after-clone.sh advisory hook
# Run: bash .claude/hooks/tests/test_suggest_mcp_reindex_after_clone.sh

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/suggest-mcp-reindex-after-clone.sh"
PASS=0
FAIL=0

run_hook() {
  echo "$1" | bash "$HOOK" 2>&1
}

assert_banner_contains() {
  local desc="$1" input="$2" needle="$3"
  local output
  output=$(run_hook "$input")
  if echo "$output" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc — expected banner containing '$needle', got: $output"
  fi
}

assert_no_banner() {
  local desc="$1" input="$2"
  local output
  output=$(run_hook "$input")
  if [ -z "$output" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc — expected no output, got: $output"
  fi
}

# --- Should fire: workspace/ clone, exit 0 ---

assert_banner_contains "single-fork form — workspace/<name>" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git clone https://github.com/owner/example.git workspace/example"},"tool_response":{"exit_code":0}}' \
  "Repo cloned into workspace/example/"

assert_banner_contains "single-fork form — banner mentions reindex command" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git clone https://github.com/owner/example.git workspace/example"},"tool_response":{"exit_code":0}}' \
  "mcp__apexyard-search__reindex"

assert_banner_contains "quoted target" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git clone https://github.com/owner/foo.git \"workspace/foo\""},"tool_response":{"exit_code":0}}' \
  "Repo cloned into workspace/foo/"

assert_banner_contains "absolute path via portfolio helper" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git clone https://github.com/owner/bar.git /Users/me/portfolio/workspace/bar"},"tool_response":{"exit_code":0}}' \
  "mcp__apexyard-search__reindex"

assert_banner_contains "project name extracted from absolute path" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git clone https://github.com/owner/bar.git /Users/me/portfolio/workspace/bar"},"tool_response":{"exit_code":0}}' \
  'project="bar"'

# --- Should NOT fire ---

assert_no_banner "clone target is NOT workspace/<name>" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git clone https://github.com/owner/example.git /tmp/scratch"},"tool_response":{"exit_code":0}}'

assert_no_banner "not a git clone — just a grep that mentions clone" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"grep -r \"git clone\" workspace/"},"tool_response":{"exit_code":0}}'

assert_no_banner "no command at all" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{}}'

assert_no_banner "clone failed (exit 128)" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git clone https://github.com/owner/example.git workspace/example"},"tool_response":{"exit_code":128}}'

assert_no_banner "clone failed (exit 1)" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git clone https://github.com/owner/foo.git workspace/foo"},"tool_response":{"exit_code":1}}'

assert_no_banner "different tool entirely (Edit)" \
  '{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"workspace/x/README.md"}}'

# --- Summary ---

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
