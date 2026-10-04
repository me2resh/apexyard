#!/bin/bash
# Tests for extract_pr_number() in _lib-extract-pr.sh — regression suite for
# bug #568 (stderr redirect `2>&1` digit contamination when PR arg is a shell
# variable) plus happy-path and gh-api-shape coverage.
#
# Cases:
#   1. `gh pr merge 42 --squash`                              → 42
#   2. `gh pr merge 42 --squash 2>&1 | tail -5`              → 42 (NOT 2)
#   3. `gh pr merge $pr --squash 2>&1`                       → empty (unexpanded var)
#   4. `gh api repos/o/r/pulls/42/merge -X PUT`              → 42
#   5. `gh api .../pulls/7/merge 2>&1`                       → 7  (NOT 2)
#   6. `gh pr merge 123 --repo foo/bar --squash 2>&1 | tail` → 123 (NOT 2)
#   7. `gh pr merge ${PR_NUMBER} --squash`                   → empty (unexpanded braces)
#   8. `gh pr merge 42 2>err.log`                            → 42 (NOT 2)
#   9. `gh pr merge 42 &>out.log`                            → 42
#  10. `gh pr merge 42 >>out.log`                            → 42
#
# Note: cases where pr="" fall through to the `gh pr view` fallback inside the
# real library. In these tests we only source the library function and do NOT
# mock `gh`, so the fallback will also return empty (no real GitHub API call).
# That is intentional — we are testing the string-parsing layer only.
#
# Exit 0 if all cases pass; exit 1 on first failure.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/_test-session-isolation.sh"


LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-extract-pr.sh"
if [ ! -f "$LIB_SRC" ]; then
  echo "FAIL: lib not found at $LIB_SRC" >&2
  exit 1
fi

# Source the library. We need to shim `gh` so that the step-3 fallback
# (`gh pr view …`) returns empty rather than making a real network call.
# Drop a minimal shim on PATH before sourcing.
SHIM_DIR=$(mktemp -d)
cat > "$SHIM_DIR/gh" <<'GHEOF'
#!/bin/bash
# Controlled branch PR/repo fallback. Defaults to empty for parsing tests.
case "$*" in
  *"--json number"*)         printf '%s\n' "${MOCK_BRANCH_PR:-}" ;;
  *"--json headRepository"*) printf '%s\n' "${MOCK_BRANCH_REPO:-}" ;;
esac
exit 0
GHEOF
chmod +x "$SHIM_DIR/gh"
export PATH="$SHIM_DIR:$PATH"

# shellcheck source=/dev/null
. "$LIB_SRC"

PASS=0
FAIL=0
FAILED_CASES=""

assert_pr() {
  local label="$1" cmd="$2" want="$3"
  local got
  got=$(extract_pr_number "$cmd")
  if [ "$got" = "$want" ]; then
    echo "PASS [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label]: cmd=[$cmd]  want=[$want]  got=[$got]" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
  fi
}

# --- Happy path: literal PR number, no redirections ----------------------

assert_pr "plain merge 42" \
  "gh pr merge 42 --squash" \
  "42"

assert_pr "merge with --repo flag" \
  "gh pr merge 99 --repo me2resh/apexyard --squash" \
  "99"

# --- Bug #568: redirect tokens must not donate digits --------------------

# Core repro: 2>&1 before a pipe — the old code returned 2 here.
assert_pr "merge 42 with 2>&1 pipe (bug #568 repro)" \
  "gh pr merge 42 --squash 2>&1 | tail -5" \
  "42"

# Unexpanded shell variable + 2>&1: old code returned 2, correct is empty.
assert_pr "merge \$pr with 2>&1 → empty (var unexpanded)" \
  'gh pr merge $pr --squash 2>&1' \
  ""

# Curly-brace unexpanded variable.
assert_pr "merge \${PR_NUMBER} → empty (var unexpanded)" \
  'gh pr merge ${PR_NUMBER} --squash' \
  ""

# Append redirect (>>).
assert_pr "merge 42 with >> redirect" \
  "gh pr merge 42 >>out.log" \
  "42"

# Overwrite redirect (>).
assert_pr "merge 42 with > redirect" \
  "gh pr merge 42 >out.log" \
  "42"

# Combined Bash &> redirect.
assert_pr "merge 42 with &> redirect" \
  "gh pr merge 42 &>out.log" \
  "42"

# fd-specific write redirect.
assert_pr "merge 42 with 2>err.log" \
  "gh pr merge 42 2>err.log" \
  "42"

# All together: repo flag, redirect, pipe.
assert_pr "merge 123 with --repo + 2>&1 + pipe" \
  "gh pr merge 123 --repo foo/bar --squash 2>&1 | tail" \
  "123"

# --- gh api URL path shape -----------------------------------------------

assert_pr "gh api pulls/42/merge" \
  "gh api repos/o/r/pulls/42/merge -X PUT" \
  "42"

# gh api with 2>&1 — the 2 must NOT win; the URL path number must.
assert_pr "gh api pulls/7/merge with 2>&1" \
  "gh api repos/me2resh/apexyard/pulls/7/merge -X PUT 2>&1" \
  "7"

# --- Edge cases ----------------------------------------------------------

# No PR number at all → empty (triggers gh pr view fallback, returns empty in test).
assert_pr "merge with no number → empty" \
  "gh pr merge --squash" \
  ""

# Unrelated command → empty.
assert_pr "gh pr view is not a merge command" \
  "gh pr view 42" \
  ""

# --- #643: merge_command_uses_variable (variable-substituted merge detection) ---

assert_var() {
  local label="$1" cmd="$2" want="$3"   # want: "yes" (uses var) | "no"
  local got="no"
  merge_command_uses_variable "$cmd" && got="yes"
  if [ "$got" = "$want" ]; then
    echo "PASS [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label]: cmd=[$cmd]  want=[$want]  got=[$got]" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
  fi
}

# Variable PR arg → yes
assert_var "var PR \$PR"            'gh pr merge $PR --repo me2resh/apexyard --squash' "yes"
assert_var "var PR \${PR_NUMBER}"  'gh pr merge ${PR_NUMBER} --squash'                "yes"
# Variable --repo value → yes (even with a literal PR number)
assert_var "var repo \$REPO"       'gh pr merge 378 --repo $REPO --squash'            "yes"
assert_var "var repo \${REPO}"     'gh pr merge 378 --repo ${REPO} --squash'          "yes"
# Quoted variable forms → yes (the common shape agents/operators write)
assert_var "quoted var PR \"\$PR\""    'gh pr merge "$PR" --repo me2resh/apexyard'    "yes"
assert_var "quoted var repo \"\$REPO\"" 'gh pr merge 378 --repo "$REPO" --squash'      "yes"
# Both literal → no
assert_var "literal PR + repo"     'gh pr merge 378 --repo me2resh/apexyard --squash' "no"
assert_var "literal PR no repo"    'gh pr merge 42 --squash'                          "no"
# Redirections must not be mistaken for a variable PR arg
assert_var "literal + 2>&1 pipe"   'gh pr merge 42 --squash 2>&1 | tail -5'           "no"
# gh api shape (literal path) → no
assert_var "gh api literal path"   'gh api repos/o/r/pulls/42/merge -X PUT'           "no"

# #1525: the variable check must use the same bounded data view as detection.
data_heredoc=$(cat <<'CMD'
cat > /tmp/brief.md <<'EOF'
run: gh pr merge 315 --repo $TEST_REPO --squash
EOF
CMD
)
assert_var "quoted data heredoc variable" "$data_heredoc" "no"
assert_var "bash heredoc variable" $'bash <<\'EOF\'\ngh pr merge $PR --repo $R\nEOF' "yes"
assert_var "sh heredoc variable" $'sh <<\'EOF\'\ngh pr merge $PR --repo $R\nEOF' "yes"
assert_var "zsh heredoc variable" $'zsh <<\'EOF\'\ngh pr merge $PR --repo $R\nEOF' "yes"
assert_var "eval of cat heredoc variable" $'eval "$(cat <<\'EOF\'\ngh pr merge $PR --repo $R\nEOF\n)"' "yes"
assert_var "source stdin heredoc variable" $'source /dev/stdin <<\'EOF\'\ngh pr merge $PR --repo $R\nEOF' "yes"
assert_var "cat heredoc piped to bash" $'cat <<\'EOF\' | bash\ngh pr merge $PR --repo $R\nEOF' "yes"
assert_var "unquoted heredoc substitution" $'cat <<EOF\n$(gh pr merge $X)\nEOF' "yes"
assert_var "real variable merge beside data heredoc" "$data_heredoc"$'\ngh pr merge $PR' "yes"

# #1525 follow-up: executable argv lists have no contiguous `gh pr merge`
# phrase. Keep these on the public detection path so the scrub boundary is
# exercised as well as the raw scanner.
assert_merge() {
  local label="$1" cmd="$2" want="$3" got="no"
  is_merge_command "$cmd" && got="yes"
  if [ "$got" = "$want" ]; then
    echo "PASS [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label]: cmd=[$cmd]  want=[$want]  got=[$got]" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
  fi
}

assert_merge "Python subprocess.run single quotes" \
  "python3 -c \"import subprocess; subprocess.run(['gh','pr','merge','1500','--squash'])\"" "yes"
assert_merge "existing Python double-quoted list" \
  "python3 -c 'import subprocess; subprocess.run([\"gh\",\"pr\",\"merge\",\"1500\"])'" "yes"
assert_merge "existing Python JSON-escaped list" \
  'python3 -c \"import subprocess; subprocess.run([\"gh\",\"pr\",\"merge\",\"1500\"])\"' "yes"
assert_merge "Python subprocess.check_call" \
  "python3 -c \"import subprocess; subprocess.check_call(['gh', 'pr', 'merge', '1500'])\"" "yes"
assert_merge "Python subprocess.Popen" \
  "python3 -c \"import subprocess; subprocess.Popen(['gh','pr','merge','1500'])\"" "yes"
assert_merge "Python os.execvp" \
  "python3 -c \"import os; os.execvp('gh', ['gh','pr','merge','1500'])\"" "yes"
assert_merge "Node spawnSync" \
  "node -e \"require('child_process').spawnSync('gh',['pr','merge','1500'])\"" "yes"
assert_merge "Node execFileSync" \
  "node -e \"require('child_process').execFileSync('gh',['pr','merge','1500'])\"" "yes"
assert_merge "Ruby system" \
  "ruby -e \"system('gh','pr','merge','1500')\"" "yes"
python_argv_heredoc=$(cat <<'CMD'
python3 - <<'EOF'
import subprocess
subprocess.run([
    'gh',
    'pr',
    'merge',
    '1500',
])
EOF
CMD
)
assert_merge "Python multi-line heredoc argv" "$python_argv_heredoc" "yes"
assert_merge "JSON-escaped argv quotes" \
  'node -e \"require(\"child_process\").execFileSync(\"gh\",[\"pr\",\"merge\",\"1500\"])\"' "yes"
assert_merge "gh api quoted argv path" \
  "python3 -c \"import subprocess; subprocess.run(['gh','api','repos/o/r/pulls/1500/merge'])\"" "yes"
assert_merge "gh api quoted argv path after -X PUT" \
  "python3 -c \"import subprocess; subprocess.run(['gh','api','-X','PUT','repos/o/r/pulls/1500/merge'])\"" "yes"
assert_merge "gh api quoted argv path with query" \
  "python3 -c \"import subprocess; subprocess.run(['gh','api','repos/o/r/pulls/5/merge?x=1'])\"" "yes"

# B1: branch discovery has a real answer, but neither an argv-only merge's
# PR nor its repo may inherit it. An API argv path still gives literal values.
export MOCK_BRANCH_PR=1546 MOCK_BRANCH_REPO=branch/repo
assert_pr "plain CLI retains branch PR fallback" "gh pr merge --squash" "1546"
plain_repo=$(extract_repo_from_command "gh pr merge 5 --squash")
if [ "$plain_repo" = branch/repo ]; then
  echo "PASS [plain CLI retains branch repo fallback]"; PASS=$((PASS+1))
else
  echo "FAIL [plain CLI retains branch repo fallback]: got=[$plain_repo]" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}plain-repo-fallback "
fi
assert_pr "argv literal does not inherit branch PR" \
  "python3 -c \"import subprocess; subprocess.run(['gh','pr','merge','5'])\"" ""
assert_pr "argv runtime value does not inherit branch PR" \
  "python3 -c \"import subprocess, os; subprocess.run(['gh','pr','merge',os.environ['PR']])\"" ""
# A parseable CLI form beside an argv merge must not lend its PR to the gate:
# the echoed text names one PR while the argv list merges another.
mixed_cmd="echo 'gh pr merge 1544 --repo o/r'; python3 -c \"import subprocess; subprocess.run(['gh','pr','merge','6'])\""
if merge_command_uses_variable "$mixed_cmd"; then
  echo "PASS [mixed CLI text + argv merge is an opaque target]"; PASS=$((PASS+1))
else
  echo "FAIL [mixed CLI text + argv merge is an opaque target]"; FAIL=$((FAIL+1))
fi

argv_repo=$(extract_repo_from_command "python3 -c \"import subprocess; subprocess.run(['gh','pr','merge','5'])\"")
if [ -z "$argv_repo" ]; then
  echo "PASS [argv merge does not inherit branch repo]"; PASS=$((PASS+1))
else
  echo "FAIL [argv merge does not inherit branch repo]: got=[$argv_repo]" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}argv-repo-fallback "
fi
assert_pr "API argv query keeps explicit PR" \
  "python3 -c \"import subprocess; subprocess.run(['gh','api','repos/o/r/pulls/5/merge?x=1'])\"" "5"
unset MOCK_BRANCH_PR MOCK_BRANCH_REPO

assert_merge "quoted argv in cat data heredoc" $'cat > f <<\'EOF\'\nExample: [\'gh\',\'pr\',\'merge\',\'12\']\nEOF' "no"
assert_merge "gh pr view argv" "['gh','pr','view','12']" "no"
assert_merge "gh pr merged argv" "['gh','pr','merged']" "no"

# --- Bash 3.2 time bound (PR #1546 security review, H1) --------------------
# ${1//$'\n'/ } slows sharply with input size under /bin/bash 3.2. A gate that
# times out does not block, so a padded merge could skip every gate. Run the
# variable check on a 3,000-line command under /bin/bash and require it to
# finish within 10 seconds. SIGKILL ends a stuck run; 3.2 defers SIGTERM.
if [ -x /bin/bash ]; then
  perf_dir=$(mktemp -d)
  {
    echo '#!/bin/bash'
    echo ". \"$LIB_SRC\""
    echo 'w=merge'
    echo 'pad=$(i=0; while [ $i -lt 3000 ]; do echo true; i=$((i+1)); done)'
    echo 'merge_command_uses_variable "gh pr $w 5 --repo o/r'
    echo '$pad"'
    echo 'echo done > "$1"'
  } > "$perf_dir/run.sh"
  /bin/bash "$perf_dir/run.sh" "$perf_dir/out" &
  perf_pid=$!
  waited=0
  while kill -0 "$perf_pid" 2>/dev/null && [ "$waited" -lt 10 ]; do
    sleep 1; waited=$((waited+1))
  done
  if kill -0 "$perf_pid" 2>/dev/null; then
    kill -9 "$perf_pid" 2>/dev/null
    echo "FAIL [3,000-line command checked within 10s under /bin/bash]"; FAIL=$((FAIL+1))
    FAILED_CASES="$FAILED_CASES perf-bash32"
  elif [ -s "$perf_dir/out" ]; then
    echo "PASS [3,000-line command checked within 10s under /bin/bash]"; PASS=$((PASS+1))
  else
    echo "FAIL [3,000-line command check did not complete]"; FAIL=$((FAIL+1))
    FAILED_CASES="$FAILED_CASES perf-bash32"
  fi
  rm -rf "$perf_dir"
fi

# --- Cleanup -------------------------------------------------------------
rm -rf "$SHIM_DIR"

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
