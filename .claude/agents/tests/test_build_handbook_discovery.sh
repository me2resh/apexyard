#!/bin/bash
# Pins proactive handbook discovery for every build-class agent named by #1178.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CONTRACT="$ROOT/.claude/rules/build-handbook-discovery.md"
FAIL=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

if [ -f "$CONTRACT" ]; then
  pass "shared build handbook contract exists"
else
  fail "shared build handbook contract exists"
  exit 1
fi

for agent in backend-engineer frontend-engineer platform-engineer data-engineer; do
  file="$ROOT/.claude/agents/$agent.md"
  if grep -qF '@.claude/rules/build-handbook-discovery.md' "$file"; then
    pass "$agent loads the shared contract"
  else
    fail "$agent loads the shared contract"
  fi
done

for required in \
  'architecture/*.md' \
  'general/*.md' \
  'language/<lang>/*.md' \
  'domain/<area>/*.md' \
  'portfolio_custom_handbooks_dir' \
  'mcp__apexyard-search__search_docs' \
  'Semantic discovery is fail-soft' \
  'expected or actual implementation'; do
  if grep -qF "$required" "$CONTRACT"; then
    pass "contract pins: $required"
  else
    fail "contract pins: $required"
  fi
done

if grep -qF 'do not issue a review verdict or write approval markers' "$CONTRACT"; then
  pass "build-time semantics remain separate from review approval"
else
  fail "build-time semantics remain separate from review approval"
fi

printf '\nPassed contract checks with %s failure(s).\n' "$FAIL"
exit "$FAIL"
