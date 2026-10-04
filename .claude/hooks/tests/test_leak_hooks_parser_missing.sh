#!/bin/bash
# apexyard#1457 review round 2 (Rex B1 / Hakim HIGH-2) — every leak hook
# must FAIL CLOSED when the shared registry parser
# (`_lib-registry-parser.sh`) is missing or fails to load. Before the fix,
# a missing library meant `registry_parse_entries` was undefined, the
# token lists stayed empty, and every hook silently exited 0 — allowing
# ANY private reference through. This file proves each of the three leak
# hooks now blocks in that situation, one case per hook.
#
# Every fixture below is synthetic; no private project name appears here.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/_test-session-isolation.sh"


ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
STAGED_SRC="$ROOT/.claude/hooks/check-private-refs-staged.sh"
RUNTIME_SRC="$ROOT/.claude/hooks/check-private-refs-runtime.sh"
TRACKER_SRC="$ROOT/.claude/hooks/block-private-refs-in-public-repos.sh"

PASS=0
FAIL=0
pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s: %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }

echo "== Fail closed when the shared registry parser is missing (apexyard#1457)"

# --- 1. Staged hook -------------------------------------------------------
sandbox=$(mktemp -d)
mkdir -p "$sandbox/.claude/hooks"
cp "$STAGED_SRC" "$sandbox/.claude/hooks/check-private-refs-staged.sh"
chmod +x "$sandbox/.claude/hooks/check-private-refs-staged.sh"
# Deliberately NOT copying _lib-registry-parser.sh.
cat > "$sandbox/apexyard.projects.yaml" <<'YAML'
projects:
  - name: sample-secret
    repo: acme/sample-secret
    workspace: workspace/sample-secret
YAML
(
  cd "$sandbox" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name Test
  git add apexyard.projects.yaml
  git commit -q -m baseline
)
printf 'Private reference: sample-secret\n' > "$sandbox/leak.md"
git -C "$sandbox" add leak.md
staged_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-staged.sh 2>&1)
staged_rc=$?
if [ "$staged_rc" = "2" ] && echo "$staged_output" | grep -qF 'registry parser'; then
  pass "staged hook blocks when the parser library is missing"
else
  fail "staged hook blocks when the parser library is missing" "exit=$staged_rc output=$staged_output"
fi
rm -rf "$sandbox"

# --- 2. Runtime hook --------------------------------------------------------
sandbox=$(mktemp -d)
mkdir -p "$sandbox/.claude/hooks"
cp "$RUNTIME_SRC" "$sandbox/.claude/hooks/check-private-refs-runtime.sh"
chmod +x "$sandbox/.claude/hooks/check-private-refs-runtime.sh"
cat > "$sandbox/apexyard.projects.yaml" <<'YAML'
projects:
  - name: sample-secret
    repo: acme/sample-secret
    workspace: workspace/sample-secret
YAML
runtime_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-runtime.sh "me2resh/apexyard" "Reviewed sample-secret" '' 2>&1)
runtime_rc=$?
if [ "$runtime_rc" = "2" ] && echo "$runtime_output" | grep -qF 'registry parser'; then
  pass "runtime hook blocks when the parser library is missing"
else
  fail "runtime hook blocks when the parser library is missing" "exit=$runtime_rc output=$runtime_output"
fi
rm -rf "$sandbox"

# --- 3. Public-tracker hook -------------------------------------------------
sandbox=$(mktemp -d)
mkdir -p "$sandbox/.claude/hooks"
cp "$TRACKER_SRC" "$sandbox/.claude/hooks/block-private-refs-in-public-repos.sh"
chmod +x "$sandbox/.claude/hooks/block-private-refs-in-public-repos.sh"
cat > "$sandbox/apexyard.projects.yaml" <<'YAML'
projects:
  - name: sample-secret
    repo: acme/sample-secret
    workspace: workspace/sample-secret
YAML
tracker_payload=$(jq -n --arg c "gh issue create --repo me2resh/apexyard --title 'bug' --body 'discovered during sample-secret rebuild'" '{tool_input: {command: $c}}')
tracker_output=$(cd "$sandbox" && printf '%s' "$tracker_payload" | .claude/hooks/block-private-refs-in-public-repos.sh 2>&1)
tracker_rc=$?
if [ "$tracker_rc" = "2" ] && echo "$tracker_output" | grep -qF 'registry parser'; then
  pass "public-tracker hook blocks when the parser library is missing"
else
  fail "public-tracker hook blocks when the parser library is missing" "exit=$tracker_rc output=$tracker_output"
fi
rm -rf "$sandbox"

echo
echo "===== test_leak_hooks_parser_missing.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
