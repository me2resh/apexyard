#!/bin/bash
# Regression test — validate-pr-create.sh's gate over-matched "gh pr create"
# as an unanchored substring anywhere in the command (apexyard bug report,
# 2026-07).
#
# THE BUG
# -------
# The gate that decides "should this hook validate at all" stripped only the
# --body / --body-file / -F payload before testing for the command verb:
#
#     if ! printf '%s' "$_cmd_for_gate" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+create\b'; then
#       exit 0
#     fi
#
# That grep has NO position anchor — it matches "gh pr create" ANYWHERE in
# what's left, including inside a --title value that was never stripped. A
# `gh issue create --title '... gh pr create over-matches gh issue create ...'`
# — e.g. exactly the kind of bug-report title you'd write about THIS hook —
# got the full PR-only validation (title-format regex, missing ## Testing /
# ## Glossary, branch-ticket-ID check) even though the invoked command was
# `gh issue create`, not `gh pr create`. Reproduced live against the
# installed hook before this fix.
#
# THE FIX
# -------
# The gate now strips one optional leading `cd <path> &&` / `cd <path>;`
# prefix and then anchors the match to the command HEAD
# (`^[[:space:]]*gh[[:space:]]+pr[[:space:]]+create\b`) — "gh pr create" must
# be the actual verb being invoked, not merely present as a substring
# anywhere in a flag's value.
#
# Exit 0 if all cases pass; exit 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/validate-pr-create.sh"
LIB_CFG="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
LIB_TRACKER="$SRC_ROOT/.claude/hooks/_lib-tracker.sh"
LIB_PR_REPO="$SRC_ROOT/.claude/hooks/_lib-pr-repo.sh"
DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"

# shellcheck source=_lib-mock-gh.sh
source "$(cd "$(dirname "$0")" && pwd)/_lib-mock-gh.sh"

if [ ! -x "$HOOK_SRC" ]; then
  echo "FAIL: hook not found or not executable at $HOOK_SRC" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

# make_sandbox [branch]
#   Default branch carries a ticket ID so cases that aren't testing the
#   branch check don't trip over it.
make_sandbox() {
  local branch="${1:-fix/GH-900-test}"
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    git remote add origin "git@github.com:me2resh/apexyard.git"
    : > onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
    git checkout -q -B "$branch"
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOK_SRC" "$sb/.claude/hooks/validate-pr-create.sh"
  chmod +x "$sb/.claude/hooks/validate-pr-create.sh"
  [ -f "$LIB_CFG" ]     && cp "$LIB_CFG"     "$sb/.claude/hooks/_lib-read-config.sh"
  [ -f "$LIB_TRACKER" ] && cp "$LIB_TRACKER" "$sb/.claude/hooks/_lib-tracker.sh"
  [ -f "$LIB_PR_REPO" ] && cp "$LIB_PR_REPO" "$sb/.claude/hooks/_lib-pr-repo.sh"
  [ -f "$DEFAULTS" ]    && cp "$DEFAULTS"    "$sb/.claude/project-config.defaults.json"
  echo "$sb"
}

# run_case label command want_rc [want_stderr_regex]
run_case() {
  local label="$1" cmd="$2" want_rc="$3" want_stderr_regex="${4:-}"
  local sb; sb=$(make_sandbox)
  mock_gh_install "$sb"

  local input
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  local got_stderr got_rc
  got_stderr=$(cd "$sb" && printf '%s' "$input" | bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:400})" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  if [ -n "$want_stderr_regex" ] && ! printf '%s' "$got_stderr" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# ---------------------------------------------------------------------------
# The reported bug: a real-world "issue create" whose TITLE discusses this
# very hook, and therefore contains the literal words "gh pr create".
# ---------------------------------------------------------------------------

run_case 'issue create whose --title mentions the literal phrase does NOT trigger PR validation (exit 0)' \
  "gh issue create --repo me2resh/apexyard --title 'fix validate-pr-create.sh: gh pr create over-matches gh issue create' --body 'the substring used to false-block this exact ticket'" \
  0 ""

# A second phrasing (word order varies) to make sure the anchor — not a
# lucky specific string — is what fixed it.
run_case 'issue create whose --title says "over-matches gh pr create" does NOT trigger PR validation (exit 0)' \
  "gh issue create --repo me2resh/apexyard --title '[Bug] validator over-matches gh pr create pattern' --body 'desc'" \
  0 ""

# --title embedding the phrase via --body-file content (not just inline
# --body) — the gate must not be fooled by title OR body-file content.
BF=$(mktemp /tmp/test-gate-anchor-body.XXXXXX.md)
printf 'Example: gh pr create --title "x" --body "y"\n' > "$BF"
run_case 'issue create with --title mentioning it AND --body-file containing it → no-op (exit 0)' \
  "gh issue create --repo me2resh/apexyard --title 'fix: gh pr create gate bug' --body-file $BF" \
  0 ""
rm -f "$BF"

# ---------------------------------------------------------------------------
# True positives must still fire — the anchor must not be so tight it misses
# real invocations.
# ---------------------------------------------------------------------------

BODY_OK="## Summary
test

## Testing
1. unit tests pass

## Glossary
| Term | Definition |
|------|------------|
| GH-900 | gate anchor fix |"
BF_OK=$(mktemp /tmp/test-gate-anchor-ok.XXXXXX.md)
printf '%s' "$BODY_OK" > "$BF_OK"

run_case 'a genuine gh pr create still validates and PASSES with a conforming title/body/branch' \
  "gh pr create --repo me2resh/apexyard --title 'fix(#900): gate anchor' --head fix/GH-900-test --body-file $BF_OK" \
  0 ""

run_case 'a genuine gh pr create with a malformed title still BLOCKS' \
  "gh pr create --repo me2resh/apexyard --title 'no ticket id here' --head fix/GH-900-test --body-file $BF_OK" \
  2 "doesn't match format"

run_case 'a leading cd prefix before a genuine gh pr create still validates' \
  "cd /tmp && gh pr create --repo me2resh/apexyard --title 'fix(#900): gate anchor' --head fix/GH-900-test --body-file $BF_OK" \
  0 ""

# ---------------------------------------------------------------------------
# Hakim's security review of the anchor fix (PR #792) flagged a MEDIUM
# completeness regression: the single-leading-`cd`-strip anchor missed
# genuine `gh pr create` invocations behind OTHER prefix shapes that the old
# (unanchored) gate used to catch. Each of Hakim's four named shapes gets a
# true-positive case (still validates) below, plus one true-negative (still
# BLOCKS a malformed title through the same prefix) so the fix isn't merely
# "widen the no-op path".
# ---------------------------------------------------------------------------

run_case 'a leading env-var assignment before a genuine gh pr create still validates' \
  "FOO=bar gh pr create --repo me2resh/apexyard --title 'fix(#900): gate anchor' --head fix/GH-900-test --body-file $BF_OK" \
  0 ""

run_case 'a leading env-var assignment with a malformed title still BLOCKS' \
  "FOO=bar gh pr create --repo me2resh/apexyard --title 'no ticket id here' --head fix/GH-900-test --body-file $BF_OK" \
  2 "doesn't match format"

run_case 'a leading "time" wrapper before a genuine gh pr create still validates' \
  "time gh pr create --repo me2resh/apexyard --title 'fix(#900): gate anchor' --head fix/GH-900-test --body-file $BF_OK" \
  0 ""

run_case 'a leading "time" wrapper with a malformed title still BLOCKS' \
  "time gh pr create --repo me2resh/apexyard --title 'no ticket id here' --head fix/GH-900-test --body-file $BF_OK" \
  2 "doesn't match format"

run_case 'a double leading cd (cd a && cd b && …) before a genuine gh pr create still validates' \
  "cd /tmp && cd /tmp && gh pr create --repo me2resh/apexyard --title 'fix(#900): gate anchor' --head fix/GH-900-test --body-file $BF_OK" \
  0 ""

run_case 'a double leading cd with a malformed title still BLOCKS' \
  "cd /tmp && cd /tmp && gh pr create --repo me2resh/apexyard --title 'no ticket id here' --head fix/GH-900-test --body-file $BF_OK" \
  2 "doesn't match format"

run_case 'a generic non-cd prefix (X && gh pr create) still validates' \
  "echo hi && gh pr create --repo me2resh/apexyard --title 'fix(#900): gate anchor' --head fix/GH-900-test --body-file $BF_OK" \
  0 ""

run_case 'a generic non-cd prefix (X && gh pr create) with a malformed title still BLOCKS' \
  "echo hi && gh pr create --repo me2resh/apexyard --title 'no ticket id here' --head fix/GH-900-test --body-file $BF_OK" \
  2 "doesn't match format"

# The gate widening must not defeat the anchor itself — a --title value that
# contains a literal "&&" stays inside its quotes and must NOT be misread as
# a chained prefix ahead of a fabricated "gh pr create" segment.
run_case 'a --title value containing a literal && does NOT get misread as a chained prefix (exit 0, no-op)' \
  "gh issue create --repo me2resh/apexyard --title 'build && deploy pipeline' --body 'desc'" \
  0 ""

# ---------------------------------------------------------------------------
# Hakim's SECOND security re-review of PR #792 found a new BLOCKING
# regression: the round-1 loop applied shape 4 (a generic quote-free-segment
# strip) unconditionally every iteration, so a genuine `gh pr create` with
# quote-free trailing args followed by a top-level `&&` / `;` / `|`
# separator got its OWN verb consumed as if it were a "chained prefix" —
# the gate then silently skipped validation (exit 0) on a real invocation.
# The fix (check-then-strip: verify the head before stripping, every
# iteration) must make each of these fire and block a malformed title,
# exactly like the true-positive/true-negative pairs above.
#
# NOTE 1: these cases deliberately use UNQUOTED --title values (or omit
# --title entirely). Shape 4's whole point is stripping a QUOTE-FREE
# segment — a quoted title (as used in every case above) contains a `'`
# before any separator, which already keeps shape 4 from matching and would
# make these cases pass trivially under the OLD buggy code too, defeating
# the regression test. Hakim's literal reported bypass commands
# (`--fill --head br && echo done`, `--title fixbug --head br; echo x`,
# `--head br | cat`) are unquoted/title-free for exactly this reason —
# faithfully reproducing them (rather than "equivalent" quoted variants) is
# what makes these cases actually fail against the pre-fix code.
#
# NOTE 2: these cases also omit --body/--body-file. The gate-decision
# preprocessing (near the top of the hook) strips everything from
# --body-file/--body to end-of-string BEFORE the gate loop ever runs, which
# would silently remove the trailing " && echo done" / "; echo x" / "| cat"
# and — like quoting the title — would make the case pass regardless of
# whether the gate fix works. Omitting --body/--body-file also means the
# required-##-sections check no-ops (it only runs when the command carries
# a body flag), so title-format + branch-ticket-ID are what prove the gate
# fired for these cases specifically.
#
# Verified (see PR #792 discussion): each malformed-title case below FAILS
# (wrongly returns rc=0) against the pre-fix commit and PASSES (rc=2)
# against the check-then-strip fix.
# ---------------------------------------------------------------------------

run_case 'Hakim repro: gh pr create --fill --head br && echo done (no title) still validates' \
  "gh pr create --repo me2resh/apexyard --fill --head fix/GH-900-test && echo done" \
  0 ""

run_case 'same shape with an unquoted malformed title still BLOCKS (proves the gate fired)' \
  "gh pr create --repo me2resh/apexyard --fill --title fixbug --head fix/GH-900-test && echo done" \
  2 "doesn't match format"

run_case 'Hakim repro: gh pr create --title fixbug --head br; echo x — a well-formed unquoted title still validates' \
  "gh pr create --repo me2resh/apexyard --title fix(#900):x --head fix/GH-900-test; echo x" \
  0 ""

run_case 'same shape (;) with the literal malformed "fixbug" title still BLOCKS' \
  "gh pr create --repo me2resh/apexyard --title fixbug --head fix/GH-900-test; echo x" \
  2 "doesn't match format"

run_case 'Hakim repro: gh pr create --head br | cat (no title) still validates' \
  "gh pr create --repo me2resh/apexyard --head fix/GH-900-test | cat" \
  0 ""

run_case 'same shape (|) with an unquoted malformed title still BLOCKS' \
  "gh pr create --repo me2resh/apexyard --title fixbug --head fix/GH-900-test | cat" \
  2 "doesn't match format"

rm -f "$BF_OK"

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
