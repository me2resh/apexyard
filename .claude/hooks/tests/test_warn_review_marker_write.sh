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
# #1026 SUPERSEDES THAT PROMOTION — READ THIS BEFORE THE MATRIX BELOW.
# ------------------------------------------------------------------
# The hook is ADVISORY again (exit 0 always), per AgDR-0111 (which
# supersedes AgDR-0109 parts 2-3). So every
# "BLOCKED, exit 2" in the matrix below now means **"DETECTED → warns,
# exit 0"**. The matrix is left otherwise intact on purpose: it is still an
# accurate record of what the hook DETECTS, and detection is what the cases
# exercise. Only the consequence changed.
#
# Why: #843's blocking promotion cost 13 false positives in a single session
# across 2 hooks — including a read-only grep, a commit message, a code
# review's own prose, and /approve-merge's documented merge step — while the
# split-path shape (#1026) stayed undetected. Note the OTHER known shapes
# (interpreter heredoc, BSD/GNU sed -i, variable indirection) ARE detected:
# cases 20/23/27 and 35-39 below assert exactly that, and citing them as open
# bypasses contradicts this file's own assertions. #843's root cause
# (auto-code-review.sh inducing build agents to forge markers) was fixed
# separately, so the block
# was belt-and-braces on a repaired cause. Merge integrity rests on the
# per-PR human approval plus block-unreviewed-merge.sh's forge-HEAD SHA match.
#
# Cases 41-45 pin the false-positive direction. Do NOT "restore" a block
# here without re-reading AgDR-0109 and AgDR-0104 first.
#
# Test matrix (read "BLOCKED, exit 2" as "detected → warns, exit 0"):
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
# #962 test matrix (resolved-target detection — see the hook's own #962
# header comment for the false-negative/false-positive bugs this closes):
#   (20) Bash   → variable-indirected write (review_marker_path + "$REX_MARKER"
#                 redirect), no active-reviewer marker            → BLOCKED, exit 2
#   (21) Bash   → same indirected write, WITH matching active-reviewer marker
#                                                                  → ALLOWED, exit 0
#   (22) Bash   → literal-path READ (cat) of a rex marker, no active-reviewer
#                                                                  → silent, exit 0 (NOT blocked — false-positive fix)
#   (23) Bash   → indirected tee write (review_marker_path + tee "$REX_MARKER"),
#                 no active-reviewer marker                       → BLOCKED, exit 2
#   (24) Bash   → fully ambiguous indirected write (mentions
#                 .claude/session/reviews/ but no resolvable role), WITH an
#                 active-reviewer marker present for a DIFFERENT kind
#                                                                  → BLOCKED, exit 2 (was "fail-closed on total ambiguity";
#                                                                    since #1026 the hook is a BACKSTOP and never fails
#                                                                    closed — it warns. Fail-closed is now a property of
#                                                                    the CONTROL hooks only. See the preamble above.)
#   (25) Bash   → _lib-detect-bash-write.sh missing (graceful fallback):
#                 literal-path READ (cat) of a rex marker, no active-reviewer
#                                                                  → BLOCKED, exit 2 (conservative pre-#962 fallback, not a bypass)
#
# #974 test (residual "total ambiguity" edge case — see the hook's #974
# header comment):
#   (26) Bash   → MALFORMED empty-kind active-reviewer marker
#                 ("owner/repo#<pr>:" with nothing after the colon) +
#                 an indirected write whose role can't be resolved to any of
#                 rex/ceo/security/architecture                    → BLOCKED, exit 2
#                 (without the #974 fix, both sides of the kind comparison
#                 resolve to "" and the write would be incorrectly ALLOWED)
#
# #977 test (per-PR binding on the indirect path — see the hook's #977 guard):
#   (27) Bash   → indirect write whose ROLE resolves (rex) but whose PR does
#                 NOT (variable PR arg), + an active-reviewer marker for a
#                 DIFFERENT specific PR                            → BLOCKED, exit 2
#                 (without #977, TARGET_PR="" skips the PR check and the write
#                 matches the wrong-PR active-reviewer marker → wrongly ALLOWED)
#   (28) Bash   → indirect write where BOTH role and PR resolve (literal PR,
#                 the sanctioned idiom), matching active-reviewer marker
#                                                                  → ALLOWED, exit 0 (no regression)
#
# #1000 test matrix (narrow detection to actual write intent — see the
# hook's own #1000 header comment for the three false-positive shapes this
# closes, and why #962/#970's resolved-target work was incomplete):
#   (29) Bash   → `rm -f` of active-reviewer, bundled with an unrelated
#                 command (the documented orchestrator cleanup step)
#                                                                  → NOT blocked, exit 0
#   (30) Bash   → purely READ-ONLY command (git show | grep) whose quoted
#                 grep PATTERN argument contains the substring "rm -f"
#                 (a segmentation false-positive in the shared file-mover
#                 matcher, not a real rm)                          → NOT blocked, exit 0
#   (31) Bash   → heredoc write to a non-marker scratch path whose BODY
#                 content quotes "$marker" and "active-reviewer" in prose
#                                                                  → NOT blocked, exit 0
#   (32) Bash   → the orchestrator's documented SET step (printf > literal
#                 active-reviewer path) — previously ALSO a false block,
#                 since role can never resolve for a plain printf
#                                                                  → NOT blocked, exit 0
#   (33) Bash   → `rm` bundled with a REAL literal marker forgery in the
#                 same command (rm -f active-reviewer; printf sha >
#                 <real marker path>)                              → BLOCKED, exit 2
#                 (confirms the #1000 deletion-only exemption doesn't
#                 swallow a genuine forgery riding alongside it)
#   (34) Bash   → `rm` of a REAL *.approved marker file (not
#                 active-reviewer) — deliberate narrowing: deletion can
#                 only remove evidence, it cannot forge approval content
#                                                                  → NOT blocked, exit 0 (documented behaviour change)
#
# Cases (1), (3), (4), (11), (20), (21), (23) already re-verify the
# target-based literal/indirect detection still catches every genuine
# forgery shape after #1000's narrowing (unchanged pass/fail expectations
# — see the top-of-file test matrix) — not duplicated here.
#
# Exit 0 if all cases pass; 1 on failure.

set -u

# Isolation: don't let a live session pin escape this sandbox onto the real
# ops fork (see bin/run-hook-tests.sh's rationale). No-op when unset/headless.
export APEXYARD_OPS_DISABLE_PIN=1

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/warn-review-marker-write.sh"
LIB_OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)/_lib-ops-root.sh"
LIB_MARKERS="$(cd "$(dirname "$0")/.." && pwd)/_lib-review-markers.sh"
LIB_BDW="$(cd "$(dirname "$0")/.." && pwd)/_lib-detect-bash-write.sh"

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
if [ ! -f "$LIB_BDW" ]; then
  echo "FAIL: _lib-detect-bash-write.sh not found at $LIB_BDW" >&2
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
  cp "$LIB_BDW" "$sb/.claude/hooks/_lib-detect-bash-write.sh"
  chmod +x "$sb/.claude/hooks/warn-review-marker-write.sh"
  echo "$sb"
}

# Build a sandbox with _lib-detect-bash-write.sh DELETED — used by case24 to
# verify the graceful literal-substring-only fallback when the library is
# missing (#962).
make_sandbox_no_bdw_lib() {
  local sb; sb=$(make_sandbox)
  rm -f "$sb/.claude/hooks/_lib-detect-bash-write.sh"
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
# Like bash_json, but COMMAND may contain literal newlines (a real heredoc)
# -- JSON-escapes embedded double quotes AND newlines so the payload is
# valid JSON that decodes back to a real multi-line command (#1000-round2).
bash_json_multiline() {
  local cmd="${1//\"/\\\"}"
  cmd="${cmd//$'\n'/\\n}"
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd"
}

# ---------------------------------------------------------------------------
# (1) Write → rex marker, no active-reviewer marker → DETECTED → warns, exit 0
# ---------------------------------------------------------------------------
case1() {
  local sb; sb=$(make_sandbox)
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  run_hook "$sb" "Write rex marker, no active-reviewer marker -> WARNS (advisory, #1026)" \
    "$(write_json "$marker")" 0 "WARNING"
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
  run_hook "$sb" "Bash echo redirect rex marker, no marker -> WARNS (advisory, #1026)" \
    "$(bash_json "echo 'abc123' > ${marker}")" 0 "WARNING"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (4) Bash → tee to rex marker, no active-reviewer marker → BLOCKED
# ---------------------------------------------------------------------------
case4() {
  local sb; sb=$(make_sandbox)
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  run_hook "$sb" "Bash tee rex marker, no marker -> WARNS (advisory, #1026)" \
    "$(bash_json "printf sha | tee ${marker}")" 0 "WARNING"
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
  run_hook "$sb" "Write architecture marker, no marker -> WARNS (advisory, #1026) (#843)" \
    "$(write_json "$marker")" 0 "WARNING"
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
  run_hook "$sb" "Rex advisory banner contains WARNING keyword (#1026)" \
    "$(write_json "$marker")" 0 "WARNING"
  run_hook "$sb" "Rex advisory banner still mentions BUILD-CLASS SUB-AGENT (deterrent retained)" \
    "$(write_json "$marker")" 0 "BUILD-CLASS SUB-AGENT"
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
  run_hook "$sb" "Bash printf rex marker, no marker -> WARNS (advisory, #1026)" \
    "$(bash_json "printf '%s' sha > ${marker}")" 0 "WARNING"
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
  run_hook "$sb" "Write rex marker, active-reviewer marker wrong kind -> WARNS (advisory, #1026)" \
    "$(write_json "$marker")" 0 "WARNING"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (16) Write → rex marker, active-reviewer marker wrong pr → BLOCKED
# ---------------------------------------------------------------------------
case16() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "${REPO}#999:rex" > "$sb/.claude/session/active-reviewer"
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  run_hook "$sb" "Write rex marker, active-reviewer marker wrong pr -> WARNS (advisory, #1026)" \
    "$(write_json "$marker")" 0 "WARNING"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (17) Write → rex marker, active-reviewer marker wrong repo → BLOCKED
# ---------------------------------------------------------------------------
case17() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "other-owner/other-repo#42:rex" > "$sb/.claude/session/active-reviewer"
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  run_hook "$sb" "Write rex marker, active-reviewer marker wrong repo -> WARNS (advisory, #1026)" \
    "$(write_json "$marker")" 0 "WARNING"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (18) Write → legacy bare-number marker filename, no active-reviewer marker
#      → BLOCKED
# ---------------------------------------------------------------------------
case18() {
  local sb; sb=$(make_sandbox)
  local marker="$sb/.claude/session/reviews/42-rex.approved"
  run_hook "$sb" "Write legacy bare-number marker, no marker -> WARNS (advisory, #1026)" \
    "$(write_json "$marker")" 0 "WARNING"
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

# ---------------------------------------------------------------------------
# (20) Bash → variable-indirected write, no active-reviewer marker → BLOCKED
#      (#962: the documented reviewer idiom — a `review_marker_path` call
#      assigned to a variable, then redirected into — used to evade the
#      literal-substring detector entirely. See make_indirect_rex_write().)
# ---------------------------------------------------------------------------
make_indirect_rex_write() {
  # Builds: REX_MARKER=$(review_marker_path "me2resh/apexyard" 42 rex "$MARKER_HOME"); printf '%s' sha123 > "$REX_MARKER"
  # The role ("rex") and PR ("42") arguments are literal — matching the real
  # reviewers' documented usage (code-reviewer.md / solution-architect.md) —
  # but the eventual write TARGET ("$REX_MARKER") never appears as a literal
  # path anywhere in the command text.
  # shellcheck disable=SC2016 # deliberate — the $VARs must stay literal text
  # for the hook to scan (the whole point of this indirection test case).
  printf 'REX_MARKER=$(review_marker_path "%s" 42 rex "$MARKER_HOME"); printf '"'"'%%s'"'"' sha123 > "$REX_MARKER"' "$REPO"
}

case20() {
  local sb; sb=$(make_sandbox)
  run_hook "$sb" "Bash indirected write (review_marker_path var), no marker -> WARNS (advisory, #1026) (#962)" \
    "$(bash_json "$(make_indirect_rex_write)")" 0 "WARNING"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (21) Bash → same indirected write WITH matching active-reviewer marker
#      → ALLOWED
# ---------------------------------------------------------------------------
case21() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "${REPO}#42:rex" > "$sb/.claude/session/active-reviewer"
  run_hook "$sb" "Bash indirected write, matching active-reviewer -> ALLOWED (#962)" \
    "$(bash_json "$(make_indirect_rex_write)")" 0
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (22) Bash → literal-path READ (cat) of a rex marker, no active-reviewer
#      → silent, exit 0 (#962 false-positive fix: a plain read must NOT be
#      blocked just because the literal marker path appears in the text)
# ---------------------------------------------------------------------------
case22() {
  local sb; sb=$(make_sandbox)
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  run_hook "$sb" "Bash cat (read) of literal rex marker path -> NOT blocked (#962)" \
    "$(bash_json "cat ${marker}")" 0
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (23) Bash → indirected TEE write, no active-reviewer marker → BLOCKED
#      (tee/redirect variant of the #962 indirection idiom)
# ---------------------------------------------------------------------------
case23() {
  local sb; sb=$(make_sandbox)
  local cmd
  # shellcheck disable=SC2016 # deliberate — literal text, not real expansion
  cmd=$(printf 'REX_MARKER=$(review_marker_path "%s" 42 rex "$MARKER_HOME"); echo sha123 | tee "$REX_MARKER"' "$REPO")
  run_hook "$sb" "Bash indirected tee write, no marker -> WARNS (advisory, #1026) (#962)" \
    "$(bash_json "$cmd")" 0 "WARNING"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (24) Bash → fully ambiguous indirected write (mentions .claude/session/
#      reviews/ but the role can't be resolved to any of rex/ceo/security/
#      architecture), WITH an active-reviewer marker present for a
#      DIFFERENT kind → still DETECTED (warns). Originally this demonstrated
#      "fail-closed on total ambiguity" (#962 requirement 3): an unresolved
#      role can never match a real active-reviewer marker's kind field, by
#      construction. Since #1026 the hook is a BACKSTOP and does not fail
#      closed at all — it warns. What this case still pins is the DETECTION
#      half of that property. Fail-closed now belongs exclusively to the
#      CONTROL hooks (block-unreviewed-merge.sh et al), which is precisely
#      the distinction AgDR-0104/0111 draw — do not reintroduce the phrase
#      here without meaning it.
# ---------------------------------------------------------------------------
case24() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "${REPO}#42:security" > "$sb/.claude/session/active-reviewer"
  # shellcheck disable=SC2016 # deliberate — literal text, not real expansion
  local cmd='DIR="$MARKER_HOME/.claude/session/reviews"; printf "%s" sha123 > "$DIR/mystery.approved"'
  run_hook "$sb" "Bash fully ambiguous indirected write -> WARNS (advisory, #1026) (#962 detection half)" \
    "$(bash_json "$cmd")" 0 "WARNING"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (25) Bash → _lib-detect-bash-write.sh missing: literal-path READ (cat) of a
#      rex marker, no active-reviewer marker → BLOCKED (conservative pre-#962
#      fallback — re-applies the known false-positive-on-read limitation
#      rather than silently bypassing the gate when the library is absent).
# ---------------------------------------------------------------------------
case25() {
  local sb; sb=$(make_sandbox_no_bdw_lib)
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  run_hook "$sb" "Bash cat (read) of literal rex marker, lib missing -> WARNS (advisory, #1026) (graceful fallback)" \
    "$(bash_json "cat ${marker}")" 0 "WARNING"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (26) Bash → MALFORMED empty-kind active-reviewer marker ("owner/repo#<pr>:"
#      with nothing after the colon) + an indirected write whose role can't
#      be resolved (mentions .claude/session/reviews/ but no literal
#      rex/ceo/security/architecture token) → still BLOCKED (#974).
#
#      Before #974: c_kind parses to "" from the malformed marker, MARKER_TYPE
#      resolves to "" from the unresolvable indirect write, and
#      `[ "$c_kind" = "$MARKER_TYPE" ]` -> `[ "" = "" ]` -> true, incorrectly
#      ALLOWING the write. #974 adds explicit non-empty guards on both sides
#      so this can never pass.
# ---------------------------------------------------------------------------
case26() {
  local sb; sb=$(make_sandbox)
  # Malformed marker: trailing colon, nothing after it (empty kind).
  printf '%s\n' "${REPO}#42:" > "$sb/.claude/session/active-reviewer"
  # Same fully-ambiguous indirected write shape as case24: performs a write
  # and mentions .claude/session/reviews/, but no literal role token appears
  # anywhere, so _extract_marker_role (and thus MARKER_TYPE) resolves to "".
  # shellcheck disable=SC2016 # deliberate — literal text, not real expansion
  local cmd='DIR="$MARKER_HOME/.claude/session/reviews"; printf "%s" sha123 > "$DIR/mystery.approved"'
  run_hook "$sb" "Bash empty-kind active-reviewer marker + unresolvable indirect write -> WARNS (advisory, #1026) (#974)" \
    "$(bash_json "$cmd")" 0 "WARNING"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (27) Bash → #962 INDIRECT write whose ROLE resolves (rex) but whose PR does
#      NOT (review_marker_path called with a variable PR, so _extract_marker_pr
#      recovers no literal digit), paired with an active-reviewer marker for a
#      DIFFERENT, specific PR → BLOCKED (#977).
#
#      Before #977: role rex matched the marker's kind; TARGET_PR was empty so
#      the PR-equality check was SKIPPED; TARGET_REPO is empty on the indirect
#      path so the repo check was skipped too — the write incorrectly matched
#      the pr=42 active-reviewer marker and was ALLOWED. #977 fails closed on an
#      unresolved TARGET_PR, so the gate's per-PR binding holds on this path.
# ---------------------------------------------------------------------------
case27() {
  local sb; sb=$(make_sandbox)
  # Active reviewer is authorised for PR 42 specifically.
  printf '%s\n' "${REPO}#42:rex" > "$sb/.claude/session/active-reviewer"
  # Indirect marker write: review_marker_path is called with a VARIABLE PR
  # ("$PR") so the PR number can't be recovered; role 'rex' is a literal arg so
  # it resolves. The redirection makes it a genuine write.
  # shellcheck disable=SC2016 # deliberate literal — not real expansion here
  local cmd='REX_MARKER=$(review_marker_path "$REPO" "$PR" rex "$MARKER_HOME"); printf "%s" sha123 > "$REX_MARKER"'
  run_hook "$sb" "Bash indirect write, role resolves + PR unresolved, active-reviewer for different PR -> WARNS (advisory, #1026) (#977)" \
    "$(bash_json "$cmd")" 0 "WARNING"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (28) Bash → #962 INDIRECT write where BOTH role and PR resolve (a LITERAL PR
#      in the review_marker_path call, matching the sanctioned reviewers'
#      documented idiom), against a matching active-reviewer marker → ALLOWED
#      (exit 0). Confirms #977's fail-closed guard does NOT regress the
#      legitimate reviewer flow.
# ---------------------------------------------------------------------------
case28() {
  local sb; sb=$(make_sandbox)
  printf '%s\n' "${REPO}#42:rex" > "$sb/.claude/session/active-reviewer"
  # shellcheck disable=SC2016 # deliberate literal — not real expansion here
  local cmd='REX_MARKER=$(review_marker_path "$REPO" 42 rex "$MARKER_HOME"); printf "%s" sha123 > "$REX_MARKER"'
  run_hook "$sb" "Bash indirect write, role+PR both resolve, matching active-reviewer -> ALLOWED (#977 no regression)" \
    "$(bash_json "$cmd")" 0
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (29) Bash → `rm -f` of active-reviewer, bundled with an unrelated command
#      (the documented orchestrator cleanup step from code-review/SKILL.md
#      § 0) -> NOT blocked, exit 0 (#1000 point 1).
# ---------------------------------------------------------------------------
case29() {
  local sb; sb=$(make_sandbox)
  local ar="$sb/.claude/session/active-reviewer"
  run_hook "$sb" "Bash rm -f active-reviewer bundled with unrelated command -> NOT blocked (#1000)" \
    "$(bash_json "rm -f ${ar} && gh pr checks 996")" 0
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (30) Bash → purely READ-ONLY command (git show | grep) whose quoted grep
#      PATTERN argument contains the substring "rm -f" — a segmentation
#      false-positive in the shared file-mover matcher (which can't see
#      quoting), not a real rm -> NOT blocked, exit 0 (#1000 point 1).
# ---------------------------------------------------------------------------
case30() {
  local sb; sb=$(make_sandbox)
  local cmd='git show upstream/dev:.claude/hooks/warn-review-marker-write.sh | grep -nE "approved|rm -f|active-reviewer"'
  run_hook "$sb" "Bash read-only grep pipeline with quoted 'rm -f' substring -> NOT blocked (#1000)" \
    "$(bash_json "$cmd")" 0
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (31) Bash → heredoc write to a non-marker scratch path whose BODY content
#      quotes "$marker" and "active-reviewer" in prose (a review body
#      explaining the gate, not code targeting one) -> NOT blocked, exit 0
#      (#1000 point 2 — judge the resolved target, not the payload).
# ---------------------------------------------------------------------------
case31() {
  local sb; sb=$(make_sandbox)
  local json
  # shellcheck disable=SC2016 # deliberate — the $marker text is literal
  # heredoc BODY payload, not a real expansion (that's the whole point of
  # this test case: prose content, not code).
  json='{"tool_name":"Bash","tool_input":{"command":"cat > /tmp/scratch/review-body.md <<'"'"'EOF'"'"'\nThe hook checks the $marker token before writing the file.\nAlso mentions active-reviewer in prose.\nEOF\necho done"}}'
  run_hook "$sb" "Bash heredoc write to scratch path, body mentions \$marker/active-reviewer -> NOT blocked (#1000)" \
    "$json" 0
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (32) Bash → the orchestrator's documented SET step (printf > literal
#      active-reviewer path, code-review/SKILL.md § 0) — previously ALSO a
#      false block, since role can never resolve for a plain printf ->
#      NOT blocked, exit 0 (#1000 point 3).
# ---------------------------------------------------------------------------
case32() {
  local sb; sb=$(make_sandbox)
  local ar="$sb/.claude/session/active-reviewer"
  local cmd="printf '%s\n' \"${REPO}#1000:rex\" > \"${ar}\""
  run_hook "$sb" "Bash SET step (printf > active-reviewer) -> NOT blocked (#1000)" \
    "$(bash_json "$cmd")" 0
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (33) Bash → `rm` bundled with a REAL literal marker forgery in the same
#      command (rm -f active-reviewer; printf sha > <real marker path>) ->
#      DETECTED -> warns, exit 0. Confirms the #1000 deletion-only exemption doesn't
#      swallow a genuine forgery riding alongside an rm.
# ---------------------------------------------------------------------------
case33() {
  local sb; sb=$(make_sandbox)
  local ar="$sb/.claude/session/active-reviewer"
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  # NOTE: this case pins DETECTION, not prevention. Pre-#1026 it asserted the
  # forgery was blocked; the hook is advisory now, so it asserts the forgery is
  # still SEEN (warns) rather than swallowed by #1000's deletion-only exemption.
  # The forgery itself is stopped at merge by block-unreviewed-merge.sh's
  # forge-HEAD SHA comparison — do not read this case as a merge guarantee.
  run_hook "$sb" "Bash rm + real marker forgery in same command -> still DETECTED, warns (#1000/#1026)" \
    "$(bash_json "rm -f ${ar}; printf sha123 > ${marker}")" 0 "WARNING"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (34) Bash → `rm` of a REAL *.approved marker file (not active-reviewer) ->
#      NOT blocked, exit 0. Deliberate, documented narrowing: deletion can
#      only remove evidence, it cannot forge approval content (#1000).
# ---------------------------------------------------------------------------
case34() {
  local sb; sb=$(make_sandbox)
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  : > "$marker"
  run_hook "$sb" "Bash rm of a real *.approved marker -> NOT blocked (#1000 narrowing)" \
    "$(bash_json "rm ${marker}")" 0
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (35) Bash → `python3 <<EOF` interpreter heredoc writing directly to a real
#      rex marker, no active-reviewer marker -> WARNS (advisory, #1026), exit 0.
#      #1000-round2 finding 1 (Rex's PR #1011 review): the FIRST version of
#      this fix stripped heredoc bodies before the fallback scan, reasoning
#      all heredoc content is data. For an INTERPRETER heredoc the body is
#      CODE naming the destination, and interpreter writes yield no
#      extractable target -- stripping removed the only evidence left,
#      silently ALLOWING marker creation from scratch. Fixed by not
#      stripping at all (see the hook's #1000-REX-ROUND-2 comment).
# ---------------------------------------------------------------------------
case35() {
  local sb; sb=$(make_sandbox)
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  local cmd
  cmd=$(printf 'python3 <<EOF\nopen("%s","w").write("sha123")\nEOF' "$marker")
  run_hook "$sb" "Bash python3 heredoc write to rex marker, no marker -> WARNS (advisory, #1026) (#1000-round2 F1)" \
    "$(bash_json_multiline "$cmd")" 0 "WARNING"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (36) Bash → `bash <<EOF` wrapping an inner `python3 -c` write to a real rex
#      marker -> WARNS (advisory, #1026), exit 0. `bash` fed a heredoc isn't itself one of
#      the shared lib's named interpreter matchers (only python/node/ruby
#      heredoc forms are) -- this shape is caught because target extraction
#      runs on the unstripped command and the inner write is still visible.
#      Guards against re-introducing any body-stripping in the future.
# ---------------------------------------------------------------------------
case36() {
  local sb; sb=$(make_sandbox)
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  local cmd
  cmd=$(printf 'bash <<EOF\npython3 -c '"'"'open("%s","w").write("sha123")'"'"'\nEOF' "$marker")
  run_hook "$sb" "Bash bash-heredoc wrapping python3 -c write to rex marker -> WARNS (advisory, #1026) (#1000-round2 F2)" \
    "$(bash_json_multiline "$cmd")" 0 "WARNING"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (37) Bash → the IDENTICAL python3 -c write INLINE (no heredoc) -> WARNS (advisory, #1026),
#      exit 0. Control for cases 35/36: same write, same target, no
#      heredoc -- confirms the interpreter-write detection itself was never
#      broken; only the (now-removed) heredoc-body strip regressed it.
# ---------------------------------------------------------------------------
case37() {
  local sb; sb=$(make_sandbox)
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  local cmd
  cmd=$(printf 'python3 -c '"'"'open("%s","w").write("sha123")'"'"'' "$marker")
  run_hook "$sb" "Bash inline python3 -c write to rex marker (heredoc control) -> WARNS (advisory, #1026)" \
    "$(bash_json "$cmd")" 0 "WARNING"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (38) Bash → BSD-form `sed -i '' s/aa/bb/ <marker>` rewriting a real rex
#      marker's stale SHA -> WARNS (advisory, #1026), exit 0.
#      #1000-round2 finding 2 (Rex's PR #1011 review): bash_extract_
#      write_target's positional heuristic for `sed -i` assumes GNU's
#      single-quoted-script form. BSD's two-token form (empty-string backup
#      suffix, unquoted script) makes it return the SED EXPRESSION as "the
#      target" -- literal, non-marker, non-variable, so the per-target loop
#      treated it as conclusive and skipped the REAL marker file, silently
#      ALLOWING a stale marker to be rewritten with a current SHA (defeating
#      "new commits invalidate approval"). Fixed via IS_EXTRACTION_FRAGILE.
# ---------------------------------------------------------------------------
case38() {
  local sb; sb=$(make_sandbox)
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" > "$marker"
  local cmd="sed -i '' s/aa/bb/ ${marker}"
  run_hook "$sb" "Bash BSD sed -i '' mis-extracted target on rex marker -> WARNS (advisory, #1026) (#1000-round2 finding2)" \
    "$(bash_json "$cmd")" 0 "WARNING"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (39) Bash → GNU-form `sed -i s/aa/bb/ <marker>` on a real rex marker ->
#      DETECTED -> warns, exit 0. Regression guard: GNU's single-token form returns
#      EMPTY targets from bash_extract_write_target and already reached the
#      general fallback before this fix -- confirms finding 2's fix doesn't
#      change (or depend on masking) the already-correct GNU behaviour.
# ---------------------------------------------------------------------------
case39() {
  local sb; sb=$(make_sandbox)
  local marker; marker=$(review_marker_path "$REPO" 42 rex "$sb")
  printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" > "$marker"
  local cmd="sed -i s/aa/bb/ ${marker}"
  run_hook "$sb" "Bash GNU sed -i on rex marker -> WARNS (advisory, #1026) (regression guard)" \
    "$(bash_json "$cmd")" 0 "WARNING"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (40) Bash → `sed -i ''` editing a NON-marker file -> NOT blocked, exit 0.
#      Negative control: IS_EXTRACTION_FRAGILE widens the fallback scan
#      for sed -i / awk -i inplace commands, but must not turn EVERY sed -i
#      invocation into a block -- only ones that actually touch a marker
#      path (literal or reviews/-dir-mentioning) do.
# ---------------------------------------------------------------------------
case40() {
  local sb; sb=$(make_sandbox)
  local cmd="sed -i '' s/foo/bar/ /tmp/scratch/notes.txt"
  run_hook "$sb" "Bash sed -i on non-marker file -> NOT blocked (negative control)" \
    "$(bash_json "$cmd")" 0
  rm -rf "$sb"
}

# ===========================================================================
# #1026 REGRESSIONS — real false positives observed in one session.
#
# These are not hypotheticals. Each of the five below hard-blocked a real
# command while this hook was a blocking gate, and every one of them reported
# `detected role: unresolved`. They are pinned here so the advisory behaviour
# cannot silently regress to blocking.
#
# The general shape: a command that MENTIONS a marker path is textually
# indistinguishable from one that WRITES it. That is the defect class
# AgDR-0104 named and AgDR-0109 acted on -- do not "fix" it with a pattern.
# ===========================================================================

# ---------------------------------------------------------------------------
# (41) Bash → read-only grep whose SEARCH PATTERN contains a marker redirect.
#      Blocked a repo sweep that was looking for this very bug. exit 0.
# ---------------------------------------------------------------------------
case41() {
  local sb; sb=$(make_sandbox)
  local cmd="grep -rn '> .claude/session/reviews/me2resh__apexyard__7777-rex.approved' .claude/hooks/"
  run_hook "$sb" "read-only grep, marker redirect inside the PATTERN -> NOT blocked (#1026)" \
    "$(bash_json "$cmd")" 0
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (42) Bash → `git commit -F -` whose COMMIT MESSAGE names a marker path.
#      Blocked the commit that fixed a hook for instructing a raw marker
#      write -- the message had to describe the thing being removed. exit 0.
# ---------------------------------------------------------------------------
case42() {
  local sb; sb=$(make_sandbox)
  local cmd
  cmd=$'git commit -F - <<EOF\nfix: stop instructing a redirect into .claude/session/reviews/me2resh__apexyard__7777-design.approved\nEOF'
  run_hook "$sb" "git commit whose MESSAGE names a marker path -> NOT blocked (#1026)" \
    "$(bash_json_multiline "$cmd")" 0
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (43) Bash → /approve-merge's documented flow: READ the rex marker to verify
#      it, then WRITE the ceo marker. First-call-wins role extraction reported
#      `rex` for a ceo write, routing an advisory write down the blocking
#      path (#1032). Roles now disagree -> role is reported as unresolved
#      rather than asserted wrongly. exit 0.
# ---------------------------------------------------------------------------
case43() {
  local sb; sb=$(make_sandbox)
  # shellcheck disable=SC2016 # deliberate — these are literal, unexpanded
  # $VAR tokens in the command text the hook receives, not expansions here.
  local cmd='REX=$(review_marker_path "$HOST" 1041 rex "$MH"); CEO=$(review_marker_path "$HOST" 1041 ceo "$MH"); printf "sha=abc" > "$CEO"'
  # Assert the exact banner field, not the bare word "unresolved" — a loose
  # match would still pass if the role were mis-reported while some OTHER
  # field happened to read "unresolved".
  run_hook "$sb" "rex READ + ceo WRITE -> NOT blocked, role not mis-reported as rex (#1032)" \
    "$(bash_json "$cmd")" 0 "detected role: unresolved"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (44) Bash → a command whose only marker-ish token is a variable NAMED
#      MARKER_HOME -- the name this framework's own skills and agent specs
#      tell you to use -- plus a redirect to an unresolvable variable target.
#      This blocked /approve-merge's own documented step 7. exit 0.
# ---------------------------------------------------------------------------
case44() {
  local sb; sb=$(make_sandbox)
  # shellcheck disable=SC2016 # literal command text, see case43.
  local cmd='MARKER_HOME=/repo; . "$MARKER_HOME/.claude/hooks/_lib-tracker.sh"; tracker_pr_merge "o/r" "1041" "squash" true > "$OUT"'
  run_hook "$sb" "MARKER_HOME declaration + variable redirect -> NOT blocked (#1026)" \
    "$(bash_json "$cmd")" 0
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# (45) Bash → a marker path inside a JSON STRING being piped to another
#      program. Three quoting layers deep and not a write at all; the role
#      extractor returned the literal garbage `…__7777-rex.approved"}}` and
#      the gate blocked on it -- it blocked this hook's own test harness.
#      exit 0.
# ---------------------------------------------------------------------------
case45() {
  local sb; sb=$(make_sandbox)
  local cmd='printf %s "{\"command\":\"printf x > .claude/session/reviews/me2resh__apexyard__7777-rex.approved\"}" | ./some-consumer'
  run_hook "$sb" "marker path inside a JSON payload piped to another program -> NOT blocked (#1026)" \
    "$(bash_json "$cmd")" 0
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
case20
case21
case22
case23
case24
case25
case26
case27
case28
case29
case30
case31
case32
case33
case34
case35
case36
case37
case38
case39
case40
case41
case42
case43
case44
case45

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
