#!/bin/bash
# Tests for suggest-mcp-reindex-after-pull.sh advisory hook
# Run: bash .claude/hooks/tests/test_suggest_mcp_reindex_after_pull.sh

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/suggest-mcp-reindex-after-pull.sh"
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

# --- Should fire: cwd-based detection (the common case) ----------------------

assert_banner_contains "git pull from inside workspace clone (cwd-based)" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"/Users/me/portfolio/workspace/example","tool_input":{"command":"git pull"},"tool_response":{"exit_code":0,"stdout":"Updating abc..def\n 3 files changed"}}' \
  "workspace/example/ was updated via git"

assert_banner_contains "cwd-based — banner names the reindex command" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"/Users/me/portfolio/workspace/example","tool_input":{"command":"git pull"},"tool_response":{"exit_code":0}}' \
  "mcp__apexyard-search__reindex"

assert_banner_contains "cwd-based — reindex is project-scoped" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"/Users/me/portfolio/workspace/example","tool_input":{"command":"git pull"},"tool_response":{"exit_code":0}}' \
  'project="example"'

assert_banner_contains "cwd nested under tool_input" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git pull","cwd":"/Users/me/portfolio/workspace/curios-dog"},"tool_response":{"exit_code":0}}' \
  "workspace/curios-dog/ was updated via git"

# --- Should fire: path-argument fallbacks ------------------------------------

assert_banner_contains "explicit -C path into workspace clone" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git -C workspace/foo pull"},"tool_response":{"exit_code":0}}' \
  "workspace/foo/ was updated via git"

assert_banner_contains "cd prefix into workspace clone" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"cd workspace/bar && git pull"},"tool_response":{"exit_code":0}}' \
  "workspace/bar/ was updated via git"

assert_banner_contains "absolute cd prefix into workspace clone" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"cd /Users/me/portfolio/workspace/baz && git pull"},"tool_response":{"exit_code":0}}' \
  "workspace/baz/ was updated via git"

# --- Should fire: other HEAD-moving git ops ----------------------------------

assert_banner_contains "git merge inside workspace clone" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"/p/workspace/example","tool_input":{"command":"git merge origin/main"},"tool_response":{"exit_code":0}}' \
  "workspace/example/ was updated via git"

assert_banner_contains "git fetch && merge inside workspace clone" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"/p/workspace/example","tool_input":{"command":"git fetch origin && git merge origin/main"},"tool_response":{"exit_code":0}}' \
  "mcp__apexyard-search__reindex"

assert_banner_contains "git checkout branch inside workspace clone" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"/p/workspace/example","tool_input":{"command":"git checkout main"},"tool_response":{"exit_code":0}}' \
  "workspace/example/ was updated via git"

assert_banner_contains "git reset --hard inside workspace clone" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"/p/workspace/example","tool_input":{"command":"git reset --hard origin/main"},"tool_response":{"exit_code":0}}' \
  "workspace/example/ was updated via git"

# --- Should NOT fire ---------------------------------------------------------

assert_no_banner "git pull outside any workspace clone (ops fork)" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"/Users/me/apexyard","tool_input":{"command":"git pull"},"tool_response":{"exit_code":0}}'

assert_no_banner "pull failed (exit 1)" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"/p/workspace/example","tool_input":{"command":"git pull"},"tool_response":{"exit_code":1}}'

assert_no_banner "pull changed nothing — Already up to date." \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"/p/workspace/example","tool_input":{"command":"git pull"},"tool_response":{"exit_code":0,"stdout":"Already up to date."}}'

assert_no_banner "bare git fetch (does not move HEAD)" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"/p/workspace/example","tool_input":{"command":"git fetch origin"},"tool_response":{"exit_code":0}}'

assert_no_banner "non-git command that mentions pull" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"/p/workspace/example","tool_input":{"command":"grep -r \"git pull\" ."},"tool_response":{"exit_code":0}}'

assert_no_banner "no command at all" \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{}}'

assert_no_banner "different tool entirely (Edit in a workspace path)" \
  '{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"workspace/example/README.md"}}'

assert_no_banner "different tool entirely (Write in a workspace path)" \
  '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"workspace/example/src/app.ts"}}'

# --- Summary -----------------------------------------------------------------

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
