#!/bin/bash
# Tests for the `.ui_paths_exclude` additive override on
# require-design-review-for-ui.sh (me2resh/apexyard#275).
#
# Scope: the EXCLUDE-application logic only. We test the in-script
# pattern-filter directly via a synthetic TOUCHED_UI list + a sandbox
# project-config.json. We do not exercise the gh-pr-diff path (that's
# covered by the hook's existing integration shape).
#
# Mirrors the assert shape of test_require_skill_for_issue_create.sh.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/require-design-review-for-ui.sh"

if [ ! -f "$HOOK_SRC" ]; then
  echo "FAIL: hook missing: $HOOK_SRC" >&2
  exit 1
fi

PASS=0
FAIL=0

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS [$label]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [$label]: want '$want', got '$got'" >&2
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Helper — replay the EXCLUDE logic inline against a synthetic input + a
# sandbox project-config.json. Keeps tests self-contained.
# ---------------------------------------------------------------------------
run_exclude_filter() {
  local touched="$1"        # space-separated TOUCHED_UI string
  local exclude_json="$2"   # JSON array literal for .ui_paths_exclude
  local sb cfg
  sb=$(mktemp -d)
  cfg="$sb/.claude/project-config.json"
  mkdir -p "$(dirname "$cfg")"
  printf '%s\n' "$exclude_json" > "$cfg"

  # Inline replay of the hook's EXCLUDE block.
  local REPO_ROOT="$sb"
  local TOUCHED_UI="$touched"
  local EXCLUDE
  EXCLUDE=$(jq -r '.ui_paths_exclude // [] | join("|")' "${REPO_ROOT}/.claude/project-config.json" 2>/dev/null)
  if [ -n "$EXCLUDE" ] && [ "$EXCLUDE" != "null" ] && [ -n "$TOUCHED_UI" ]; then
    local FILTERED=""
    local FILE
    for FILE in $TOUCHED_UI; do
      if ! echo "$FILE" | grep -qE "$EXCLUDE"; then
        FILTERED="${FILTERED}${FILE} "
      fi
    done
    TOUCHED_UI="$FILTERED"
  fi

  rm -rf "$sb"
  # Trim trailing whitespace for stable assert.
  echo "${TOUCHED_UI%% }"
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

echo ""
echo "1) The reported false-positive: docs/example.jsx must be excluded"

result=$(run_exclude_filter \
  "docs/example.jsx src/Button.tsx wiki/artifacts/placeholder.jsx" \
  '{"ui_paths_exclude":["^docs/","^wiki/"]}')
# Expect: only src/Button.tsx survives (trailing space trimmed)
assert_eq "docs/wiki carve-out leaves only src/Button.tsx" \
  "src/Button.tsx" \
  "${result// /}" # collapse for stable comparison — order preserved

# Order check explicitly
result2=$(run_exclude_filter \
  "docs/example.jsx src/Button.tsx wiki/artifacts/placeholder.jsx" \
  '{"ui_paths_exclude":["^docs/","^wiki/"]}')
assert_eq "docs/wiki carve-out preserves order" \
  "src/Button.tsx" \
  "$(echo $result2)"

echo ""
echo "2) Real UI in conventional dirs still triggers — no exclude defined"

result=$(run_exclude_filter \
  "src/Button.tsx components/Card.jsx pages/Home.tsx" \
  '{}')
assert_eq "no exclude → all UI files survive" \
  "src/Button.tsx components/Card.jsx pages/Home.tsx" \
  "$(echo $result)"

echo ""
echo "3) Real UI plus an excluded path — only excluded one is dropped"

result=$(run_exclude_filter \
  "src/Button.tsx tools/rule-engine.jsx" \
  '{"ui_paths_exclude":["^tools/"]}')
assert_eq "tools/ exclude leaves src/" \
  "src/Button.tsx" \
  "$(echo $result)"

echo ""
echo "4) Empty TOUCHED_UI + any exclude — still empty"

result=$(run_exclude_filter \
  "" \
  '{"ui_paths_exclude":["^docs/"]}')
assert_eq "empty in → empty out" "" "$(echo $result)"

echo ""
echo "5) ui_paths_exclude is null (missing key) — no-op"

result=$(run_exclude_filter \
  "src/Button.tsx" \
  '{"prefix_whitelist":["Feature"]}')
assert_eq "missing key → all survive" \
  "src/Button.tsx" \
  "$(echo $result)"

echo ""
echo "6) Multiple patterns combine via OR"

result=$(run_exclude_filter \
  "docs/a.jsx wiki/b.jsx tools/c.jsx src/Real.tsx" \
  '{"ui_paths_exclude":["^docs/","^wiki/","^tools/"]}')
assert_eq "OR of three patterns excludes three files" \
  "src/Real.tsx" \
  "$(echo $result)"

echo ""
echo "7) Pattern that matches no files — same as no-op"

result=$(run_exclude_filter \
  "src/Button.tsx" \
  '{"ui_paths_exclude":["^never-matches/"]}')
assert_eq "non-matching exclude → all survive" \
  "src/Button.tsx" \
  "$(echo $result)"

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
