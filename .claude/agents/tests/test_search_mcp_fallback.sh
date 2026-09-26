#!/bin/bash
# Pins the absent-MCP fallback for the optional apexyard-search server
# (me2resh/apexyard#1379).
#
# The server is an optional add-on. When its tools are absent, an agent must
# do the same read with grep and Read. It must not skip the step, and it must
# not report a semantic search that did not run. The old text covered only an
# empty result, not an absent tool.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
AGENTS="$ROOT/.claude/agents"
RECONCILE="$ROOT/.claude/rules/reconcile-before-build.md"
HANDBOOKS="$ROOT/.claude/rules/build-handbook-discovery.md"
HANDOVER="$ROOT/.claude/skills/handover/SKILL.md"
FAIL=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}
not() { ! "$@"; }

frontmatter() {
  awk 'NR==1 && /^---[[:space:]]*$/ {fm=1; next}
       fm && /^---[[:space:]]*$/ {exit}
       fm {print}' "$1"
}
body() {
  awk 'NR==1 && /^---[[:space:]]*$/ {fm=1; next}
       fm && /^---[[:space:]]*$/ {fm=0; next}
       !fm {print}' "$1"
}

# An agent that lists the search tools must say what to do without them.
lists_search_tools() {
  frontmatter "$1" | grep -qE '^(tools|allowed-tools):.*mcp__apexyard-search__'
}
has_absent_fallback() {
  local text
  text=$(body "$1")
  printf '%s\n' "$text" | grep -qF 'optional add-on' &&
    printf '%s\n' "$text" | grep -qF 'not in your tool list' &&
    printf '%s\n' "$text" | grep -qF 'Do not report a semantic search that did not run' &&
    ! printf '%s\n' "$text" | grep -qF 'only when an MCP query returns nothing relevant'
}

has_text() { grep -qF -- "$2" "$1"; }

echo "== Agents that list the search tools"
SEARCH_AGENTS=0
while IFS= read -r agent_file; do
  lists_search_tools "$agent_file" || continue
  SEARCH_AGENTS=$((SEARCH_AGENTS + 1))
  check "$(basename "$agent_file" .md) describes the absent-tool fallback" has_absent_fallback "$agent_file"
done < <(find "$AGENTS" -maxdepth 1 -type f -name '*.md' | sort)
check "at least one agent lists the search tools" test "$SEARCH_AGENTS" -gt 0

echo "== Rules and skills"
check "reconcile-before-build names the add-on" has_text "$RECONCILE" 'The `apexyard-search` MCP server is an optional add-on.'
check "reconcile-before-build keeps the search required" has_text "$RECONCILE" 'The search is required either way.'
check "reconcile-before-build forbids a false search claim" has_text "$RECONCILE" 'Do not report a semantic search that did not run.'
check "build-handbook-discovery keeps fail-soft wording" has_text "$HANDBOOKS" 'Semantic discovery is fail-soft'
check "build-handbook-discovery checks the tool list" has_text "$HANDBOOKS" 'Check your tool list for `search_docs` before the query.'
check "build-handbook-discovery skips only the query" has_text "$HANDBOOKS" 'When the tool is absent, skip only this query and load the full path-convention set.'
check "build-handbook-discovery forbids a false citation" has_text "$HANDBOOKS" 'Do not cite a semantic query in the build handoff when it did not run.'
check "handover checks the tool list before reindex" has_text "$HANDOVER" 'Check your tool list for `mcp__apexyard-search__reindex` before the call.'
check "handover does not call an absent tool" has_text "$HANDOVER" '**Tool absent:** do not call it.'
check "handover keeps every read" has_text "$HANDOVER" 'Do not skip or shorten a step.'
check "handover claims an index only when indexed" has_text "$HANDOVER" 'Include "and indexed in MCP" only when `$REINDEX_STATUS` is `indexed`.'
check "handover no longer always attempts the reindex" not has_text "$HANDOVER" '(default: always attempt)'

echo "== Negative cases"
FIXTURES=$(mktemp -d)
trap 'rm -rf "$FIXTURES"' EXIT
cat > "$FIXTURES/old-wording.md" <<'EOF'
---
name: old-wording
allowed-tools: Read, Grep, mcp__apexyard-search__search_code
---

# Fixture agent

Prefer `mcp__apexyard-search__search_code` over `grep` + `Read`. Fall back to `grep`/`Read` only when an MCP query returns nothing relevant.
EOF
check "fixture lists the search tools" lists_search_tools "$FIXTURES/old-wording.md"
check "old empty-result-only wording fails the fallback check" not has_absent_fallback "$FIXTURES/old-wording.md"

printf '\nSearch-MCP fallback checks completed with %s failure(s).\n' "$FAIL"
[ "$FAIL" -eq 0 ]
