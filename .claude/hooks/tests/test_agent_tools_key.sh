#!/bin/bash
# Test: agent files use the agent tools key, and QA cannot edit or write files.
# me2resh/apexyard#2031
#
# Claude Code reads the `tools:` key in an agent file. The `allowed-tools:` key
# is a skill key. An agent ignores it and gets every tool. This test fails if
# any `.claude/agents/*.md` file has `allowed-tools:` in its frontmatter, and
# fails if the QA agent does not deny Edit and Write.
#
# Usage: bash .claude/hooks/tests/test_agent_tools_key.sh
# Exit 0 on success, 1 on any failure. Bash 3.2 compatible.

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
AGENTS_DIR="$ROOT/.claude/agents"

FAIL=0
PASS=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# Print the frontmatter lines (between the first two --- lines) of a file.
frontmatter() {
  awk '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm && $0 == "---" { exit }
    infm { print }
  ' "$1"
}

# Print the value of one frontmatter key (empty when the key is absent).
fm_value() {
  frontmatter "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -n 1
}

# Succeed when a comma-separated list contains an exact tool name.
list_has() {
  printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -Fqx -- "$2"
}

# Assert that an agent's tools: list contains an exact tool name.
assert_tool() {
  agent_file="$AGENTS_DIR/$1.md"
  if [ ! -f "$agent_file" ]; then
    fail "$1.md is missing"
    return
  fi
  if list_has "$(fm_value "$agent_file" tools)" "$2"; then
    pass "$1.md grants $2"
  else
    fail "$1.md does not grant $2 in tools"
  fi
}

count=0
for f in "$AGENTS_DIR"/*.md; do
  [ -f "$f" ] || continue
  count=$((count + 1))
  name=$(basename "$f")
  if frontmatter "$f" | grep -q '^allowed-tools:'; then
    fail "$name uses allowed-tools: (skill key); use tools:"
  else
    pass "$name has no allowed-tools: key"
  fi
done

if [ "$count" -eq 0 ]; then
  fail "no agent files found in $AGENTS_DIR"
fi

QA="$AGENTS_DIR/qa-engineer.md"
if [ ! -f "$QA" ]; then
  fail "qa-engineer.md is missing"
else
  qa_tools=$(fm_value "$QA" tools)
  qa_deny=$(fm_value "$QA" disallowedTools)
  if [ -z "$qa_tools" ]; then
    fail "qa-engineer.md has no tools: key"
  else
    pass "qa-engineer.md has a tools: key"
  fi
  for t in mcp__playwright__browser_file_upload mcp__playwright__browser_run_code; do
    if list_has "$qa_deny" "$t"; then
      pass "qa-engineer.md disallows $t"
    else
      fail "qa-engineer.md does not list $t in disallowedTools"
    fi
  done
  for t in Edit Write; do
    if list_has "$qa_deny" "$t"; then
      pass "qa-engineer.md disallows $t"
    else
      fail "qa-engineer.md does not list $t in disallowedTools"
    fi
    if list_has "$qa_tools" "$t"; then
      fail "qa-engineer.md lists $t in tools"
    else
      pass "qa-engineer.md does not grant $t in tools"
    fi
  done
fi

# me2resh/apexyard#2039: tools the role files need.
# Browser tools: server-level entry for the Playwright MCP server.
assert_tool qa-engineer 'mcp__playwright__*'
assert_tool ui-designer 'mcp__playwright__*'
assert_tool head-of-design 'mcp__playwright__*'
# Skill: QA runs /bug; the UI designer runs /design-sync.
assert_tool qa-engineer Skill
assert_tool ui-designer Skill
# DesignSync: the tool that /design-sync drives.
assert_tool ui-designer DesignSync
# Web research: product manager.
assert_tool product-manager WebSearch
assert_tool product-manager WebFetch

printf '\n%s passed, %s failed (%s agent files)\n' "$PASS" "$FAIL" "$count"
[ "$FAIL" -eq 0 ]
