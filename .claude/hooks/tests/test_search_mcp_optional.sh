#!/bin/bash
# Check the required reads and generated instructions without a search MCP.

set -u

ROOT="${APEXYARD_TEST_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
PASS=0
FAIL=0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/search-mcp-optional.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

check() {
  local label="$1"
  shift
  if "$@"; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s\n' "$label"
    FAIL=$((FAIL + 1))
  fi
}

has_text() { grep -qF -- "$2" "$1"; }
lacks_text() { ! grep -qF -- "$2" "$1"; }

echo '== Agent capability and fallback'
agent_count=0
for agent in "$ROOT"/.claude/agents/*.md; do
  if grep -qE '^(tools|allowed-tools):.*mcp__apexyard-search__' "$agent"; then
    agent_count=$((agent_count + 1))
    check "$(basename "$agent") keeps the full read when search is absent" \
      has_text "$agent" 'If `apexyard-search` is not installed, use `grep` and `Read`. Do not skip the step.'
  fi
done
check 'search agents were found' test "$agent_count" -gt 0
check 'reviewer checks tool availability before the semantic supplement' \
  has_text "$ROOT/.claude/agents/code-reviewer.md" \
  'Check your tool list for `mcp__apexyard-search__search_docs` before the call.'

echo '== Required rule and skill steps'
check 'reconciliation uses grep and Read without the MCP' \
  has_text "$ROOT/.claude/rules/reconcile-before-build.md" \
  'If `apexyard-search` is not installed, use `grep` and `Read`. Do not skip the search.'
check 'handbook discovery keeps every required read' \
  has_text "$ROOT/.claude/rules/build-handbook-discovery.md" \
  'If `apexyard-search` is not installed, use path-convention discovery and `Read`. Do not skip a selected handbook.'
check 'handover uses grep and Read when reindex is unavailable' \
  has_text "$ROOT/.claude/skills/handover/SKILL.md" \
  'When `unavailable` or `skipped`, use `grep` and `Read` for every assessment read in steps 2–6.'
check 'handover does not require grep after a successful reindex' \
  lacks_text "$ROOT/.claude/skills/handover/SKILL.md" \
  'Do every read in steps 2–6 with `grep` + `Read`.'

echo '== Generated adapter without the MCP'
fixture="$WORK/fork"
mkdir -p "$fixture/.claude/agents" "$fixture/.claude/skills/handover" "$fixture/bin"
cp "$ROOT/bin/sync-codex-adapter.sh" "$fixture/bin/"
cp "$ROOT/.claude/agents/backend-engineer.md" "$fixture/.claude/agents/"
cp "$ROOT/.claude/skills/handover/SKILL.md" "$fixture/.claude/skills/handover/"
printf '{"hooks":{}}\n' > "$fixture/.claude/settings.json"
printf '{}\n' > "$fixture/.claude/harness-models.json"

if /bin/bash "$fixture/bin/sync-codex-adapter.sh" --root "$fixture" > "$WORK/generate.out" 2>&1; then
  check 'adapter omits unavailable MCP tool identifiers' \
    lacks_text "$fixture/.codex/agents/backend-engineer.toml" 'mcp__apexyard-search__'
  check 'generated skill omits unavailable MCP tool identifiers' \
    lacks_text "$fixture/.agents/skills/handover/SKILL.md" 'mcp__apexyard-search__'
  check 'generated handover keeps the required fallback reads' \
    has_text "$fixture/.agents/skills/handover/SKILL.md" \
    'When `unavailable` or `skipped`, use `grep` and `Read` for every assessment read in steps 2–6.'
  check 'generated agent keeps the grep and Read fallback' \
    has_text "$fixture/.codex/agents/backend-engineer.toml" \
    'If `apexyard-search` is not installed, use `grep` and `Read`. Do not skip the step.'
else
  printf 'FAIL: adapter generation without the MCP (%s)\n' "$(cat "$WORK/generate.out")"
  FAIL=$((FAIL + 4))
fi

printf '{"mcpServers":{"other-server":{"command":"other-fixture"}}}\n' > "$fixture/.mcp.json"
if /bin/bash "$fixture/bin/sync-codex-adapter.sh" --root "$fixture" > "$WORK/other.out" 2>&1; then
  check 'unrelated MCP config does not enable search identifiers' \
    lacks_text "$fixture/.codex/agents/backend-engineer.toml" 'mcp__apexyard-search__'
else
  printf 'FAIL: adapter generation with unrelated MCP (%s)\n' "$(cat "$WORK/other.out")"
  FAIL=$((FAIL + 1))
fi

printf '{"mcpServers":{"apexyard-search":{"command":"search-fixture"}}}\n' > "$fixture/.mcp.json"
if /bin/bash "$fixture/bin/sync-codex-adapter.sh" --root "$fixture" > "$WORK/configured.out" 2>&1; then
  check 'configured adapter retains the search tool identifier' \
    has_text "$fixture/.codex/agents/backend-engineer.toml" 'mcp__apexyard-search__search_code'
else
  printf 'FAIL: adapter generation with configured MCP (%s)\n' "$(cat "$WORK/configured.out")"
  FAIL=$((FAIL + 1))
fi

printf 'Passed: %s\nFailed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
