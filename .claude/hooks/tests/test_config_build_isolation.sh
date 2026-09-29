#!/bin/bash
# Regression test for the build.isolation config key (apexyard#1381).
#
# Pins the shipped default and the docs/agents that must describe both modes.
# This test FAILS on a pre-#1381 tree that has no "build" key.
#
# Optional: APEXYARD_TEST_SRC_ROOT points at an alternate tree (fail-before
# copies). Defaults to the repo root that contains this test file.
#
# Exit 0 if all cases pass; 1 when any case fails.

set -u

SRC_ROOT="${APEXYARD_TEST_SRC_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
PASS=0
FAIL=0
FAILED=""

mark_pass() { printf "  PASS: %s\n" "$1"; PASS=$((PASS+1)); }
mark_fail() { printf "  FAIL: %s: %s\n" "$1" "$2" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}\n  - $1"; }

DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"
RULE="$SRC_ROOT/.claude/rules/isolated-builds.md"
FANOUT="$SRC_ROOT/.claude/skills/fan-out/SKILL.md"
DOCS="$SRC_ROOT/docs/project-config.md"
# Hook libs always come from the live repo (not from fail-before copies).
LIVE_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

# ---------------------------------------------------------------------------
# Case 1: shipped defaults file has build.isolation == worktree (no fallback).
# ---------------------------------------------------------------------------
got=$(jq -r '.build.isolation' "$DEFAULTS" 2>/dev/null)
if [ "$got" = "worktree" ]; then
  mark_pass "shipped file: .build.isolation is present and worktree"
else
  mark_fail "shipped file" "want 'worktree', got '${got:-<missing key>}'"
fi

# ---------------------------------------------------------------------------
# Case 2: config_get_or resolves the shipped default.
# ---------------------------------------------------------------------------
make_sandbox() {
  local sb
  sb=$(mktemp -d)
  mkdir -p "$sb/.claude/hooks"
  touch "$sb/.apexyard-fork"
  cp "$LIVE_ROOT/.claude/hooks/_lib-read-config.sh" "$sb/.claude/hooks/"
  cp "$LIVE_ROOT/.claude/hooks/_lib-ops-root.sh" "$sb/.claude/hooks/"
  if [ -f "$LIVE_ROOT/.claude/hooks/_lib-resolution-cache.sh" ]; then
    cp "$LIVE_ROOT/.claude/hooks/_lib-resolution-cache.sh" "$sb/.claude/hooks/"
  fi
  cp "$DEFAULTS" "$sb/.claude/project-config.defaults.json"
  echo "$sb"
}

sb=$(make_sandbox)
got=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1 bash -c '
  . .claude/hooks/_lib-read-config.sh
  config_get_or ".build.isolation" "MISSING"
')
rm -rf "$sb"
if [ "$got" = "worktree" ]; then
  mark_pass "config_get_or: build.isolation == worktree"
else
  mark_fail "config_get_or default" "want 'worktree', got '$got'"
fi

# ---------------------------------------------------------------------------
# Case 3: an override file can select branch mode.
# ---------------------------------------------------------------------------
sb=$(make_sandbox)
cat > "$sb/.claude/project-config.json" <<'JSON'
{"build": {"isolation": "branch"}}
JSON
got=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1 bash -c '
  . .claude/hooks/_lib-read-config.sh
  config_get_or ".build.isolation" "MISSING"
')
rm -rf "$sb"
if [ "$got" = "branch" ]; then
  mark_pass "override: build.isolation can be set to branch"
else
  mark_fail "override" "want 'branch', got '$got'"
fi

# ---------------------------------------------------------------------------
# Case 4: defaults JSON stays valid.
# ---------------------------------------------------------------------------
if jq empty "$DEFAULTS" >/dev/null 2>&1; then
  mark_pass "project-config.defaults.json is valid JSON"
else
  mark_fail "project-config.defaults.json JSON validity" "jq empty failed"
fi

# ---------------------------------------------------------------------------
# Case 5: isolated-builds.md documents both modes and the setting key.
# ---------------------------------------------------------------------------
if grep -qF 'build.isolation' "$RULE" 2>/dev/null \
  && grep -qF 'worktree' "$RULE" 2>/dev/null \
  && grep -qE '"branch"|`branch`' "$RULE" 2>/dev/null; then
  mark_pass "isolated-builds.md documents build.isolation and both modes"
else
  mark_fail "isolated-builds.md modes" "missing build.isolation and/or both modes"
fi

# ---------------------------------------------------------------------------
# Case 6: branch mode refuses a dirty working tree.
# ---------------------------------------------------------------------------
if grep -qiE 'uncommitted|dirty' "$RULE" 2>/dev/null \
  && grep -qiE 'refuse|do not switch|must not switch' "$RULE" 2>/dev/null; then
  mark_pass "isolated-builds.md: branch mode refuses dirty tree"
else
  mark_fail "dirty-tree refuse" "rule lacks dirty-tree refuse language"
fi

# ---------------------------------------------------------------------------
# Case 7: parallel builds always use worktrees.
# ---------------------------------------------------------------------------
if grep -qiE 'fan-out|parallel' "$RULE" 2>/dev/null \
  && grep -qiE 'always use (a )?worktree|always use worktrees|regardless of' "$RULE" 2>/dev/null; then
  mark_pass "isolated-builds.md: parallel always uses worktrees"
else
  mark_fail "parallel override" "rule lacks parallel-always-worktree language"
fi

# ---------------------------------------------------------------------------
# Case 8: /fan-out documents the setting and parallel override.
# ---------------------------------------------------------------------------
if grep -qF 'build.isolation' "$FANOUT" 2>/dev/null \
  && grep -qiE 'always|regardless' "$FANOUT" 2>/dev/null \
  && grep -qi 'worktree' "$FANOUT" 2>/dev/null; then
  mark_pass "fan-out skill documents build.isolation and parallel worktrees"
else
  mark_fail "fan-out skill" "missing build.isolation / parallel worktree guidance"
fi

# ---------------------------------------------------------------------------
# Case 9: each build-class agent documents both modes.
# ---------------------------------------------------------------------------
for agent in backend-engineer frontend-engineer platform-engineer data-engineer; do
  f="$SRC_ROOT/.claude/agents/${agent}.md"
  if grep -qF 'build.isolation' "$f" 2>/dev/null \
    && grep -qE 'worktree|branch' "$f" 2>/dev/null \
    && grep -qiE 'uncommitted|dirty' "$f" 2>/dev/null; then
    mark_pass "agent $agent documents build.isolation + dirty refuse"
  else
    mark_fail "agent $agent" "missing build.isolation / dirty-tree guidance"
  fi
done

# ---------------------------------------------------------------------------
# Case 10: docs/project-config.md documents the key.
# ---------------------------------------------------------------------------
if grep -qF 'build.isolation' "$DOCS" 2>/dev/null; then
  mark_pass "docs/project-config.md documents build.isolation"
else
  mark_fail "docs/project-config.md" "missing build.isolation"
fi

echo
echo "===== test_config_build_isolation.sh ====="
printf "Passed: %s\n" "$PASS"
printf "Failed: %s\n" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf "Failed cases:%b\n" "$FAILED"
  exit 1
fi
exit 0
