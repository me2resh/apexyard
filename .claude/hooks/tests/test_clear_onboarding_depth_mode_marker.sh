#!/bin/bash
# Smoke tests for .claude/hooks/clear-onboarding-depth-mode-marker.sh
#
# SessionStart hook (me2resh/apexyard#914) that sweeps a stale
# .claude/session/onboarding-depth-mode marker left behind by an
# interrupted session, mirroring clear-bootstrap-marker.sh /
# clear-active-reviewer-marker.sh. A stale marker would otherwise
# silently carry a prior session's depth choice (terse|guided) into the
# next one, instead of the design's per-session derive-or-ask contract
# (docs/technical-designs/onboarding-increment-2.md § D2).
#
# Each case builds an isolated sandbox repo, optionally seeds the marker,
# runs the hook from inside the sandbox, and asserts marker-file state +
# stderr content.
#
# Exit 0 means all cases passed. Exit 1 on any failure (all cases still run).

set -u

export APEXYARD_OPS_DISABLE_PIN=1

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/clear-onboarding-depth-mode-marker.sh"
LIB_OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)/_lib-ops-root.sh"

if [ ! -x "$HOOK_SRC" ]; then
  echo "FAIL: hook not found or not executable at $HOOK_SRC" >&2
  exit 1
fi
if [ ! -f "$LIB_OPS_ROOT" ]; then
  echo "FAIL: _lib-ops-root.sh not found at $LIB_OPS_ROOT" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

make_sandbox() {
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    touch onboarding.yaml apexyard.projects.yaml
    git add onboarding.yaml apexyard.projects.yaml
    git commit -q -m "init"
  )
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session"
  cp "$HOOK_SRC" "$sb/.claude/hooks/clear-onboarding-depth-mode-marker.sh"
  cp "$LIB_OPS_ROOT" "$sb/.claude/hooks/_lib-ops-root.sh"
  chmod +x "$sb/.claude/hooks/clear-onboarding-depth-mode-marker.sh"
  echo "$sb"
}

# run_hook <sandbox> <expect_grep|""> <case_name>
run_hook() {
  local sb="$1" expect_grep="$2" case_name="$3"
  local stderr_file
  stderr_file=$(mktemp)
  (
    cd "$sb" || exit 1
    "$sb/.claude/hooks/clear-onboarding-depth-mode-marker.sh" 2>"$stderr_file"
  )
  local rc=$?
  local ok=1

  if [ "$rc" != "0" ]; then
    echo "FAIL [$case_name]: exit $rc (expected 0)" >&2
    ok=0
  fi

  if [ -z "$expect_grep" ]; then
    if [ -s "$stderr_file" ]; then
      echo "FAIL [$case_name]: expected silent, got stderr" >&2
      ok=0
    fi
  else
    if ! grep -qE "$expect_grep" "$stderr_file"; then
      echo "FAIL [$case_name]: stderr did not match /$expect_grep/" >&2
      ok=0
    fi
  fi

  if [ "$ok" = "1" ]; then
    PASS=$((PASS+1))
    echo "PASS [$case_name]"
  else
    sed 's/^/    stderr: /' "$stderr_file" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="$FAILED_CASES $case_name"
  fi
  rm -f "$stderr_file"
}

# -------------------- CASE 1: no marker present — silent no-op --------------------
case1() {
  local sb
  sb=$(make_sandbox)
  run_hook "$sb" "" "no-marker-silent"
  rm -rf "$sb"
}

# -------------------- CASE 2: stale "guided" marker present — cleared + logged --------------------
case2() {
  local sb
  sb=$(make_sandbox)
  local marker="$sb/.claude/session/onboarding-depth-mode"
  printf '%s' "guided" > "$marker"
  run_hook "$sb" "cleared stale onboarding depth-mode marker.*was: guided" "stale-guided-marker-cleared"
  if [ -f "$marker" ]; then
    echo "FAIL [stale-guided-marker-cleared]: marker file still present after sweep" >&2
    FAIL=$((FAIL+1))
    PASS=$((PASS-1))
  fi
  rm -rf "$sb"
}

# -------------------- CASE 3: stale "terse" marker present — cleared + logged --------------------
case3() {
  local sb
  sb=$(make_sandbox)
  local marker="$sb/.claude/session/onboarding-depth-mode"
  printf '%s' "terse" > "$marker"
  run_hook "$sb" "cleared stale onboarding depth-mode marker.*was: terse" "stale-terse-marker-cleared"
  rm -rf "$sb"
}

# -------------------- CASE 4: idempotent — running twice is still silent the 2nd time --------------------
case4() {
  local sb
  sb=$(make_sandbox)
  local marker="$sb/.claude/session/onboarding-depth-mode"
  printf '%s' "guided" > "$marker"
  run_hook "$sb" "cleared stale onboarding depth-mode marker" "idempotent-first-sweep"
  run_hook "$sb" "" "idempotent-second-sweep-silent"
  rm -rf "$sb"
}

case1
case2
case3
case4

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED_CASES" >&2
  exit 1
fi
exit 0
