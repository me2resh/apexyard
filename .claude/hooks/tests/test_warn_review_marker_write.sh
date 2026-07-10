#!/bin/bash
# Tests for warn-review-marker-write.sh.
#
# HISTORY: #728 made the hook's banner "unmissable" (VIOLATION framing) but
# kept it advisory (exit 0 always) for every marker type, reasoning that the
# harness gives no per-agent-type signal to distinguish the sanctioned
# code-reviewer from a build-class impersonator. #843 closes that gap with a
# session-state signal instead: writes to *-rex.approved / *-security.approved
# / *-architecture.approved now BLOCK (exit 2) unless a matching
# .claude/session/active-reviewer marker is present. *-ceo.approved KEEPS its
# original #728 advisory-only (never-blocks) behaviour — it has its own
# structured-field defence in block-unreviewed-merge.sh and is written by a
# human-invoked skill, not a reviewer agent.
#
# Test matrix:
#   (1)  Write  → rex marker, no active-reviewer marker         → BLOCKED, exit 2
#   (2)  Write  → ceo marker                                    → advisory, exit 0 (unchanged)
#   (3)  Bash   → echo redirect to rex marker, no marker         → BLOCKED, exit 2
#   (4)  Bash   → tee to rex marker, no marker                   → BLOCKED, exit 2
#   (5)  Write  → non-marker path                                → silent, exit 0
#   (6)  Bash   → unrelated command                               → silent, exit 0
#   (7)  Write  → architecture marker, no active-reviewer marker → BLOCKED, exit 2 (#843: no longer silently ignored)
#   (8)  Missing tool_name field                                  → silent, exit 0
#   (9)  Banner content — rex blocked case contains "BLOCKED"
#   (10) Banner content — ceo advisory case contains "VIOLATION" and "/approve-merge"
#   (11) Bash   → printf to rex marker, no marker                → BLOCKED, exit 2
#   (12) Write  → rex marker WITH matching active-reviewer marker → ALLOWED, exit 0, silent
#   (13) Write  → security marker WITH matching active-reviewer marker → ALLOWED, exit 0
#   (14) Write  → architecture marker WITH matching active-reviewer marker → ALLOWED, exit 0
#   (15) Write  → rex marker, active-reviewer marker wrong kind  → BLOCKED, exit 2
#   (16) Write  → rex marker, active-reviewer marker wrong pr    → BLOCKED, exit 2
#   (17) Write  → rex marker, active-reviewer marker wrong repo  → BLOCKED, exit 2
#   (18) Write  → legacy bare-number marker filename, no marker  → BLOCKED, exit 2
#   (19) Write  → legacy bare-number marker filename, matching pr+kind → ALLOWED, exit 0 (repo check skipped)
#
# Exit 0 if all cases pass; 1 on failure.

set -u

# Isolation: don't let a live session pin escape this sandbox onto the real
# ops fork (see bin/run-hook-tests.sh's rationale). No-op when unset/headless.
export APEXYARD_OPS_DISABLE_PIN=1

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/warn-review-marker-write.sh"
LIB_OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)/_lib-ops-root.sh"
LIB_MARKERS="$(cd "$(dirname "$0")/.." && pwd)/_lib-review-markers.sh"

if [ ! -f "$HOOK_SRC" ]; then
  echo "FAIL: hook not found: $HOOK_SRC" >&2
  exit 1
fi
if ! bash -n "$HOOK_SRC" 2>/dev/null; then
  echo "FAIL: syntax error in $HOOK_SRC" >&2
  exit 1
fi
if [ ! -f "$LIB_OPS_ROOT" ]; then
  echo "FAIL: _lib-ops-root.sh not found at $LIB_OPS_ROOT" >&2
  exit 1
fi
if [ ! -f "$LIB_MARKERS" ]; then
  echo "FAIL: _lib-review-markers.sh not found at $LIB_MARKERS" >&2
  exit 1
fi

# Load the marker-path helper so test cases build expected paths the same
# way the real skills/hooks do.
# shellcheck source=/dev/null
. "$LIB_MARKERS"

PASS=0; FAIL=0; FAILED_CASES=""

# Build an isolated sandbox: a tiny git repo anchored as an ops fork
# (onboarding.yaml + apexyard.projects.yaml) with the hook + its libs copied
# in. Every case runs from inside its own sandbox so MARKER_HOME resolves
# there, not onto the real fork running this test.
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
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session/reviews"
  cp "$HOOK_SRC" "$sb/.claude/hooks/warn-review-marker-write.sh"
  cp "$LIB_OPS_ROOT" "$sb/.claude/hooks/_lib-ops-root.sh"
  chmod +x "$sb/.claude/hooks/warn-review-marker-write.sh"
  echo "$sb"
}

REPO="me2resh/apexyard"

# ---------------------------------------------------------------------------
# Helper: run_hook <sandbox> <label> <json> <expect_exit> [<grep_pattern>]
# ---------------------------------------------------------------------------
run_hook() {
  local sb="$1" label="$2" json="$3" expect_exit="$4"
  local grep_pattern="${5:-}"
  local stderr_file rc

  stderr_file=$(mktemp)
  (
    cd "$sb" || exit 1
    printf '%s' "$json" | "$sb/.claude/hooks/warn-review-marker-write.sh" 2>"$stderr_file"
  )
  rc=$?

  if [ "$rc" != "$expect_exit" ]; then
    echo "FAIL [$label]: hook exited $rc, expected $expect_exit" >&2
    sed 's/^/    stderr: /' "$stderr_file" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES $label"; rm -f "$stderr_file"; return
  fi

  local stderr_content
  stderr_content=$(cat "$stderr_file")

  if [ -n "$grep_pattern" ]; then
    if ! echo "$stderr_content" | grep -qE "$grep_pattern"; then
      echo "FAIL [$label]: stderr did not match /$grep_pattern/" >&2
      echo "  stderr (first 400 chars): ${stderr_content:0:400}" >&2
      FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES $label"; rm -f "$stderr_file"; return
    fi
  fi

  rm -f "$stderr_file"
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# Convenience wrappers for common JSON payloads.
write_json() {
  local path="$1"
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"sha123"}}' "$path"
}
bash_json() {
  local cmd="${1//\"/\\\"}"
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd"
}

# ---------------------------------------------------------------------------
# (1) Write → rex marker, no active-reviewer marker → BLOCKED, exit 2
# ---------------------------------------------------------------------------
case1() {
  local sb; sb=$(make_sandbox)
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  run_hook "$sb" "Write rex marker, no active-reviewer marker -> BLOCKED" \
    "$(write_json "$marker")" 2 "BLOCKED"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (2) Write → ceo marker → advisory, exit 0 (unchanged)
# ---------------------------------------------------------------------------
case2() {
  local sb; sb=$(make_sandbox)
  local marker; marker=$(review_marker_path "$REPO" 42 ceo "$sb")
  run_hook "$sb" "Write ceo marker -> advisory, exit 0" \
    "$(write_json "$marker")" 0 "VIOLATION"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (3) Bash → echo redirect to rex marker, no active-reviewer marker → BLOCKED
# ---------------------------------------------------------------------------
case3() {
  local sb; sb=$(make_sandbox)
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  run_hook "$sb" "Bash echo redirect rex marker, no marker -> BLOCKED" \
    "$(bash_json "echo 'abc123' > ${marker}")" 2 "BLOCKED"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (4) Bash → tee to rex marker, no active-reviewer marker → BLOCKED
# ---------------------------------------------------------------------------
case4() {
  local sb; sb=$(make_sandbox)
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  run_hook "$sb" "Bash tee rex marker, no marker -> BLOCKED" \
    "$(bash_json "printf sha | tee ${marker}")" 2 "BLOCKED"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (5) Write → non-marker path → silent, exit 0
# ---------------------------------------------------------------------------
case5() {
  local sb; sb=$(make_sandbox)
  run_hook "$sb" "Write non-marker path is silent" \
    "$(write_json ".claude/session/notes/build-log.txt")" 0
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (6) Bash → unrelated command → silent, exit 0
# ---------------------------------------------------------------------------
case6() {
  local sb; sb=$(make_sandbox)
  run_hook "$sb" "Bash unrelated command is silent" \
    "$(bash_json "gh pr merge 42 --squash")" 0
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (7) Write → architecture marker, no active-reviewer marker → BLOCKED (#843:
#     architecture markers are no longer silently ignored — they're gated
#     exactly like rex now).
# ---------------------------------------------------------------------------
case7() {
  local sb; sb=$(make_sandbox)
  local marker; marker=$(review_marker_path "$REPO" 42 architecture "$sb")
  run_hook "$sb" "Write architecture marker, no marker -> BLOCKED (#843)" \
    "$(write_json "$marker")" 2 "BLOCKED"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (8) Missing tool_name field → silent, exit 0
# ---------------------------------------------------------------------------
case8() {
  local sb; sb=$(make_sandbox)
  run_hook "$sb" "Missing tool_name is silent" \
    '{"tool_input":{"file_path":".claude/session/reviews/42-rex.approved"}}' 0
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (9) Banner content — rex blocked case contains "BLOCKED"
# ---------------------------------------------------------------------------
case9() {
  local sb; sb=$(make_sandbox)
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  run_hook "$sb" "Rex blocked banner contains BLOCKED keyword" \
    "$(write_json "$marker")" 2 "BLOCKED"
  run_hook "$sb" "Rex blocked banner mentions BUILD-CLASS SUB-AGENT" \
    "$(write_json "$marker")" 2 "BUILD-CLASS SUB-AGENT"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (10) Banner content — ceo advisory case contains VIOLATION and /approve-merge
# ---------------------------------------------------------------------------
case10() {
  local sb; sb=$(make_sandbox)
  local marker; marker=$(review_marker_path "$REPO" 42 ceo "$sb")
  run_hook "$sb" "CEO banner contains VIOLATION keyword" \
    "$(write_json "$marker")" 0 "VIOLATION"
  run_hook "$sb" "CEO banner mentions /approve-merge" \
    "$(write_json "$marker")" 0 "/approve-merge"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (11) Bash → printf to rex marker, no active-reviewer marker → BLOCKED
# ---------------------------------------------------------------------------
case11() {
  local sb; sb=$(make_sandbox)
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  run_hook "$sb" "Bash printf rex marker, no marker -> BLOCKED" \
    "$(bash_json "printf '%s' sha > ${marker}")" 2 "BLOCKED"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (12) Write → rex marker WITH matching active-reviewer marker → ALLOWED
# ---------------------------------------------------------------------------
case12() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "${REPO}#42:rex" > "$sb/.claude/session/active-reviewer"
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  run_hook "$sb" "Write rex marker with matching active-reviewer marker -> ALLOWED" \
    "$(write_json "$marker")" 0
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (13) Write → security marker WITH matching active-reviewer marker → ALLOWED
# ---------------------------------------------------------------------------
case13() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "${REPO}#42:security" > "$sb/.claude/session/active-reviewer"
  local marker; marker=$(review_marker_path "$REPO" 42 security "$sb")
  run_hook "$sb" "Write security marker with matching active-reviewer marker -> ALLOWED" \
    "$(write_json "$marker")" 0
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (14) Write → architecture marker WITH matching active-reviewer marker → ALLOWED
# ---------------------------------------------------------------------------
case14() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "${REPO}#42:architecture" > "$sb/.claude/session/active-reviewer"
  local marker; marker=$(review_marker_path "$REPO" 42 architecture "$sb")
  run_hook "$sb" "Write architecture marker with matching active-reviewer marker -> ALLOWED" \
    "$(write_json "$marker")" 0
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (15) Write → rex marker, active-reviewer marker wrong kind → BLOCKED
# ---------------------------------------------------------------------------
case15() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "${REPO}#42:security" > "$sb/.claude/session/active-reviewer"
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  run_hook "$sb" "Write rex marker, active-reviewer marker wrong kind -> BLOCKED" \
    "$(write_json "$marker")" 2 "BLOCKED"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (16) Write → rex marker, active-reviewer marker wrong pr → BLOCKED
# ---------------------------------------------------------------------------
case16() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "${REPO}#999:rex" > "$sb/.claude/session/active-reviewer"
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  run_hook "$sb" "Write rex marker, active-reviewer marker wrong pr -> BLOCKED" \
    "$(write_json "$marker")" 2 "BLOCKED"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (17) Write → rex marker, active-reviewer marker wrong repo → BLOCKED
# ---------------------------------------------------------------------------
case17() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "other-owner/other-repo#42:rex" > "$sb/.claude/session/active-reviewer"
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  run_hook "$sb" "Write rex marker, active-reviewer marker wrong repo -> BLOCKED" \
    "$(write_json "$marker")" 2 "BLOCKED"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (18) Write → legacy bare-number marker filename, no active-reviewer marker
#      → BLOCKED
# ---------------------------------------------------------------------------
case18() {
  local sb; sb=$(make_sandbox)
  local marker="$sb/.claude/session/reviews/42-rex.approved"
  run_hook "$sb" "Write legacy bare-number marker, no marker -> BLOCKED" \
    "$(write_json "$marker")" 2 "BLOCKED"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (19) Write → legacy bare-number marker filename, matching pr+kind → ALLOWED
#      (repo check skipped — can't recover a repo from a bare filename)
# ---------------------------------------------------------------------------
case19() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "${REPO}#42:rex" > "$sb/.claude/session/active-reviewer"
  local marker="$sb/.claude/session/reviews/42-rex.approved"
  run_hook "$sb" "Write legacy bare-number marker, matching pr+kind -> ALLOWED" \
    "$(write_json "$marker")" 0
  rm -rf "$sb"
}

case1
case2
case3
case4
case5
case6
case7
case8
case9
case10
case11
case12
case13
case14
case15
case16
case17
case18
case19

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED_CASES" >&2
  exit 1
fi
exit 0
