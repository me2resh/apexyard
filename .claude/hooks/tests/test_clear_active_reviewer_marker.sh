#!/bin/bash
# Smoke tests for .claude/hooks/clear-active-reviewer-marker.sh
#
# SessionStart hook (me2resh/apexyard#843) that sweeps a stale
# .claude/session/active-reviewer marker left behind by an interrupted
# session, mirroring clear-bootstrap-marker.sh. A stale marker would
# otherwise silently authorise the next *-rex.approved / *-security.approved
# / *-architecture.approved write in a future session regardless of which
# (repo, pr, kind) it's actually for — warn-review-marker-write.sh checks
# only marker *presence + content*, not recency.
#
# Each case builds an isolated sandbox repo, optionally seeds the marker,
# runs the hook from inside the sandbox, and asserts marker-file state +
# stderr content.
#
# Exit 0 means all cases passed. Exit 1 on any failure (all cases still run).

set -u

export APEXYARD_OPS_DISABLE_PIN=1

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/clear-active-reviewer-marker.sh"
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
  cp "$HOOK_SRC" "$sb/.claude/hooks/clear-active-reviewer-marker.sh"
  cp "$LIB_OPS_ROOT" "$sb/.claude/hooks/_lib-ops-root.sh"
  chmod +x "$sb/.claude/hooks/clear-active-reviewer-marker.sh"
  echo "$sb"
}

# run_hook <sandbox> <expect_grep|""> <case_name>
run_hook() {
  local sb="$1" expect_grep="$2" case_name="$3"
  local stderr_file
  stderr_file=$(mktemp)
  (
    cd "$sb" || exit 1
    "$sb/.claude/hooks/clear-active-reviewer-marker.sh" 2>"$stderr_file"
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

# -------------------- CASE 2: stale marker present — cleared + logged --------------------
case2() {
  local sb
  sb=$(make_sandbox)
  local marker="$sb/.claude/session/active-reviewer"
  printf '%s\n' "me2resh/apexyard#843:rex" > "$marker"
  run_hook "$sb" "cleared stale active-reviewer marker.*me2resh/apexyard#843:rex" "stale-marker-cleared"
  if [ -f "$marker" ]; then
    echo "FAIL [stale-marker-cleared]: marker file still present after sweep" >&2
    FAIL=$((FAIL+1))
    PASS=$((PASS-1))
  fi
  rm -rf "$sb"
}

# -------------------- CASE 3: idempotent — running twice is still silent the 2nd time --------------------
case3() {
  local sb
  sb=$(make_sandbox)
  local marker="$sb/.claude/session/active-reviewer"
  printf '%s\n' "acme/repo#7:security" > "$marker"
  run_hook "$sb" "cleared stale active-reviewer marker" "idempotent-first-sweep"
  run_hook "$sb" "" "idempotent-second-sweep-silent"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# me2resh/apexyard#1376 — the marker this hook sweeps is now keyed on
# CLAUDE_CODE_SESSION_ID. Before this fix, a SessionStart sweep in ANY
# session removed the ONE fixed marker file regardless of who wrote it — so
# a fresh session starting up could silently disable
# block-reviewer-repo-mutation.sh for a review genuinely still in flight in a
# DIFFERENT, concurrently-running session/worktree. A dedicated sandbox (with
# _lib-review-markers.sh copied in, unlike make_sandbox above) and a
# session-aware run helper cover this without touching cases 1-3.
# ---------------------------------------------------------------------------

LIB_MARKERS="$(cd "$(dirname "$0")/.." && pwd)/_lib-review-markers.sh"
if [ ! -f "$LIB_MARKERS" ]; then
  echo "FAIL: _lib-review-markers.sh not found at $LIB_MARKERS" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$LIB_MARKERS"

make_sandbox_scoped() {
  local sb; sb=$(make_sandbox)
  cp "$LIB_MARKERS" "$sb/.claude/hooks/_lib-review-markers.sh"
  echo "$sb"
}

# run_hook_sess <sandbox> <session_id|""> <expect_grep|""> <case_name>
run_hook_sess() {
  local sb="$1" sess="$2" expect_grep="$3" case_name="$4"
  local stderr_file
  stderr_file=$(mktemp)
  (
    cd "$sb" || exit 1
    if [ -n "$sess" ]; then export CLAUDE_CODE_SESSION_ID="$sess"; else unset CLAUDE_CODE_SESSION_ID; fi
    "$sb/.claude/hooks/clear-active-reviewer-marker.sh" 2>"$stderr_file"
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

# -------------------- CASE 4: same session's own stale marker -- cleared --------------------
case4() {
  local sb; sb=$(make_sandbox_scoped)
  local marker; marker=$(active_reviewer_marker_path "$sb" "sess-A")
  mkdir -p "$(dirname "$marker")"
  printf '%s\n' "me2resh/apexyard#843:rex" > "$marker"
  run_hook_sess "$sb" "sess-A" "cleared stale active-reviewer marker.*me2resh/apexyard#843:rex" "same-session-stale-marker-cleared"
  if [ -f "$marker" ]; then
    echo "FAIL [same-session-stale-marker-cleared]: marker file still present after sweep" >&2
    FAIL=$((FAIL+1)); PASS=$((PASS-1))
  fi
  rm -rf "$sb"
}

# -------------------- CASE 5: THE REGRESSION THIS FIX CLOSES -- a DIFFERENT
# session's marker must survive the sweep --------------------
# Session "sess-A" is mid-review (its marker is live, not stale). SessionStart
# fires in a NEW, unrelated session "sess-B". Pre-#1376's single fixed path
# meant sess-B's own startup swept sess-A's marker out from under its
# still-running review, silently disabling block-reviewer-repo-mutation.sh for
# it. Post-#1376, sess-B's sweep only ever targets its OWN suffixed path.
case5() {
  local sb; sb=$(make_sandbox_scoped)
  local marker_a; marker_a=$(active_reviewer_marker_path "$sb" "sess-A")
  mkdir -p "$(dirname "$marker_a")"
  printf '%s\n' "me2resh/apexyard#843:rex" > "$marker_a"
  run_hook_sess "$sb" "sess-B" "" "different-session-marker-survives-sweep"
  if [ ! -f "$marker_a" ]; then
    echo "FAIL [different-session-marker-survives-sweep]: sess-B's sweep removed sess-A's live marker (#1376 regression)" >&2
    FAIL=$((FAIL+1)); PASS=$((PASS-1))
  fi
  rm -rf "$sb"
}

case1
case2
case3
case4
case5

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED_CASES" >&2
  exit 1
fi
exit 0
