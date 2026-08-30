#!/bin/bash
# Tests for .claude/hooks/warn-unqualified-review-marker.sh
#
# Advisory detector (me2resh/apexyard#1144) for approval markers written to the
# bare-number path `<pr>-<role>.approved` instead of the repo-qualified
# `<owner>__<repo>__<pr>-<role>.approved` form every gate actually reads.
#
# Covered:
#   1.  clean reviews dir (only qualified markers)      → silent, exit 0
#   2.  bare-number rex marker                          → warns, names it, exit 0
#   3.  bare-number marker for each other role          → warns
#   4.  no reviews dir at all                           → silent, exit 0
#   5.  PostToolUse payload with no `.approved`         → fast-path skip (silent)
#       even when an offender exists
#   6.  PostToolUse payload mentioning `.approved`      → scans, warns
#   7.  SessionStart payload (no tool_input)            → scans, warns
#   8.  unparseable / empty payload                     → scans (fail-open to
#       detection, never silently disabled)
#   9.  the warning names the wrong fix as wrong        → "Do NOT rename"
#   10. non-marker junk in the reviews dir              → ignored
#   11. never blocks: exit 0 even with offenders present
#   12. the lib helpers emit the two path shapes + the right re-run skill
#   13. unqualified_marker_hint fires only when the near-miss file exists
#   14. old (pre-AgDR-0060) markers only → one quiet summary line, not a list
#   15. mixed old + fresh                → fresh named individually, old counted
#   16. more than MAX_LISTED fresh ones  → list capped with "…and N more"
#   17. no shipped instruction quotes a bare-number marker path (regression
#       guard on the CAUSE — an instruction that models the wrong path is the
#       #1144 vector itself, not a typo)
#
# Exit 0 means all cases passed. Exit 1 on any failure (all cases still run).

set -u

export APEXYARD_OPS_DISABLE_PIN=1

HOOK_DIR_SRC="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SRC="$HOOK_DIR_SRC/warn-unqualified-review-marker.sh"
LIB_OPS_ROOT="$HOOK_DIR_SRC/_lib-ops-root.sh"
LIB_MARKERS="$HOOK_DIR_SRC/_lib-review-markers.sh"

for f in "$HOOK_SRC" "$LIB_OPS_ROOT" "$LIB_MARKERS"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file not found at $f" >&2
    exit 1
  fi
done
if [ ! -x "$HOOK_SRC" ]; then
  echo "FAIL: hook is not executable: $HOOK_SRC" >&2
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
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session/reviews"
  cp "$HOOK_SRC" "$sb/.claude/hooks/warn-unqualified-review-marker.sh"
  cp "$LIB_OPS_ROOT" "$sb/.claude/hooks/_lib-ops-root.sh"
  cp "$LIB_MARKERS" "$sb/.claude/hooks/_lib-review-markers.sh"
  chmod +x "$sb/.claude/hooks/warn-unqualified-review-marker.sh"
  echo "$sb"
}

# run_hook <sandbox> <stdin_payload> <expect_grep|""> <case_name>
# An empty expect_grep asserts SILENCE. Always asserts exit 0 (advisory hook).
run_hook() {
  local sb="$1" payload="$2" expect_grep="$3" case_name="$4"
  local stderr_file rc ok=1
  stderr_file=$(mktemp)
  (
    cd "$sb" || exit 1
    printf '%s' "$payload" | "$sb/.claude/hooks/warn-unqualified-review-marker.sh" 2>"$stderr_file"
  )
  rc=$?

  if [ "$rc" != "0" ]; then
    echo "FAIL [$case_name]: exit $rc (an advisory hook must always exit 0)" >&2
    ok=0
  fi

  if [ -z "$expect_grep" ]; then
    if [ -s "$stderr_file" ]; then
      echo "FAIL [$case_name]: expected silence, got stderr" >&2
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

SHA="2933a06e28a1e98aee8cdef18a0dcaaa0f610b08"
# A PostToolUse payload whose text never mentions a marker → fast-path skip.
PAYLOAD_IRRELEVANT='{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"npm test"}}'
# A PostToolUse payload that does mention one → full scan.
PAYLOAD_MARKER='{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"printf %s sha > .claude/session/reviews/42-rex.approved"}}'
PAYLOAD_SESSION_START='{"hook_event_name":"SessionStart"}'

# ---------- CASE 1: only qualified markers → silent ----------
case1() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "$SHA" > "$sb/.claude/session/reviews/me2resh__apexyard__42-rex.approved"
  printf '%s\n' "$SHA" > "$sb/.claude/session/reviews/me2resh__apexyard__42-architecture.approved"
  run_hook "$sb" "$PAYLOAD_SESSION_START" "" "qualified-only-silent"
  rm -rf "$sb"
}

# ---------- CASE 2: bare-number rex marker → warns and names it ----------
case2() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "$SHA" > "$sb/.claude/session/reviews/42-rex.approved"
  run_hook "$sb" "$PAYLOAD_SESSION_START" "42-rex\.approved" "bare-rex-detected"
  rm -rf "$sb"
}

# ---------- CASE 3: every other role is detected too ----------
case3() {
  local role
  for role in ceo security architecture design; do
    local sb; sb=$(make_sandbox)
    printf '%s\n' "$SHA" > "$sb/.claude/session/reviews/7-${role}.approved"
    run_hook "$sb" "$PAYLOAD_SESSION_START" "7-${role}\.approved" "bare-${role}-detected"
    rm -rf "$sb"
  done
}

# ---------- CASE 4: no reviews dir at all → silent ----------
case4() {
  local sb; sb=$(make_sandbox)
  rmdir "$sb/.claude/session/reviews"
  run_hook "$sb" "$PAYLOAD_SESSION_START" "" "no-reviews-dir-silent"
  rm -rf "$sb"
}

# ---------- CASE 5: irrelevant PostToolUse payload → fast-path skip ----------
# The offender IS present; the hook must still stay silent, because scanning on
# every Write/Bash in a session is the cost this fast path exists to avoid.
case5() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "$SHA" > "$sb/.claude/session/reviews/42-rex.approved"
  run_hook "$sb" "$PAYLOAD_IRRELEVANT" "" "irrelevant-payload-fast-skip"
  rm -rf "$sb"
}

# ---------- CASE 6: marker-mentioning PostToolUse payload → scans ----------
case6() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "$SHA" > "$sb/.claude/session/reviews/42-rex.approved"
  run_hook "$sb" "$PAYLOAD_MARKER" "42-rex\.approved" "marker-payload-scans"
  rm -rf "$sb"
}

# ---------- CASE 7: SessionStart sweep sees prior-session leftovers ----------
case7() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "$SHA" > "$sb/.claude/session/reviews/99-security.approved"
  run_hook "$sb" "$PAYLOAD_SESSION_START" "no gate reads this" "sessionstart-sweep"
  rm -rf "$sb"
}

# ---------- CASE 8: empty/unparseable payload → still scans ----------
# Fail-open to DETECTION, not to silence: an unrecognised payload shape must
# never quietly disable the detector.
case8() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "$SHA" > "$sb/.claude/session/reviews/42-rex.approved"
  run_hook "$sb" "" "42-rex\.approved" "empty-payload-still-scans"
  rm -rf "$sb"
  sb=$(make_sandbox)
  printf '%s\n' "$SHA" > "$sb/.claude/session/reviews/42-rex.approved"
  run_hook "$sb" "not json at all" "42-rex\.approved" "garbage-payload-still-scans"
  rm -rf "$sb"
}

# ---------- CASE 9: the warning names the WRONG fix as wrong ----------
# The whole point of #1144: relocating the file is the tempting repair and it is
# marker forging. If this assertion ever fails, the hook has lost its reason to
# exist.
case9() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "$SHA" > "$sb/.claude/session/reviews/42-rex.approved"
  run_hook "$sb" "$PAYLOAD_SESSION_START" "Do NOT rename or move" "warns-against-relocating"
  rm -rf "$sb"
}

# ---------- CASE 10: unrelated files in the reviews dir are ignored ----------
case10() {
  local sb; sb=$(make_sandbox)
  printf 'x\n' > "$sb/.claude/session/reviews/README.md"
  printf 'x\n' > "$sb/.claude/session/reviews/notes.txt"
  printf 'x\n' > "$sb/.claude/session/reviews/abc-rex.approved"      # non-numeric PR
  printf 'x\n' > "$sb/.claude/session/reviews/42-unknownrole.approved" # unknown role
  run_hook "$sb" "$PAYLOAD_SESSION_START" "" "junk-ignored"
  rm -rf "$sb"
}

# ---------- CASE 11: offenders are never deleted or renamed ----------
# Advisory means advisory. The hook must leave the file exactly where it found
# it — deleting would destroy a reviewer's work product on a false positive, and
# renaming would BE the forgery it warns about.
case11() {
  local sb; sb=$(make_sandbox)
  local m="$sb/.claude/session/reviews/42-rex.approved"
  printf '%s\n' "$SHA" > "$m"
  run_hook "$sb" "$PAYLOAD_SESSION_START" "42-rex\.approved" "advisory-does-not-mutate"
  if [ ! -f "$m" ]; then
    echo "FAIL [advisory-does-not-mutate]: hook removed the marker file" >&2
    FAIL=$((FAIL+1)); PASS=$((PASS-1))
    FAILED_CASES="$FAILED_CASES advisory-does-not-mutate-mutation"
  fi
  if [ -f "$sb/.claude/session/reviews/me2resh__apexyard__42-rex.approved" ]; then
    echo "FAIL [advisory-does-not-mutate]: hook created a qualified marker (forgery)" >&2
    FAIL=$((FAIL+1)); PASS=$((PASS-1))
    FAILED_CASES="$FAILED_CASES advisory-does-not-mutate-forgery"
  fi
  rm -rf "$sb"
}

# ---------- CASE 12: lib helpers resolve the two shapes correctly ----------
case12() {
  local out expected_q expected_u
  out=$(
    # shellcheck source=/dev/null
    . "$LIB_MARKERS"
    printf '%s|%s|%s' \
      "$(review_marker_path me2resh/apexyard 1144 rex /mh)" \
      "$(unqualified_marker_path /mh 1144 rex)" \
      "$(review_role_skill security)"
  )
  expected_q="/mh/.claude/session/reviews/me2resh__apexyard__1144-rex.approved"
  expected_u="/mh/.claude/session/reviews/1144-rex.approved"
  if [ "$out" = "${expected_q}|${expected_u}|/security-review" ]; then
    PASS=$((PASS+1)); echo "PASS [lib-helpers-shape]"
  else
    echo "FAIL [lib-helpers-shape]: got $out" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES lib-helpers-shape"
  fi
}

# ---------- CASE 13: unqualified_marker_hint fires only on an existing file ----------
case13() {
  local sb hint rc ok=1
  sb=$(mktemp -d)
  mkdir -p "$sb/.claude/session/reviews"

  # No file → silent, non-zero.
  hint=$(
    # shellcheck source=/dev/null
    . "$LIB_MARKERS"; unqualified_marker_hint "$sb" 42 rex "/expected/path"
  ) && rc=0 || rc=1
  if [ "$rc" != "1" ] || [ -n "$hint" ]; then
    echo "FAIL [hint-silent-without-file]: rc=$rc out='$hint'" >&2; ok=0
  fi

  # File present → emits the diagnosis, names both paths and the re-run skill.
  printf '%s\n' "$SHA" > "$sb/.claude/session/reviews/42-rex.approved"
  hint=$(
    # shellcheck source=/dev/null
    . "$LIB_MARKERS"; unqualified_marker_hint "$sb" 42 rex "/expected/path"
  ) && rc=0 || rc=1
  if [ "$rc" != "0" ]; then
    echo "FAIL [hint-fires-with-file]: rc=$rc" >&2; ok=0
  fi
  for needle in "NEAR MISS" "42-rex.approved" "/expected/path" "Do NOT rename" "/code-review 42"; do
    case "$hint" in
      *"$needle"*) ;;
      *) echo "FAIL [hint-fires-with-file]: missing '$needle'" >&2; ok=0 ;;
    esac
  done

  if [ "$ok" = "1" ]; then
    PASS=$((PASS+1)); echo "PASS [hint-behaviour]"
  else
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES hint-behaviour"
  fi
  rm -rf "$sb"
}

# ---------- CASE 14: only OLD markers → one quiet summary line ----------
# Any fork predating #485 has a pile of these. Re-listing them every SessionStart
# is how an advisory hook teaches the operator to scroll past it.
case14() {
  local sb; sb=$(make_sandbox)
  local i
  for i in 53 57 62; do
    printf '%s\n' "$SHA" > "$sb/.claude/session/reviews/${i}-rex.approved"
    touch -t 202001010000 "$sb/.claude/session/reviews/${i}-rex.approved"
  done
  run_hook "$sb" "$PAYLOAD_SESSION_START" "3 bare-number approval marker" "old-markers-summarised"
  # The noisy per-file banner must NOT appear for archaeology.
  local stderr_file; stderr_file=$(mktemp)
  ( cd "$sb" || exit 1; printf '%s' "$PAYLOAD_SESSION_START" | "$sb/.claude/hooks/warn-unqualified-review-marker.sh" 2>"$stderr_file" )
  if grep -q "Do NOT rename or move" "$stderr_file"; then
    echo "FAIL [old-markers-summarised]: full banner printed for legacy-only markers" >&2
    FAIL=$((FAIL+1)); PASS=$((PASS-1)); FAILED_CASES="$FAILED_CASES old-markers-noisy"
  fi
  rm -f "$stderr_file"; rm -rf "$sb"
}

# ---------- CASE 15: mixed → fresh named individually, old merely counted ----------
case15() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "$SHA" > "$sb/.claude/session/reviews/53-rex.approved"
  touch -t 202001010000 "$sb/.claude/session/reviews/53-rex.approved"
  printf '%s\n' "$SHA" > "$sb/.claude/session/reviews/1144-rex.approved"   # fresh
  local stderr_file ok=1; stderr_file=$(mktemp)
  ( cd "$sb" || exit 1; printf '%s' "$PAYLOAD_SESSION_START" | "$sb/.claude/hooks/warn-unqualified-review-marker.sh" 2>"$stderr_file" )
  grep -q "1144-rex.approved" "$stderr_file" || { echo "FAIL [mixed]: fresh marker not named" >&2; ok=0; }
  grep -q "Do NOT rename or move" "$stderr_file" || { echo "FAIL [mixed]: full banner missing" >&2; ok=0; }
  grep -qE "1 older bare-number marker" "$stderr_file" || { echo "FAIL [mixed]: legacy count not reported" >&2; ok=0; }
  grep -q "• 53-rex.approved" "$stderr_file" && { echo "FAIL [mixed]: legacy marker listed individually" >&2; ok=0; }
  if [ "$ok" = "1" ]; then PASS=$((PASS+1)); echo "PASS [mixed-fresh-and-legacy]"
  else sed 's/^/    stderr: /' "$stderr_file" >&2; FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES mixed-fresh-and-legacy"; fi
  rm -f "$stderr_file"; rm -rf "$sb"
}

# ---------- CASE 16: more than MAX_LISTED fresh offenders → capped list ----------
case16() {
  local sb; sb=$(make_sandbox)
  local i
  for i in $(seq 1 13); do
    printf '%s\n' "$SHA" > "$sb/.claude/session/reviews/${i}-rex.approved"
  done
  run_hook "$sb" "$PAYLOAD_SESSION_START" "…and 3 more" "listing-capped"
  rm -rf "$sb"
}

# ---------- CASE 17: no shipped instruction quotes a bare-number path ----------
# The cause half of #1144. auto-code-review.sh's banner used to end with
# "...until a Rex approval file exists at .claude/session/reviews/<pr>-rex.approved"
# — printed at the orchestrator on EVERY PR creation, which is the single
# highest-traffic place the framework could hand an agent the gate-invisible
# path. Guard the whole instruction surface, not just that one file.
#
# TRACKED FILES ONLY (the #1154 precedent). An adopter fork's .claude/skills/
# holds their own private skills, often symlinked in; a recursive grep over the
# directory would fail this test on content the framework does not ship and
# cannot fix. Enumerate via `git ls-files` so the assertion covers exactly the
# framework's own instruction surface. Skipped outside a git checkout.
#
# Deliberate anti-pattern illustrations DO exist — pr-workflow.md quotes the bad
# spawn-prompt line, eval-agents/SKILL.md quotes a historical bad command — and
# showing the wrong path is the point in both. Those opt out with an inline
# `bare-marker-example` marker, the same visible-escape-hatch convention as
# `<!-- private-refs: allow -->` and `<!-- agdr: not-applicable -->`. The marker
# has to be typed on purpose, so an accidental bare path still fails.
case17() {
  local repo_root files hit ok=1
  repo_root=$(cd "$HOOK_DIR_SRC" && git rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$repo_root" ]; then
    echo "SKIP [no-literal-bare-marker-paths]: not a git checkout"
    return 0
  fi

  # NOTE: git pathspec `*` crosses `/`, so '.claude/hooks/*.sh' also matches
  # '.claude/hooks/tests/*.sh'. Test files legitimately create bare-number
  # markers as FIXTURES — that is what they are testing — so they are filtered
  # out below rather than excluded here; they are not instruction surface.
  files=$(cd "$repo_root" && git ls-files \
            '.claude/hooks/*.sh' '.claude/agents/*.md' \
            '.claude/skills/*/SKILL.md' '.claude/rules/*.md' 2>/dev/null)
  if [ -z "$files" ]; then
    echo "SKIP [no-literal-bare-marker-paths]: no tracked instruction files found"
    return 0
  fi

  # A bare-number marker path in prose: `.claude/session/reviews/<x>-<role>.approved`
  # where <x> carries no `__` repo qualifier and is not an explicit wildcard
  # (`*-rex.approved` is a legitimate way to name the class).
  hit=$(cd "$repo_root" && printf '%s\n' "$files" | tr '\n' '\0' \
        | xargs -0 grep -nE '\.claude/session/reviews/[^ `"'"'"'*]*-(rex|ceo|security|architecture|design)\.approved' 2>/dev/null \
        | grep -v '__' \
        | grep -v 'bare-marker-example' \
        | grep -v '/tests/' \
        | grep -v 'warn-unqualified-review-marker\.sh' \
        | grep -v '_lib-review-markers\.sh' || true)

  if [ -n "$hit" ]; then
    echo "FAIL [no-literal-bare-marker-paths]: shipped instructions quote a gate-invisible path:" >&2
    printf '%s\n' "$hit" | sed 's/^/    /' >&2
    ok=0
  fi
  if [ "$ok" = "1" ]; then PASS=$((PASS+1)); echo "PASS [no-literal-bare-marker-paths]"
  else FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES no-literal-bare-marker-paths"; fi
}

case1; case2; case3; case4; case5; case6
case7; case8; case9; case10; case11; case12; case13
case14; case15; case16; case17

echo
echo "----------------------------------------"
echo "PASS: $PASS   FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED_CASES" >&2
  exit 1
fi
exit 0
