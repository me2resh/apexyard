#!/bin/bash
# Regression test for the build.isolation config key (apexyard#1381 / AgDR-0210).
#
# Pins the shipped default and the docs/agents that must describe both modes,
# the concurrency rule, the fallback sentence, the dirty definition, and the
# HEAD-before-commit check.
#
# Optional: APEXYARD_TEST_SRC_ROOT points at an alternate tree (fail-before
# copies). Defaults to the repo root that contains this test file.
#
# Exit 0 if all cases pass; 1 when any case fails.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


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
AGDR="$SRC_ROOT/docs/agdr/AgDR-0210-build-isolation-setting.md"
# Hook libs always come from the live repo (not from fail-before copies).
LIVE_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

FALLBACK_SENTENCE='Any value other than `branch`, including an empty result, means `worktree`.'
CONFIG_READ="config_get_or '.build.isolation' 'worktree'"
DIRTY_DEF='Dirty means tracked files with uncommitted changes or staged changes. Untracked files do not count.'
HEAD_CHECK='Before each commit in `branch` mode, check that HEAD is still your ticket branch with `git branch --show-current`.'

# Concurrency rule lines (checked one-by-one; multiline grep -F is unreliable).
CONC_L1='`branch` mode applies only to a foreground build spawn when no other writer is active on that checkout.'
CONC_L2='A background build spawn always uses a worktree, regardless of `build.isolation`.'
CONC_L3='Any build spawn while another writer is active on that checkout uses a worktree, regardless of `build.isolation`.'
CONC_L4='Parallel means overlapping writers, including a build agent still working from an earlier spawn.'
CONC_L5='The orchestrator decides the mode at spawn time and tells the agent which mode to use.'

BUILD_AGENTS="backend-engineer frontend-engineer platform-engineer data-engineer product-manager ui-designer ux-designer"

has_concurrency_rule() {
  local f="$1"
  grep -qF "$CONC_L1" "$f" 2>/dev/null \
    && grep -qF "$CONC_L2" "$f" 2>/dev/null \
    && grep -qF "$CONC_L3" "$f" 2>/dev/null \
    && grep -qF "$CONC_L4" "$f" 2>/dev/null \
    && grep -qF "$CONC_L5" "$f" 2>/dev/null
}

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
# Case 4: defaults JSON stays valid and names AgDR-0210.
# ---------------------------------------------------------------------------
if jq empty "$DEFAULTS" >/dev/null 2>&1; then
  mark_pass "project-config.defaults.json is valid JSON"
else
  mark_fail "project-config.defaults.json JSON validity" "jq empty failed"
fi
comment=$(jq -r '.build._comment // empty' "$DEFAULTS" 2>/dev/null)
if printf '%s' "$comment" | grep -qF 'AgDR-0210'; then
  mark_pass "defaults _comment names AgDR-0210"
else
  mark_fail "defaults AgDR-0210" "build._comment missing AgDR-0210"
fi

# ---------------------------------------------------------------------------
# Case 5: AgDR-0210 file exists with the correct heading.
# ---------------------------------------------------------------------------
if [ -f "$AGDR" ] && grep -qE '^# AgDR-0210:' "$AGDR" 2>/dev/null; then
  mark_pass "AgDR-0210 file exists with AgDR-0210: heading"
else
  mark_fail "AgDR-0210 file" "missing file or heading at $AGDR"
fi

# ---------------------------------------------------------------------------
# Case 6: isolated-builds.md documents both modes, the setting, and AgDR-0210.
# ---------------------------------------------------------------------------
if grep -qF 'build.isolation' "$RULE" 2>/dev/null \
  && grep -qF 'worktree' "$RULE" 2>/dev/null \
  && grep -qE '"branch"|`branch`' "$RULE" 2>/dev/null \
  && grep -qF 'AgDR-0210' "$RULE" 2>/dev/null; then
  mark_pass "isolated-builds.md documents build.isolation, both modes, AgDR-0210"
else
  mark_fail "isolated-builds.md modes" "missing build.isolation / modes / AgDR-0210"
fi

# ---------------------------------------------------------------------------
# Case 7: concurrency rule text in isolated-builds.md and fan-out.
# ---------------------------------------------------------------------------
if has_concurrency_rule "$RULE"; then
  mark_pass "isolated-builds.md: concurrency rule text"
else
  mark_fail "concurrency rule" "isolated-builds.md lacks the concurrency block"
fi
if has_concurrency_rule "$FANOUT"; then
  mark_pass "fan-out: concurrency rule text"
else
  mark_fail "concurrency fan-out" "fan-out SKILL.md lacks the concurrency block"
fi

# ---------------------------------------------------------------------------
# Case 8: fallback sentence in the rule and docs.
# ---------------------------------------------------------------------------
if grep -qF "$FALLBACK_SENTENCE" "$RULE" 2>/dev/null; then
  mark_pass "isolated-builds.md: fallback sentence"
else
  mark_fail "fallback rule" "isolated-builds.md lacks the fallback sentence"
fi
if grep -qF "$FALLBACK_SENTENCE" "$DOCS" 2>/dev/null; then
  mark_pass "docs/project-config.md: fallback sentence"
else
  mark_fail "fallback docs" "docs/project-config.md lacks the fallback sentence"
fi

# ---------------------------------------------------------------------------
# Case 9: dirty definition (tracked/staged only; untracked do not count).
# ---------------------------------------------------------------------------
if grep -qF "$DIRTY_DEF" "$RULE" 2>/dev/null; then
  mark_pass "isolated-builds.md: dirty definition"
else
  mark_fail "dirty definition" "isolated-builds.md lacks the dirty definition"
fi

# ---------------------------------------------------------------------------
# Case 10: HEAD check before each commit in branch mode.
# ---------------------------------------------------------------------------
if grep -qF "$HEAD_CHECK" "$RULE" 2>/dev/null; then
  mark_pass "isolated-builds.md: HEAD check before commit"
else
  mark_fail "HEAD check" "isolated-builds.md lacks the HEAD-before-commit check"
fi

# ---------------------------------------------------------------------------
# Case 11: docs/project-config.md documents the key and AgDR-0210.
# ---------------------------------------------------------------------------
if grep -qF 'build.isolation' "$DOCS" 2>/dev/null \
  && grep -qF 'AgDR-0210' "$DOCS" 2>/dev/null; then
  mark_pass "docs/project-config.md documents build.isolation and AgDR-0210"
else
  mark_fail "docs/project-config.md" "missing build.isolation / AgDR-0210"
fi

# ---------------------------------------------------------------------------
# Case 12: all seven build-class agents share config read + fallback sentence.
# ---------------------------------------------------------------------------
for agent in $BUILD_AGENTS; do
  f="$SRC_ROOT/.claude/agents/${agent}.md"
  if [ ! -f "$f" ]; then
    mark_fail "agent $agent" "file missing"
    continue
  fi
  if grep -qF "$CONFIG_READ" "$f" 2>/dev/null \
    && grep -qF "$FALLBACK_SENTENCE" "$f" 2>/dev/null \
    && grep -qF 'AgDR-0210' "$f" 2>/dev/null \
    && grep -qF "$DIRTY_DEF" "$f" 2>/dev/null \
    && grep -qF "$HEAD_CHECK" "$f" 2>/dev/null \
    && grep -qiE 'another repository|different repository' "$f" 2>/dev/null \
    && grep -qiE 'destructive git' "$f" 2>/dev/null; then
    mark_pass "agent $agent: config read, fallback, dirty, HEAD, other worktree cases"
  else
    mark_fail "agent $agent" "missing shared build-isolation contract"
  fi
done

# ---------------------------------------------------------------------------
# Case 13: worktree-mode spawn bullet (stale "always isolate" wording gone).
# ---------------------------------------------------------------------------
if grep -qF 'Spawning a build-class sub-agent in `worktree` mode' "$RULE" 2>/dev/null; then
  mark_pass "isolated-builds.md: spawn isolation scoped to worktree mode"
else
  mark_fail "worktree-mode spawn bullet" "rule lacks worktree-mode spawn scoping"
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
