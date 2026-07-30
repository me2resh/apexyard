#!/bin/bash
# Security-review regression test for me2resh/apexyard#1075 (a follow-up
# correction to the #1066 fix).
#
# The first version of the #1066 fix routed the PRESENCE checks in
# validate-branch-name.sh and block-main-push.sh (`grep -qE 'git push'` /
# `'git commit'`) through heredoc-stripped text. A security review found
# eight distinct malformed-heredoc shapes that made the (then single-pass,
# un-anchored) stripper eat the real command, so the presence check never
# fired and the gate silently allowed a real push to a protected branch —
# verified by stubbing `git` on PATH and confirming the push genuinely runs
# for seven of the eight (the eighth, an unterminated heredoc, never
# executes in real bash either, but the GATE still incorrectly returned 0).
#
# The fix has two parts:
#   1. `_lib-strip-heredoc.sh`'s stripper only strips a heredoc that is BOTH
#      anchored (nothing but whitespace/comment/redirect follows the
#      delimiter word on its own line) AND confirmed-terminated (a later
#      line actually equals the delimiter). Every shape below fails at
#      least one of those checks, so the (fixed) stripper declines to
#      touch it and leaves the text completely unchanged.
#   2. Independent of (1): the presence checks in both hooks now run
#      against the RAW, unfiltered command — never against stripped text.
#      This is the actual bypass fix; (1) just means the "which ref"
#      refinement stays accurate too.
#
# Each shape is tested against BOTH hooks with the reviewer's exact
# payloads (originally `pay_*.json`), pushing to `main`:
#   - block-main-push.sh (protected-branch gate)  -> must BLOCK (rc=2)
#   - validate-branch-name.sh (naming gate)       -> `main` is an exempt
#     trunk name, so the correctly-extracted destination passes (rc=0);
#     what matters here is that it does NOT extract a bogus ref from the
#     prose (which a separate assertion, the BAD case, checks by pushing
#     to a non-conforming name instead of a protected one).
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BLOCK_HOOK="$SRC_ROOT/.claude/hooks/block-main-push.sh"
BRANCH_HOOK="$SRC_ROOT/.claude/hooks/validate-branch-name.sh"
LIB_SRC="$SRC_ROOT/.claude/hooks/_lib-extract-push-ref.sh"
LIB_STRIP_HEREDOC_SRC="$SRC_ROOT/.claude/hooks/_lib-strip-heredoc.sh"
LIB_CONFIG_SRC="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
LIB_OPS_ROOT_SRC="$SRC_ROOT/.claude/hooks/_lib-ops-root.sh"
LIB_PR_REPO_SRC="$SRC_ROOT/.claude/hooks/_lib-pr-repo.sh"

for f in "$BLOCK_HOOK" "$BRANCH_HOOK" "$LIB_SRC" "$LIB_STRIP_HEREDOC_SRC"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required source missing: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

make_sandbox() {
  local branch="${1:-main}"
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    : > onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
    git checkout -q -B "$branch"
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$BLOCK_HOOK" "$sb/.claude/hooks/block-main-push.sh"
  cp "$BRANCH_HOOK" "$sb/.claude/hooks/validate-branch-name.sh"
  cp "$LIB_SRC" "$sb/.claude/hooks/_lib-extract-push-ref.sh"
  cp "$LIB_STRIP_HEREDOC_SRC" "$sb/.claude/hooks/_lib-strip-heredoc.sh"
  if [ -f "$LIB_CONFIG_SRC" ]; then
    cp "$LIB_CONFIG_SRC" "$sb/.claude/hooks/_lib-read-config.sh"
  fi
  if [ -f "$LIB_OPS_ROOT_SRC" ]; then
    cp "$LIB_OPS_ROOT_SRC" "$sb/.claude/hooks/_lib-ops-root.sh"
  fi
  if [ -f "$LIB_PR_REPO_SRC" ]; then
    cp "$LIB_PR_REPO_SRC" "$sb/.claude/hooks/_lib-pr-repo.sh"
  fi
  if [ -f "$SRC_ROOT/.claude/project-config.defaults.json" ]; then
    cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  fi
  chmod +x "$sb/.claude/hooks/block-main-push.sh" "$sb/.claude/hooks/validate-branch-name.sh"
  echo "$sb"
}

run_cmd() {
  local label="$1" hook="$2" branch="$3" cmd="$4" want_rc="$5"
  local sb input got_rc got_stderr
  sb=$(make_sandbox "$branch")
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  got_stderr=$(cd "$sb" && echo "$input" | bash ".claude/hooks/$hook" 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"
  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label/$hook]: want rc=$want_rc, got $got_rc" >&2
    echo "    stderr: ${got_stderr:0:200}" >&2
    FAIL=$((FAIL + 1))
    FAILED_CASES="${FAILED_CASES}${label}/${hook} "
    return
  fi
  echo "PASS [$label/$hook]"
  PASS=$((PASS + 1))
}

# ---------------------------------------------------------------------------
# Control: a plain, honest push to main. Every hook must handle this
# correctly before any of the adversarial shapes are meaningful.
# ---------------------------------------------------------------------------
run_cmd "HONEST control" "block-main-push.sh" "main" "git push origin main" 2
run_cmd "HONEST control (main is exempt trunk)" "validate-branch-name.sh" "main" "git push origin main" 0

# ---------------------------------------------------------------------------
# The eight bypass shapes. All push to `main` (protected). Real destination
# is always `main` — none of these should ever extract anything else.
# ---------------------------------------------------------------------------

SHAPE_A=$(cat <<'CMD'
cat <<EOF
prose
git push origin main
CMD
)
run_cmd "A: unterminated heredoc" "block-main-push.sh" "main" "$SHAPE_A" 2
run_cmd "A: unterminated heredoc" "validate-branch-name.sh" "main" "$SHAPE_A" 0

SHAPE_B=$(cat <<'CMD'
cat <<E\OF
hello
EOF
git push origin main
CMD
)
run_cmd "B: backslash-escaped delimiter" "block-main-push.sh" "main" "$SHAPE_B" 2
run_cmd "B: backslash-escaped delimiter" "validate-branch-name.sh" "main" "$SHAPE_B" 0

SHAPE_C=$(cat <<'CMD'
cat <<'E O F'
hello
E O F
git push origin main
CMD
)
run_cmd "C: multi-word quoted delimiter" "block-main-push.sh" "main" "$SHAPE_C" 2
run_cmd "C: multi-word quoted delimiter" "validate-branch-name.sh" "main" "$SHAPE_C" 0

SHAPE_D=$(cat <<'CMD'
cat <<END.OF
prose
END.OF
git push origin main
CMD
)
run_cmd "D: dotted delimiter" "block-main-push.sh" "main" "$SHAPE_D" 2
run_cmd "D: dotted delimiter" "validate-branch-name.sh" "main" "$SHAPE_D" 0

SHAPE_E='echo "docs say use cat <<EOF here" && git push origin main'
run_cmd "E: <<EOF inside a quoted string, no real heredoc" "block-main-push.sh" "main" "$SHAPE_E" 2
run_cmd "E: <<EOF inside a quoted string, no real heredoc" "validate-branch-name.sh" "main" "$SHAPE_E" 0

SHAPE_F=$(cat <<'CMD'
git commit -m "fix <<EOF parsing"
git push origin main
CMD
)
run_cmd "F: commit message merely mentions <<EOF" "block-main-push.sh" "main" "$SHAPE_F" 2
run_cmd "F: commit message merely mentions <<EOF" "validate-branch-name.sh" "main" "$SHAPE_F" 0

SHAPE_G=$(cat <<'CMD'
cat <<A <<B
A
echo <<X
B
git push origin main
CMD
)
run_cmd "G: two heredocs on one line" "block-main-push.sh" "main" "$SHAPE_G" 2
run_cmd "G: two heredocs on one line" "validate-branch-name.sh" "main" "$SHAPE_G" 0

SHAPE_H=$(cat <<'CMD'
git commit -m "use a << b shift"
git push origin main
CMD
)
run_cmd "H: C++ operator-<< in a quoted message" "block-main-push.sh" "main" "$SHAPE_H" 2
run_cmd "H: C++ operator-<< in a quoted message" "validate-branch-name.sh" "main" "$SHAPE_H" 0

# ---------------------------------------------------------------------------
# Sanity check: heredoc-mention + a REAL push to a non-conforming (but
# unprotected) branch. block-main-push.sh correctly allows it (not
# protected); validate-branch-name.sh correctly blocks it (bad name) —
# proving the extraction found "badbranchname", not something from the
# prose, and each hook applies its own, correct semantics to that value.
# ---------------------------------------------------------------------------
SHAPE_BAD='echo "see cat <<EOF" && git push origin badbranchname'
run_cmd "BAD sanity: dest=badbranchname, not protected -> allowed" "block-main-push.sh" "main" "$SHAPE_BAD" 0
run_cmd "BAD sanity: dest=badbranchname, non-conforming -> blocks" "validate-branch-name.sh" "main" "$SHAPE_BAD" 2

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
