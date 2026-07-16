#!/bin/bash
# Unit tests for .claude/hooks/_lib-onboarding-depth-mode.sh
#
# Ticket: me2resh/apexyard#914 (increment-2 M6 — depth adaptivity: terse vs
# guided + override + transparency). Technical design:
# docs/technical-designs/onboarding-increment-2.md § D2/D7.
#
# Coverage (per the design's Testing Strategy for #914 t6):
#   - derivation from each `onboarding-tech-level` signal value
#   - depth_mode_read's safe default (absent/garbage marker -> terse)
#   - override phrase classification (both families + no-match)
#   - FR-9 transparency report text for both modes
#   - INVARIANT: exercising every depth-mode function never writes a
#     gate/permission/approval marker (`.claude/session/reviews/**`,
#     `*-rex.approved`, `*-ceo.approved`, `*-security.approved`,
#     `*-architecture.approved`) — the mechanical guard for design
#     § "Depth mode is presentation only"
#
# Each case builds an isolated sandbox repo, sources the lib inside it,
# and asserts stdout/return-code/file-state. Exit 0 means all cases
# passed. Exit 1 on any failure (all cases still run).

set -u

export APEXYARD_OPS_DISABLE_PIN=1

LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-onboarding-depth-mode.sh"
LIB_OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)/_lib-ops-root.sh"

if [ ! -f "$LIB_SRC" ]; then
  echo "FAIL: lib not found at $LIB_SRC" >&2
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
  cp "$LIB_SRC" "$sb/.claude/hooks/_lib-onboarding-depth-mode.sh"
  cp "$LIB_OPS_ROOT" "$sb/.claude/hooks/_lib-ops-root.sh"
  echo "$sb"
}

# assert_eq <case_name> <expected> <actual>
assert_eq() {
  local case_name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
    echo "PASS [$case_name]"
  else
    echo "FAIL [$case_name]: expected '$expected', got '$actual'" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="$FAILED_CASES $case_name"
  fi
}

# assert_rc <case_name> <expected_rc> <actual_rc>
assert_rc() {
  local case_name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
    echo "PASS [$case_name]"
  else
    echo "FAIL [$case_name]: expected rc $expected, got rc $actual" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="$FAILED_CASES $case_name"
  fi
}

# ============================================================
# derive_from_signal — pure mapping
# ============================================================

case_derive() {
  local sb out rc
  sb=$(make_sandbox)
  (
    cd "$sb" || exit 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-depth-mode.sh

    out=$(depth_mode_derive_from_signal "engineer"); rc=$?
    echo "engineer:$out:$rc"

    out=$(depth_mode_derive_from_signal "non-engineer"); rc=$?
    echo "non-engineer:$out:$rc"

    out=$(depth_mode_derive_from_signal "ambiguous"); rc=$?
    echo "ambiguous:$out:$rc"

    out=$(depth_mode_derive_from_signal ""); rc=$?
    echo "empty:$out:$rc"
  ) > "$sb/derive.out"

  assert_eq "derive-engineer-to-terse" "engineer:terse:0" "$(sed -n '1p' "$sb/derive.out")"
  assert_eq "derive-non-engineer-to-guided" "non-engineer:guided:0" "$(sed -n '2p' "$sb/derive.out")"
  assert_eq "derive-ambiguous-fails-no-guess" "ambiguous::1" "$(sed -n '3p' "$sb/derive.out")"
  assert_eq "derive-empty-fails-no-guess" "empty::1" "$(sed -n '4p' "$sb/derive.out")"

  rm -rf "$sb"
}

# ============================================================
# depth_mode_read — safe default
# ============================================================

case_read_default() {
  local sb out
  sb=$(make_sandbox)
  (
    cd "$sb" || exit 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-depth-mode.sh
    depth_mode_read
  ) > "$sb/read1.out"
  assert_eq "read-absent-marker-defaults-terse" "terse" "$(cat "$sb/read1.out")"

  mkdir -p "$sb/.claude/session"
  printf 'guided' > "$sb/.claude/session/onboarding-depth-mode"
  (
    cd "$sb" || exit 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-depth-mode.sh
    depth_mode_read
  ) > "$sb/read2.out"
  assert_eq "read-guided-marker-reflected" "guided" "$(cat "$sb/read2.out")"

  printf 'garbage-value' > "$sb/.claude/session/onboarding-depth-mode"
  (
    cd "$sb" || exit 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-depth-mode.sh
    depth_mode_read
  ) > "$sb/read3.out"
  assert_eq "read-garbage-marker-safe-default-terse" "terse" "$(cat "$sb/read3.out")"

  rm -rf "$sb"
}

# ============================================================
# depth_mode_write — writes + rejects invalid values
# ============================================================

case_write() {
  local sb rc
  sb=$(make_sandbox)
  (
    cd "$sb" || exit 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-depth-mode.sh
    depth_mode_write "guided"
  )
  assert_eq "write-guided-persists" "guided" "$(cat "$sb/.claude/session/onboarding-depth-mode" 2>/dev/null)"

  (
    cd "$sb" || exit 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-depth-mode.sh
    depth_mode_write "terse"
  )
  assert_eq "write-terse-overwrites" "terse" "$(cat "$sb/.claude/session/onboarding-depth-mode" 2>/dev/null)"

  (
    cd "$sb" || exit 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-depth-mode.sh
    depth_mode_write "chaotic-neutral" 2>/dev/null
  )
  rc=$?
  assert_rc "write-invalid-mode-rejected-rc1" "1" "$rc"
  assert_eq "write-invalid-mode-does-not-overwrite" "terse" "$(cat "$sb/.claude/session/onboarding-depth-mode" 2>/dev/null)"

  rm -rf "$sb"
}

# ============================================================
# depth_mode_classify_override — phrase families (design § D2)
# ============================================================

case_classify_override() {
  local sb
  sb=$(make_sandbox)
  (
    cd "$sb" || exit 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-depth-mode.sh

    echo "guided1:$(depth_mode_classify_override "actually, explain things more")"
    echo "guided2:$(depth_mode_classify_override "Explain more please")"
    echo "guided3:$(depth_mode_classify_override "honestly I don't know these terms")"
    echo "terse1:$(depth_mode_classify_override "skip the explanations")"
    echo "terse2:$(depth_mode_classify_override "just be terse")"
    echo "terse3:$(depth_mode_classify_override "I know this already")"
    echo "none1:$(depth_mode_classify_override "what does this PR do")"
    echo "none2:$(depth_mode_classify_override "")"
  ) > "$sb/classify.out"

  assert_eq "override-explain-things-more-guided" "guided1:guided" "$(sed -n '1p' "$sb/classify.out")"
  assert_eq "override-explain-more-guided" "guided2:guided" "$(sed -n '2p' "$sb/classify.out")"
  assert_eq "override-dont-know-terms-guided" "guided3:guided" "$(sed -n '3p' "$sb/classify.out")"
  assert_eq "override-skip-explanations-terse" "terse1:terse" "$(sed -n '4p' "$sb/classify.out")"
  assert_eq "override-be-terse-terse" "terse2:terse" "$(sed -n '5p' "$sb/classify.out")"
  assert_eq "override-know-this-already-terse" "terse3:terse" "$(sed -n '6p' "$sb/classify.out")"
  assert_eq "override-unrelated-phrase-no-match" "none1:" "$(sed -n '7p' "$sb/classify.out")"
  assert_eq "override-empty-phrase-no-match" "none2:" "$(sed -n '8p' "$sb/classify.out")"

  rm -rf "$sb"
}

# ============================================================
# depth_mode_report — FR-9 transparency text
# ============================================================

case_report() {
  local sb
  sb=$(make_sandbox)
  (
    cd "$sb" || exit 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-depth-mode.sh
    depth_mode_report
  ) > "$sb/report_default.out"

  if grep -qi "^Terse" "$sb/report_default.out" && grep -qi "explain more" "$sb/report_default.out"; then
    PASS=$((PASS+1)); echo "PASS [report-default-terse-mentions-switch-phrase]"
  else
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES report-default-terse-mentions-switch-phrase"
    echo "FAIL [report-default-terse-mentions-switch-phrase]: $(cat "$sb/report_default.out")" >&2
  fi

  mkdir -p "$sb/.claude/session"
  printf 'guided' > "$sb/.claude/session/onboarding-depth-mode"
  (
    cd "$sb" || exit 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-depth-mode.sh
    depth_mode_report
  ) > "$sb/report_guided.out"

  if grep -qi "^Guided" "$sb/report_guided.out" && grep -qi "be terse" "$sb/report_guided.out"; then
    PASS=$((PASS+1)); echo "PASS [report-guided-mentions-switch-phrase]"
  else
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES report-guided-mentions-switch-phrase"
    echo "FAIL [report-guided-mentions-switch-phrase]: $(cat "$sb/report_guided.out")" >&2
  fi

  rm -rf "$sb"
}

# ============================================================
# INVARIANT — depth mode never touches a gate/permission/approval marker
#
# Exercises derive -> write -> override -> report end-to-end (a full
# simulated session), then asserts NOTHING under .claude/session/reviews/
# exists and no *-rex.approved / *-ceo.approved / *-security.approved /
# *-architecture.approved file exists anywhere in the sandbox. This is
# the mechanical guard for design § "Depth mode is presentation only".
# ============================================================

case_invariant_no_gate_marker() {
  local sb
  sb=$(make_sandbox)

  # Seed an inc-1 tech-level signal, same as /onboard would have written.
  printf 'non-engineer' > "$sb/.claude/session/onboarding-tech-level"

  (
    cd "$sb" || exit 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-depth-mode.sh

    # 1. Derive from the seeded signal (non-engineer -> guided).
    signal=$(cat .claude/session/onboarding-tech-level)
    mode=$(depth_mode_derive_from_signal "$signal") || mode="terse"
    depth_mode_write "$mode"

    # 2. Adopter asks a transparency question.
    depth_mode_report >/dev/null

    # 3. Adopter overrides mid-session.
    new_mode=$(depth_mode_classify_override "actually, be terse from now on")
    [ -n "$new_mode" ] && depth_mode_write "$new_mode"

    # 4. Adopter asks again post-override.
    depth_mode_report >/dev/null

    # 5. An ambiguous/ill-formed override attempt — must not write anything odd.
    depth_mode_classify_override "hmm not sure" >/dev/null
  )

  # -- Assertion 1: the .claude/session/reviews/ directory was never created --
  if [ -d "$sb/.claude/session/reviews" ]; then
    echo "FAIL [invariant-no-reviews-dir]: .claude/session/reviews/ exists after exercising depth-mode functions" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES invariant-no-reviews-dir"
  else
    PASS=$((PASS+1)); echo "PASS [invariant-no-reviews-dir]"
  fi

  # -- Assertion 2: no gate/approval marker file exists anywhere in the sandbox --
  local hits
  hits=$(find "$sb" -type f \( \
      -name "*-rex.approved" -o \
      -name "*-ceo.approved" -o \
      -name "*-security.approved" -o \
      -name "*-architecture.approved" \
    \) 2>/dev/null)
  if [ -n "$hits" ]; then
    echo "FAIL [invariant-no-approval-marker-anywhere]: found $hits" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES invariant-no-approval-marker-anywhere"
  else
    PASS=$((PASS+1)); echo "PASS [invariant-no-approval-marker-anywhere]"
  fi

  # -- Assertion 3: the ONLY files under .claude/session/ are the depth-mode
  #    marker itself and the pre-seeded tech-level signal — no surprise state.
  local session_files
  session_files=$(cd "$sb/.claude/session" && find . -type f | sed 's|^\./||' | sort | tr '\n' ',')
  local expected="onboarding-depth-mode,onboarding-tech-level,"
  if [ "$session_files" = "$expected" ]; then
    PASS=$((PASS+1)); echo "PASS [invariant-only-expected-session-files]"
  else
    echo "FAIL [invariant-only-expected-session-files]: expected '$expected', got '$session_files'" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES invariant-only-expected-session-files"
  fi

  # -- Assertion 4: the final mode reflects the override (terse), proving the
  #    override path actually took effect during the same run as the checks
  #    above (not just a no-op that happened to leave no marker).
  local final_mode
  final_mode=$(cat "$sb/.claude/session/onboarding-depth-mode" 2>/dev/null)
  assert_eq "invariant-override-took-effect" "terse" "$final_mode"

  rm -rf "$sb"
}

case_derive
case_read_default
case_write
case_classify_override
case_report
case_invariant_no_gate_marker

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED_CASES" >&2
  exit 1
fi
exit 0
