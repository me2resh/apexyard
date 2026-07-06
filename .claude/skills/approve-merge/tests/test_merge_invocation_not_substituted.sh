#!/bin/bash
# test_merge_invocation_not_substituted.sh — pins the shape of the
# tracker_pr_merge invocation in /approve-merge's SKILL.md (#759 follow-up).
#
# WHY THIS EXISTS
# ---------------
# The merge-gate hooks fire on a `Bash(tracker_pr_merge *)` matcher added to
# .claude/settings.json (#759) — Claude Code's PreToolUse permission-rule
# engine matches that pattern against the raw Bash command text. Whether that
# engine recognises the pattern when the invocation is wrapped in a command
# substitution (`X=$(tracker_pr_merge ...)`) is UNVERIFIED — a substitution
# runs its content in a subshell, a materially different construct from a
# bare sequential statement, and there is no prior art of a
# `Bash(<function> *)` gate matcher firing from inside `$(...)` to lean on.
# Rex + Hakim's review of PR #794 flagged this as a load-bearing gap that
# unit tests of the shell functions can't cover (is_merge_command matching
# the STRING "tracker_pr_merge ..." proves nothing about whether Claude
# Code's own matcher fires on a live invocation shaped one way vs another).
#
# The fix: SKILL.md step 7 now invokes `tracker_pr_merge` as its own bare,
# top-level statement (redirected to a temp file), and reads the result back
# in a SEPARATE step via `cat` (not itself a merge command, so `$(...)`
# wrapping it is fine). This test is the regression guard — a future edit to
# SKILL.md that reintroduces `$(tracker_pr_merge ...)` should fail this test
# BEFORE it ships, not get discovered by an unverifiable harness-matcher
# assumption after the fact.
#
# THIS IS A STATIC-SHAPE TEST — it lints the markdown's code-block text; it
# does not (and cannot, from a test harness) prove what Claude Code's real
# PreToolUse matcher does at runtime. Manual verification note: if you want
# to confirm empirically, run `/approve-merge <pr>` on a real PR with no
# review markers present and watch whether block-unreviewed-merge.sh's
# BLOCKED message actually appears — if the merge silently proceeds despite
# missing markers, the matcher did not fire and this fix regressed.
#
# Cases:
#   1. SKILL.md exists and has at least one fenced bash code block
#   2. NO bash code-block line invokes tracker_pr_merge inside `$(...)`
#   3. NO bash code-block line invokes tracker_pr_merge inside backticks
#   4. At least one bash code-block line is a BARE top-level invocation of
#      tracker_pr_merge (not preceded by `=`, `$(`, or a backtick on the
#      same statement)
#   5. That bare invocation redirects its output (`>`) rather than being
#      left unconsumed — proving the "read the file back separately" shape
#      is actually wired, not just the top-level call in isolation
#   6. The prose explicitly documents the "never wrap in $(...)" rule, so a
#      human editing this file by hand still sees the warning inline
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SKILL_MD="$SRC_ROOT/.claude/skills/approve-merge/SKILL.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# --- Case 1: file exists ---------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
  echo "FAIL: SKILL.md not found at $SKILL_MD" >&2
  exit 1
fi
pass "SKILL.md exists at $SKILL_MD"

# Extract the text of every fenced ```bash ... ``` block (concatenated).
BASH_BLOCKS=$(awk '
  /^```bash[[:space:]]*$/ { inblock=1; next }
  /^```[[:space:]]*$/     { if (inblock) { inblock=0 }; next }
  inblock                 { print }
' "$SKILL_MD")

if [ -z "$BASH_BLOCKS" ]; then
  fail "at least one fenced bash code block extracted from SKILL.md"
else
  pass "at least one fenced bash code block extracted from SKILL.md"
fi

# Cases 2-5 check EXECUTABLE shape, not prose — strip full-line `#` comments
# first (the code block deliberately contains a comment ILLUSTRATING the
# forbidden `X=$(tracker_pr_merge ...)` shape as a negative example; that
# comment must not itself trip the "no $(...) wrapping" check).
CODE_LINES=$(echo "$BASH_BLOCKS" | grep -vE '^[[:space:]]*#')

# --- Case 2: no `$(tracker_pr_merge ...)` command-substitution form -------
# Matches `$(tracker_pr_merge` with any amount of whitespace after `$(`, and
# the assignment form `VAR=$(tracker_pr_merge`.
if echo "$CODE_LINES" | grep -qE '\$\([[:space:]]*tracker_pr_merge\b'; then
  fail "no bash code-block line wraps tracker_pr_merge in \$(...) (found one)"
  echo "$CODE_LINES" | grep -nE '\$\([[:space:]]*tracker_pr_merge\b' >&2
else
  pass "no bash code-block line wraps tracker_pr_merge in \$(...)"
fi

# --- Case 3: no backtick command-substitution form -------------------------
if echo "$CODE_LINES" | grep -qE '`[[:space:]]*tracker_pr_merge\b'; then
  fail "no bash code-block line wraps tracker_pr_merge in backticks (found one)"
  echo "$CODE_LINES" | grep -nE '\`[[:space:]]*tracker_pr_merge\b' >&2
else
  pass "no bash code-block line wraps tracker_pr_merge in backticks"
fi

# --- Case 4: a bare top-level invocation exists ----------------------------
# A line whose first non-whitespace token is literally `tracker_pr_merge`
# (not preceded by `VAR=`, `$(`, or a backtick anywhere earlier on the line —
# those are covered by cases 2/3, this asserts the POSITIVE: the call must
# still exist somewhere, unindented-in-spirit (leading whitespace from
# markdown code-fence indentation is fine; leading SHELL syntax before the
# command name is not).
TOPLEVEL_LINE=$(echo "$CODE_LINES" | grep -E '^[[:space:]]*tracker_pr_merge\b' | head -1)
if [ -z "$TOPLEVEL_LINE" ]; then
  fail "a bare top-level tracker_pr_merge invocation exists in SKILL.md"
else
  pass "a bare top-level tracker_pr_merge invocation exists in SKILL.md"
fi

# --- Case 5: that invocation redirects its output --------------------------
if echo "$TOPLEVEL_LINE" | grep -qE '>[[:space:]]*"?\$[A-Za-z_]'; then
  pass "the top-level tracker_pr_merge invocation redirects output to a file"
else
  fail "the top-level tracker_pr_merge invocation redirects output to a file"
  echo "  got: $TOPLEVEL_LINE" >&2
fi

# --- Case 6: the prose documents the never-wrap-in-\$(...) rule -----------
if grep -qE 'NEVER be invoked.*\$\(|MUST be invoked.*top-level|never wrap.*\$\(' "$SKILL_MD"; then
  pass "SKILL.md prose documents the never-wrap-in-\$(...) rule inline"
else
  fail "SKILL.md prose documents the never-wrap-in-\$(...) rule inline"
fi

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
