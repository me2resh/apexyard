#!/bin/bash
# Smoke tests for .claude/hooks/_lib-ops-root.sh
# (apexyard#229 + #230 — merge-gate marker-location mismatch fix)
#
# Each case:
#   - builds an isolated sandbox under $TMPDIR with a synthetic ops-fork
#     layout (onboarding.yaml + apexyard.projects.yaml at the root,
#     optional workspace/<project>/ git clone underneath)
#   - sources the lib
#   - calls resolve_ops_root from various cwd contexts
#   - asserts the returned path
#
# Cases covered:
#   1. resolve_ops_root from inside the ops fork → returns ops fork path
#   2. resolve_ops_root from inside workspace/<project>/ → returns OPS fork
#      (this is the bug fix — without this, marker-resolution diverged
#      between the agent and the merge gate)
#   3. resolve_ops_root from outside any ops fork → returns empty string
#   4. resolve_ops_root with explicit start_dir argument → walks from there
#   5. Source-guard: re-sourcing the lib in the same shell is a no-op
#      (no double-define of the function, no shell errors)
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$SRC_ROOT/.claude/hooks/_lib-ops-root.sh"

if [ ! -f "$LIB" ]; then
  echo "FAIL: lib not found at $LIB" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

mark_pass() { echo "  ✓ $1"; return 0; }
mark_fail() { echo "  ✗ $1: $2" >&2; return 1; }

run_case() {
  local fn="$1"
  if "$fn"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES $fn"
  fi
}

# Builds a synthetic ops-fork layout under $1 (legacy v1 layout):
#   $1/onboarding.yaml
#   $1/apexyard.projects.yaml
#   $1/workspace/demo/  (with its own .git/, simulating a managed-project clone)
build_sandbox() {
  local sb="$1"
  mkdir -p "$sb/workspace/demo/.git"
  : > "$sb/onboarding.yaml"
  : > "$sb/apexyard.projects.yaml"
}

# Builds a synthetic split-portfolio v2 ops-fork layout under $1:
#   $1/.apexyard-fork                            (v2 anchor — presence-only)
#   $1/workspace_local/demo/  (placeholder workspace dir for clone path)
# NOTE: no onboarding.yaml or apexyard.projects.yaml at this root —
# v2 moves both to a private sibling repo.
build_v2_sandbox() {
  local sb="$1"
  mkdir -p "$sb/workspace_local/demo/.git"
  : > "$sb/.apexyard-fork"
}

# ---------------------------------------------------------------------------
# Case 1: from inside the ops fork
# ---------------------------------------------------------------------------
case_1() {
  local case_name="resolve_ops_root from ops fork → ops fork path"
  local sb
  sb=$(mktemp -d)
  build_sandbox "$sb"
  ( # shellcheck source=/dev/null
    . "$LIB"
    out=$(cd "$sb" && resolve_ops_root)
    [ "$out" = "$sb" ] || { mark_fail "$case_name" "expected '$sb', got '$out'"; return; }
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 2: from inside workspace/<project>/ → returns ops fork (the bug fix)
# ---------------------------------------------------------------------------
case_2() {
  local case_name="resolve_ops_root from workspace/<project>/ → ops fork"
  local sb
  sb=$(mktemp -d)
  build_sandbox "$sb"
  ( # shellcheck source=/dev/null
    . "$LIB"
    out=$(cd "$sb/workspace/demo" && resolve_ops_root)
    [ "$out" = "$sb" ] || { mark_fail "$case_name" "expected '$sb', got '$out'"; return; }
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 3: from outside any ops fork → empty string
# ---------------------------------------------------------------------------
case_3() {
  local case_name="resolve_ops_root from non-ops dir → empty"
  local outside
  outside=$(mktemp -d)  # no onboarding.yaml / apexyard.projects.yaml
  ( # shellcheck source=/dev/null
    . "$LIB"
    out=$(cd "$outside" && resolve_ops_root)
    # /tmp may itself be inside something the resolver finds, but mktemp -d
    # places us in a fresh subdir — assert it's NOT $outside (we walked up).
    # The "miss" path returns empty.
    if [ -z "$out" ]; then
      mark_pass "$case_name"
    elif [ "$out" = "$outside" ]; then
      mark_fail "$case_name" "false-positive — returned start_dir without finding markers"
    else
      # Walked up and found markers somewhere above /tmp — also acceptable
      # IF those markers actually exist (test environment varies).
      [ -f "$out/onboarding.yaml" ] && [ -f "$out/apexyard.projects.yaml" ] \
        && mark_pass "$case_name (walked up to ancestor ops fork: $out)" \
        || mark_fail "$case_name" "returned '$out' but not a real ops fork"
    fi
  )
}

# ---------------------------------------------------------------------------
# Case 4: explicit start_dir argument
# ---------------------------------------------------------------------------
case_4() {
  local case_name="resolve_ops_root <start_dir> walks from start_dir, not cwd"
  local sb
  sb=$(mktemp -d)
  build_sandbox "$sb"
  local cwd_outside
  cwd_outside=$(mktemp -d)
  ( # shellcheck source=/dev/null
    . "$LIB"
    # cwd is outside; pass workspace clone as explicit start_dir.
    out=$(cd "$cwd_outside" && resolve_ops_root "$sb/workspace/demo")
    [ "$out" = "$sb" ] || { mark_fail "$case_name" "expected '$sb', got '$out'"; return; }
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 5: source-guard
# ---------------------------------------------------------------------------
case_5() {
  local case_name="re-sourcing the lib is a no-op"
  ( # shellcheck source=/dev/null
    . "$LIB"
    if ! type resolve_ops_root >/dev/null 2>&1; then
      mark_fail "$case_name" "function not defined after first source"
      return
    fi
    # Re-source — should not error
    # shellcheck source=/dev/null
    . "$LIB" 2>/dev/null
    if ! type resolve_ops_root >/dev/null 2>&1; then
      mark_fail "$case_name" "function gone after re-source"
      return
    fi
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 6 (v2): from inside a split-portfolio v2 fork with .apexyard-fork
# marker but NO onboarding.yaml / apexyard.projects.yaml at the root
# ---------------------------------------------------------------------------
case_6() {
  local case_name="resolve_ops_root v2: .apexyard-fork marker is enough"
  local sb
  sb=$(mktemp -d)
  build_v2_sandbox "$sb"
  ( # shellcheck source=/dev/null
    . "$LIB"
    out=$(cd "$sb" && resolve_ops_root)
    [ "$out" = "$sb" ] || { mark_fail "$case_name" "expected '$sb', got '$out'"; return; }
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 7 (v2): from inside workspace clone in a v2 fork → returns ops fork
# ---------------------------------------------------------------------------
case_7() {
  local case_name="resolve_ops_root v2: from workspace_local/demo → v2 ops fork"
  local sb
  sb=$(mktemp -d)
  build_v2_sandbox "$sb"
  ( # shellcheck source=/dev/null
    . "$LIB"
    out=$(cd "$sb/workspace_local/demo" && resolve_ops_root)
    [ "$out" = "$sb" ] || { mark_fail "$case_name" "expected '$sb', got '$out'"; return; }
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 8 (v2): v2 marker takes precedence over a legacy anchor when both
# happen to be present (during migration, before legacy files are removed)
# ---------------------------------------------------------------------------
case_8() {
  local case_name="resolve_ops_root: v2 marker takes precedence over legacy anchor"
  local sb
  sb=$(mktemp -d)
  build_v2_sandbox "$sb"
  # Add legacy anchor too — should still resolve to this dir (no ambiguity).
  : > "$sb/onboarding.yaml"
  : > "$sb/apexyard.projects.yaml"
  ( # shellcheck source=/dev/null
    . "$LIB"
    out=$(cd "$sb" && resolve_ops_root)
    [ "$out" = "$sb" ] || { mark_fail "$case_name" "expected '$sb', got '$out'"; return; }
    mark_pass "$case_name"
  )
}

echo "Running ops-root lib tests..."
for fn in case_1 case_2 case_3 case_4 case_5 case_6 case_7 case_8; do
  run_case "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED_CASES"
  exit 1
fi
exit 0
