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
#   7. Release metadata creation and the merge invocation occupy the same
#      fenced bash block, so a harness cannot lose the values at a code-block
#      boundary (#1196)
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

# --- Case 7: release metadata and merge call share one code block ----------
# A fenced block can execute in a separate shell. The body-file variable is
# therefore only safe when its creation and tracker_pr_merge use are in the
# same block. Extract the block containing the merge invocation and require
# both release assignments in it.
MERGE_BLOCK=$(awk '
  /^```bash[[:space:]]*$/ { inblock=1; block=""; next }
  /^```[[:space:]]*$/ {
    if (inblock && block ~ /tracker_pr_merge/) print block
    inblock=0
    next
  }
  inblock { block=block $0 "\n" }
' "$SKILL_MD")

if printf '%s' "$MERGE_BLOCK" | grep -qF 'RELEASE_SUBJECT=""' \
  && printf '%s' "$MERGE_BLOCK" | grep -qF "RELEASE_BODY_FILE=\$(mktemp)" \
  && printf '%s' "$MERGE_BLOCK" | grep -qE '^[[:space:]]*tracker_pr_merge\b'; then
  pass "release metadata and tracker_pr_merge share one fenced bash block"
else
  fail "release metadata and tracker_pr_merge share one fenced bash block"
fi

# --- Case 8: /update sync shapes select the ancestry-preserving strategy ----
# Sync-class detection lives in scripts/approve-merge.sh (steps 3a, 4, 6).
SCRIPT="$SRC_ROOT/.claude/skills/approve-merge/scripts/approve-merge.sh"
if [ -f "$SCRIPT" ] \
  && grep -qF 'sync/main-to-dev-after-' "$SCRIPT" \
  && grep -qF 'sync\(' "$SCRIPT" \
  && grep -qF 'sync-upstream-(apexyard|dev)' "$SCRIPT" \
  && grep -qF 'sync ops fork with upstream' "$SCRIPT" \
  && grep -qF 'STRATEGY=merge' "$SCRIPT"; then
  pass "/release-sync and /update sync branch and title shapes are classified as sync PRs"
else
  fail "/release-sync and /update sync branch and title shapes are classified as sync PRs"
fi

# --- Case 9: step 6 re-derives strategy and release class and stops ---------
# Run the real step 6 block in a fresh shell, with MERGE_STRATEGY and
# RELEASE_CLASS unset. A stub script prints a chosen result. The merge
# adapter is a stub that writes a sentinel file when it runs (#1196).
T9=$(mktemp -d)
mkdir -p "$T9/home/.claude/skills/approve-merge/scripts" "$T9/home/.claude/hooks"
printf '%s\n' 'tracker_pr_merge() { : > "$SENTINEL"; printf "{\"sha\":\"abc\"}"; }' > "$T9/home/.claude/hooks/_lib-tracker.sh"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$STUB_JSON"' > "$T9/home/.claude/skills/approve-merge/scripts/approve-merge.sh"
printf '%s' "$MERGE_BLOCK" | sed -e "s|<marker_home>|$T9/home|g" -e 's|<repo>|owner/repo|g' -e 's|<pr>|42|g' > "$T9/block.sh"
run9() { rm -f "$T9/sentinel"; env -u MERGE_STRATEGY -u RELEASE_CLASS SENTINEL="$T9/sentinel" STUB_JSON="$1" bash "$T9/block.sh" >/dev/null 2>&1; }
OK9='{"marker_home":"x","pr_host_repo":"owner/repo","strategy":"squash","head_sha":"abc","release_class":false}'
if run9 '{}' || [ -e "$T9/sentinel" ]; then fail "step 6 stops when strategy and release_class are missing"; else pass "step 6 stops when strategy and release_class are missing"; fi
if run9 '{"pr_host_repo":"owner/repo","strategy":"fast-forward","release_class":false}' || [ -e "$T9/sentinel" ]; then fail "step 6 stops on an invalid strategy"; else pass "step 6 stops on an invalid strategy"; fi
if run9 '{"pr_host_repo":"owner/repo","strategy":"squash"}' || [ -e "$T9/sentinel" ]; then fail "step 6 stops on a missing release_class"; else pass "step 6 stops on a missing release_class"; fi
if run9 "$OK9" && [ -e "$T9/sentinel" ]; then pass "step 6 merges when the script result is valid"; else fail "step 6 merges when the script result is valid"; fi
rm -rf "$T9"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
