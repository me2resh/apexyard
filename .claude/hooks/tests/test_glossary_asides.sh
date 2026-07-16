#!/bin/bash
# Unit tests for .claude/hooks/_lib-onboarding-glossary-seen.sh
#
# Ticket: me2resh/apexyard#913 (increment-2 M5 — teach-in-context glossary
# + just-in-time asides). Technical design:
# docs/technical-designs/onboarding-increment-2.md § D1/D3/D7.
#
# Coverage (per the design's Testing Strategy for #913 t4):
#   - terse mode -> zero asides, seen-set untouched
#   - guided mode, first mention of a term -> aside fires, key recorded
#   - guided mode, second mention of the SAME term -> no aside (already
#     seen), seen-set unchanged
#   - unknown term key -> no aside, seen-set untouched
#   - glossary_term_body slices the right section and excludes the
#     **Example**: line (asides are a short parenthetical, not the whole
#     entry)
#   - INVARIANT: exercising the aside path for all five terms across both
#     modes never writes a gate/permission/approval marker
#     (`.claude/session/reviews/**`, `*-rex.approved`, `*-ceo.approved`,
#     `*-security.approved`, `*-architecture.approved`) — the same
#     mechanical guard #914's test_depth_mode.sh established for design
#     § "Depth mode is presentation only"
#
# Each case builds an isolated sandbox repo (with a real docs/onboarding/
# glossary.md fixture), sources the lib inside it, and asserts
# stdout/return-code/file-state. Exit 0 means all cases passed. Exit 1 on
# any failure (all cases still run).

set -u

export APEXYARD_OPS_DISABLE_PIN=1

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB_SRC="$HOOKS_DIR/_lib-onboarding-glossary-seen.sh"
DEPTH_MODE_LIB_SRC="$HOOKS_DIR/_lib-onboarding-depth-mode.sh"
LIB_OPS_ROOT="$HOOKS_DIR/_lib-ops-root.sh"
REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
GLOSSARY_SRC="$REPO_ROOT/docs/onboarding/glossary.md"

if [ ! -f "$LIB_SRC" ]; then
  echo "FAIL: lib not found at $LIB_SRC" >&2
  exit 1
fi
if [ ! -f "$DEPTH_MODE_LIB_SRC" ]; then
  echo "FAIL: _lib-onboarding-depth-mode.sh not found at $DEPTH_MODE_LIB_SRC" >&2
  exit 1
fi
if [ ! -f "$LIB_OPS_ROOT" ]; then
  echo "FAIL: _lib-ops-root.sh not found at $LIB_OPS_ROOT" >&2
  exit 1
fi
if [ ! -f "$GLOSSARY_SRC" ]; then
  echo "FAIL: docs/onboarding/glossary.md not found at $GLOSSARY_SRC" >&2
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
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session" "$sb/docs/onboarding"
  cp "$LIB_SRC" "$sb/.claude/hooks/_lib-onboarding-glossary-seen.sh"
  cp "$DEPTH_MODE_LIB_SRC" "$sb/.claude/hooks/_lib-onboarding-depth-mode.sh"
  cp "$LIB_OPS_ROOT" "$sb/.claude/hooks/_lib-ops-root.sh"
  cp "$GLOSSARY_SRC" "$sb/docs/onboarding/glossary.md"
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

# assert_true <case_name> <bash-condition-as-string, already evaluated 0/1>
assert_rc0() {
  local case_name="$1" rc="$2"
  if [ "$rc" = "0" ]; then
    PASS=$((PASS+1))
    echo "PASS [$case_name]"
  else
    echo "FAIL [$case_name]: expected rc 0, got rc $rc" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="$FAILED_CASES $case_name"
  fi
}

assert_rc1() {
  local case_name="$1" rc="$2"
  if [ "$rc" = "1" ]; then
    PASS=$((PASS+1))
    echo "PASS [$case_name]"
  else
    echo "FAIL [$case_name]: expected rc 1, got rc $rc" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="$FAILED_CASES $case_name"
  fi
}

# ============================================================
# terse mode -> zero asides, seen-set untouched (the critical case)
# ============================================================

case_terse_zero_asides() {
  local sb out rc
  sb=$(make_sandbox)
  (
    cd "$sb" || exit 1
    printf '%s' "terse" > .claude/session/onboarding-depth-mode
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-glossary-seen.sh

    out=$(glossary_maybe_aside "ticket"); rc=$?
    echo "$out:$rc"
  ) > "$sb/out.txt"

  assert_eq "terse-no-aside-empty-output" ":1" "$(cat "$sb/out.txt")"

  if [ -f "$sb/.claude/session/onboarding-glossary-seen" ]; then
    echo "FAIL [terse-seen-set-untouched]: seen-set marker created in terse mode" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES terse-seen-set-untouched"
  else
    PASS=$((PASS+1)); echo "PASS [terse-seen-set-untouched]"
  fi
  rm -rf "$sb"
}

# Absent depth-mode marker entirely (safe default -> terse, D7).
case_absent_marker_defaults_terse() {
  local sb out rc
  sb=$(make_sandbox)
  (
    cd "$sb" || exit 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-glossary-seen.sh
    out=$(glossary_maybe_aside "merge"); rc=$?
    echo "$out:$rc"
  ) > "$sb/out.txt"

  assert_eq "absent-marker-defaults-terse-no-aside" ":1" "$(cat "$sb/out.txt")"
  rm -rf "$sb"
}

# ============================================================
# guided mode — first mention fires, records the key
# ============================================================

case_guided_first_mention() {
  local sb out rc seen
  sb=$(make_sandbox)
  (
    cd "$sb" || exit 1
    printf '%s' "guided" > .claude/session/onboarding-depth-mode
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-glossary-seen.sh
    out=$(glossary_maybe_aside "ticket"); rc=$?
    echo "$out"
    echo "RC:$rc"
  ) > "$sb/out.txt"

  rc=$(grep '^RC:' "$sb/out.txt" | cut -d: -f2)
  body=$(grep -v '^RC:' "$sb/out.txt")

  assert_rc0 "guided-first-mention-fires" "$rc"

  if [ -n "$body" ]; then
    PASS=$((PASS+1)); echo "PASS [guided-first-mention-nonempty-body]"
  else
    echo "FAIL [guided-first-mention-nonempty-body]: expected non-empty aside body" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES guided-first-mention-nonempty-body"
  fi

  # Body must not contain the Example line — asides are a short
  # parenthetical, not the whole glossary entry.
  if printf '%s' "$body" | grep -q '\*\*Example\*\*'; then
    echo "FAIL [guided-aside-excludes-example]: aside body leaked the Example line" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES guided-aside-excludes-example"
  else
    PASS=$((PASS+1)); echo "PASS [guided-aside-excludes-example]"
  fi

  seen=$(cat "$sb/.claude/session/onboarding-glossary-seen" 2>/dev/null)
  assert_eq "guided-first-mention-key-recorded" "ticket" "$seen"

  rm -rf "$sb"
}

# ============================================================
# guided mode — second mention of the SAME term is suppressed
# ============================================================

case_guided_second_mention_suppressed() {
  local sb rc1 rc2 seen_after
  sb=$(make_sandbox)
  (
    cd "$sb" || exit 1
    printf '%s' "guided" > .claude/session/onboarding-depth-mode
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-glossary-seen.sh
    glossary_maybe_aside "merge" >/dev/null; echo "rc1=$?"
    glossary_maybe_aside "merge" >/dev/null; echo "rc2=$?"
  ) > "$sb/out.txt"

  rc1=$(grep '^rc1=' "$sb/out.txt" | cut -d= -f2)
  rc2=$(grep '^rc2=' "$sb/out.txt" | cut -d= -f2)

  assert_rc0 "guided-second-mention-first-call-fires" "$rc1"
  assert_rc1 "guided-second-mention-suppressed" "$rc2"

  seen_after=$(cat "$sb/.claude/session/onboarding-glossary-seen" 2>/dev/null | wc -l | tr -d '[:space:]')
  assert_eq "guided-second-mention-no-duplicate-key" "1" "$seen_after"

  rm -rf "$sb"
}

# guided mode — different terms each get their own aside, in order.
case_guided_multiple_distinct_terms() {
  local sb seen
  sb=$(make_sandbox)
  (
    cd "$sb" || exit 1
    printf '%s' "guided" > .claude/session/onboarding-depth-mode
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-glossary-seen.sh
    glossary_maybe_aside "ticket" >/dev/null
    glossary_maybe_aside "branch" >/dev/null
    glossary_maybe_aside "ticket" >/dev/null   # repeat — must not re-add
  )

  seen=$(cat "$sb/.claude/session/onboarding-glossary-seen" 2>/dev/null | tr '\n' ',')
  assert_eq "guided-multiple-terms-recorded-once-each" "ticket,branch," "$seen"
  rm -rf "$sb"
}

# ============================================================
# unknown term key — no aside, no seen-set write
# ============================================================

case_unknown_term() {
  local sb out rc
  sb=$(make_sandbox)
  (
    cd "$sb" || exit 1
    printf '%s' "guided" > .claude/session/onboarding-depth-mode
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-glossary-seen.sh
    out=$(glossary_maybe_aside "nonexistent-term"); rc=$?
    echo "$out:$rc"
  ) > "$sb/out.txt"

  assert_eq "unknown-term-no-aside" ":1" "$(cat "$sb/out.txt")"

  if [ -f "$sb/.claude/session/onboarding-glossary-seen" ]; then
    echo "FAIL [unknown-term-seen-set-untouched]: seen-set created for an unknown term" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES unknown-term-seen-set-untouched"
  else
    PASS=$((PASS+1)); echo "PASS [unknown-term-seen-set-untouched]"
  fi
  rm -rf "$sb"
}

# ============================================================
# glossary_term_body — comma-key aliasing (issue vs ticket -> same entry)
# ============================================================

case_term_body_alias() {
  local sb issue_body ticket_body
  sb=$(make_sandbox)
  (
    cd "$sb" || exit 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-glossary-seen.sh
    printf '%s\n' "$(glossary_term_body "issue")"
    echo "---SPLIT---"
    printf '%s\n' "$(glossary_term_body "ticket")"
  ) > "$sb/out.txt"

  issue_body=$(sed -n '1,/^---SPLIT---$/p' "$sb/out.txt" | sed '$d')
  ticket_body=$(sed -n '/^---SPLIT---$/,$p' "$sb/out.txt" | tail -n +2)

  assert_eq "term-body-alias-issue-eq-ticket" "$issue_body" "$ticket_body"

  if [ -n "$issue_body" ]; then
    PASS=$((PASS+1)); echo "PASS [term-body-alias-nonempty]"
  else
    echo "FAIL [term-body-alias-nonempty]: expected non-empty body for 'issue'/'ticket'" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES term-body-alias-nonempty"
  fi
  rm -rf "$sb"
}

# ============================================================
# INVARIANT: exercising the aside path never writes a gate/approval
# marker anywhere in the sandbox — mirrors #914's
# case_invariant_no_gate_marker in test_depth_mode.sh.
# ============================================================

case_invariant_no_gate_marker() {
  local sb
  sb=$(make_sandbox)

  (
    cd "$sb" || exit 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-onboarding-glossary-seen.sh

    # Terse pass first (should be fully inert).
    printf '%s' "terse" > .claude/session/onboarding-depth-mode
    for t in issue pr merge branch ci; do
      glossary_maybe_aside "$t" >/dev/null
    done

    # Now flip to guided and exercise all five terms, twice each.
    printf '%s' "guided" > .claude/session/onboarding-depth-mode
    for t in issue pr merge branch ci; do
      glossary_maybe_aside "$t" >/dev/null
      glossary_maybe_aside "$t" >/dev/null
    done
  )

  # -- Assertion 1: .claude/session/reviews/ was never created --
  if [ -d "$sb/.claude/session/reviews" ]; then
    echo "FAIL [invariant-no-reviews-dir]: .claude/session/reviews/ exists after exercising glossary-aside functions" >&2
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

  # -- Assertion 3: the ONLY files under .claude/session/ are the two
  #    markers this run legitimately touches — no surprise state.
  local session_files expected
  session_files=$(cd "$sb/.claude/session" && find . -type f | sed 's|^\./||' | sort | tr '\n' ',')
  expected="onboarding-depth-mode,onboarding-glossary-seen,"
  assert_eq "invariant-only-expected-session-files" "$expected" "$session_files"

  # -- Assertion 4: all five terms ended up recorded exactly once each. --
  local seen_count
  seen_count=$(wc -l < "$sb/.claude/session/onboarding-glossary-seen" 2>/dev/null | tr -d '[:space:]')
  assert_eq "invariant-five-terms-recorded-once-each" "5" "$seen_count"

  rm -rf "$sb"
}

case_terse_zero_asides
case_absent_marker_defaults_terse
case_guided_first_mention
case_guided_second_mention_suppressed
case_guided_multiple_distinct_terms
case_unknown_term
case_term_body_alias
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
