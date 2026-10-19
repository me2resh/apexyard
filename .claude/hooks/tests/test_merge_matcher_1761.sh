#!/bin/bash
# Merge-matcher regressions for #1761 (#1757, #1758, #1760).
#
# Step 1: a literal merge is not a variable target, under the system awk
# and under mawk when mawk is installed. The argv -c window stays 200
# characters. A variable merge and a shell -c wrapper still block.
# Step 2: the /approve-merge step 6 call passes literal repo and PR values.
# Step 3: a grep pattern and an inert heredoc are data. An inert heredoc
# is a quoted body, or an unquoted body with no $, backtick, or backslash.
# This file does not widen that rule. A real merge, a variable merge, and
# a shell -c or heredoc executor still block.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/.claude/hooks/_lib-extract-pr.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS [%s]\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL [%s]\n' "$1" >&2; }

expect_rc() {
  local label="$1" want="$2" got="$3"
  if [ "$got" -eq "$want" ]; then
    pass "$label"
  else
    fail "$label: want $want, got $got"
  fi
}

expect_opaque() {
  local label="$1" cmd="$2" want="$3" got=clear
  if _has_opaque_merge_wrapper "$cmd"; then got=opaque; fi
  if [ "$got" = "$want" ]; then
    pass "$label"
  else
    fail "$label: want $want, got $got"
  fi
}

check_window() {
  local prefix="$1"
  local pad near far
  # After the -c quote the bytes are comma, quote, pad, space, then the phrase.
  # Gap 200 is opaque. Gap 201 is clear. The space keeps a word boundary.
  pad=$(printf '%*s' 197 '' | tr ' ' 'x')
  near="['sh','-c','${pad} gh pr merge 5']"
  pad=$(printf '%*s' 198 '' | tr ' ' 'x')
  far="['sh','-c','${pad} gh pr merge 5']"
  merge_command_uses_variable 'gh pr merge 42 --repo owner/repo'
  expect_rc "$prefix literal merge is not a variable" 1 $?
  merge_command_uses_variable 'gh pr merge $PR --repo owner/repo'
  expect_rc "$prefix unexpanded PR still blocks" 0 $?
  merge_command_uses_variable 'gh pr merge 42 --repo $REPO'
  expect_rc "$prefix unexpanded repo still blocks" 0 $?
  merge_command_uses_variable "sh -c 'gh pr merge \$PR --repo owner/repo'"
  expect_rc "$prefix sh -c variable merge still blocks" 0 $?
  merge_command_uses_variable "bash -c 'gh pr merge 42 --repo \$REPO'"
  expect_rc "$prefix bash -c variable repo still blocks" 0 $?
  expect_opaque "$prefix argv -c within 200 is opaque" "$near" opaque
  expect_opaque "$prefix argv -c beyond 200 is not opaque" "$far" clear
  expect_opaque "$prefix tight argv -c is opaque" "['sh','-c','gh pr merge 5']" opaque
  expect_opaque "$prefix direct merge is not an opaque wrapper" 'gh pr merge 42 --repo owner/repo' clear
  expect_opaque "$prefix multiline argv -c is opaque" "$(printf "['sh','-c','\ngh pr merge 5']")" opaque
  expect_opaque "$prefix glab argv -c is opaque" "['bash','-c','glab mr merge 5']" opaque
}

check_skill_literals() {
  local skill line filled
  skill="$ROOT/.claude/skills/approve-merge/SKILL.md"
  line=$(grep -E '^[[:space:]]*tracker_pr_merge\b' "$skill" | head -1)
  if [ -z "$line" ]; then
    fail "approve-merge step 6 has a tracker_pr_merge line"
    return
  fi
  pass "approve-merge step 6 has a tracker_pr_merge line"
  case "$line" in
    *'$PR_HOST_REPO'*|*'$PR"'*)
      fail "step 6 merge call passes a repo or PR variable"
      ;;
    *)
      pass "step 6 merge call passes literal repo and PR placeholders"
      ;;
  esac
  filled=$(printf '%s\n' "$line" | sed -e 's|<repo>|owner/repo|g' -e 's|<pr>|42|g')
  merge_command_uses_variable "$filled"
  expect_rc "filled step 6 merge call is not a variable target" 1 $?
  if is_merge_command "$filled"; then
    pass "filled step 6 merge call is still a merge"
  else
    fail "filled step 6 merge call is still a merge"
  fi
  merge_command_uses_variable 'tracker_pr_merge "$PR_HOST_REPO" "$PR" squash true'
  expect_rc "unexpanded wrapper repo and PR still block" 0 $?
}

expect_merge() {
  local label="$1" cmd="$2" want="$3" got=no
  if is_merge_command "$cmd"; then got=yes; fi
  if [ "$got" = "$want" ]; then
    pass "$label"
  else
    fail "$label: want $want, got $got"
  fi
}

check_data_view() {
  local heredoc
  expect_merge "unquoted grep pattern is data" "grep -n tracker_pr_merge SKILL.md" no
  expect_merge "attached --regexp= pattern is data" "grep --regexp=tracker_pr_merge SKILL.md" no
  expect_merge "attached -e= pattern is data" "grep -e=tracker_pr_merge SKILL.md" no
  expect_merge "bare --regexp still blanks the next word" "grep --regexp tracker_pr_merge SKILL.md" no
  expect_merge "double-quoted grep pattern is data" \
    "grep -n \"tracker_pr_merge \\\"\$PR_HOST_REPO\\\"\" SKILL.md" no
  heredoc=$(printf "true; cat <<'EOF'\ntracker_pr_merge \"\$PR_HOST_REPO\"\nEOF")
  expect_merge "quoted heredoc beside true is data" "$heredoc" no
  expect_merge "grep then a real merge still blocks" \
    "grep -n tracker_pr_merge SKILL.md; gh pr merge 7 --repo owner/repo" yes
  expect_merge "true then a real merge still blocks" \
    "true; gh pr merge 7 --repo owner/repo" yes
  expect_merge "bash heredoc merge still blocks" \
    "$(printf "bash <<'EOF'\ngh pr merge 7 --repo owner/repo\nEOF")" yes
  expect_merge "heredoc piped to sh still blocks" \
    "$(printf "cat <<'EOF' | sh\ngh pr merge 7 --repo owner/repo\nEOF")" yes
  expect_merge "heredoc then sh still blocks" \
    "$(printf "cat > m.sh <<'EOF'\ngh pr merge 7\nEOF\nsh m.sh")" yes
  expect_merge "double-quoted substitution still blocks" 'echo "$(gh pr merge 7)"' yes
  expect_merge "grep --filter still blocks" "grep --filter=sh 'gh pr merge 7' notes.txt" yes
  expect_merge "attached --regexp= beside --filter still blocks" \
    "grep --filter=sh --regexp=tracker_pr_merge notes.txt" yes
  expect_merge "sh -c merge still blocks" "sh -c 'gh pr merge 7 --repo owner/repo'" yes
  expect_merge "bash -c merge still blocks" "bash -c 'gh pr merge 42 --repo owner/repo'" yes
  merge_command_uses_variable 'grep -n tracker_pr_merge SKILL.md; gh pr merge $PR --repo owner/repo'
  expect_rc "grep then unexpanded PR still blocks" 0 $?
  merge_command_uses_variable 'true; gh pr merge $PR --repo owner/repo'
  expect_rc "true then unexpanded PR still blocks" 0 $?
  merge_command_uses_variable "sh -c 'gh pr merge \$PR --repo owner/repo'"
  expect_rc "sh -c variable merge still blocks after data view" 0 $?
  merge_command_uses_variable "bash -c 'gh pr merge 42 --repo \$REPO'"
  expect_rc "bash -c variable repo still blocks after data view" 0 $?
  merge_command_uses_variable "grep -n \"tracker_pr_merge \\\"\$PR_HOST_REPO\\\"\" SKILL.md"
  expect_rc "double-quoted grep is not a variable target" 1 $?
}

# Hakim, review of PR #1765: the -c window must stay linear under the
# system awk. About 100 KB of argv -c units, with the merge phrase only
# inside the last 200-character window, must finish within 3 seconds.
check_c_window_time() {
  local unit n big pad phrase start end elapsed got
  unit="['sh','-c','x'] "
  phrase=$(printf '%s %s %s' gh pr merge)
  n=$((100000 / ${#unit}))
  big=$(awk -v u="$unit" -v n="$n" 'BEGIN { for (i = 0; i < n; i++) printf "%s", u }')
  pad=$(printf '%*s' 197 '' | tr ' ' 'x')
  big="${big}['sh','-c','${pad} ${phrase} 5']"
  start=$(python3 -c 'import time; print("%.6f" % time.time())')
  if _has_opaque_merge_wrapper "$big"; then got=opaque; else got=clear; fi
  end=$(python3 -c 'import time; print("%.6f" % time.time())')
  elapsed=$(python3 -c 'import sys; print("%.3f" % (float(sys.argv[2]) - float(sys.argv[1])))' "$start" "$end")
  if [ "$got" = opaque ]; then
    pass "100 KB argv -c window stays opaque (${#big} bytes)"
  else
    fail "100 KB argv -c window stays opaque (${#big} bytes, got $got)"
  fi
  if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= 3.0 else 1)' "$elapsed"; then
    pass "100 KB argv -c window took ${elapsed}s under system awk (limit 3s)"
  else
    fail "100 KB argv -c window took ${elapsed}s under system awk (limit 3s)"
  fi
}

check_data_view
check_skill_literals
check_window "bsd awk"
check_c_window_time
if command -v mawk >/dev/null 2>&1; then
  mawk_bin=$(mktemp -d)
  ln -s "$(command -v mawk)" "$mawk_bin/awk"
  PATH="$mawk_bin:$PATH" check_window "mawk"
  rm -rf "$mawk_bin"
else
  echo "SKIP: mawk is not installed"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
