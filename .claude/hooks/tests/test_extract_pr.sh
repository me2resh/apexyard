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
cat > "$SHIM_DIR/glab" <<'GLABEOF'
#!/bin/bash
# Controlled branch MR fallback for glab opacity tests.
case "$*" in
  *"mr view"*)
    if [ -n "${MOCK_BRANCH_PR:-}" ]; then
      printf '{"iid":%s}\n' "$MOCK_BRANCH_PR"
    fi
    ;;
esac
exit 0
GLABEOF
chmod +x "$SHIM_DIR/glab"
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
assert_merge "gh pr list argv" "['gh','pr','list']" "no"
assert_merge "jq mergeable array" 'jq -n '\''["gh","pr","mergeable"]'\''' "no"

# --- #1552 argv-merge gap shapes ------------------------------------------
# Positive cases: each must detect as a merge and treat the target as opaque.
assert_opaque() {
  local label="$1" cmd="$2"
  if ! is_merge_command "$cmd"; then
    echo "FAIL [$label]: not detected as merge; cmd=[$cmd]" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  if ! merge_command_uses_variable "$cmd"; then
    echo "FAIL [$label]: target not opaque; cmd=[$cmd]" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  echo "PASS [$label]"; PASS=$((PASS+1))
}

assert_opaque "1552 padded gh element" "[' gh','pr','merge','5']"
assert_opaque "1552 full-path gh element" "['/usr/bin/gh','pr','merge','5']"
assert_opaque "1552 homebrew gh element" '["/opt/homebrew/bin/gh","pr","merge","5"]'
assert_opaque "1552 global -R between elements" "['gh','-R','o/r','pr','merge','5']"
assert_opaque "1552 global --repo between elements" "['gh','--repo','o/r','pr','merge','5']"
assert_opaque "1552 glab argv" "['glab','mr','merge','5']"
assert_opaque "1552 glab argv with -R" "['glab','-R','o/r','mr','merge','5']"
assert_opaque "1552 api argv with comma in element" \
  "['gh','api','-f','m=a,b','repos/o/r/pulls/5/merge']"
# Rex #1556: backtick inside a '…' / "…" API element must not end the element.
api_bt_sq=$(cat <<'CMD'
python3 -c "import subprocess; subprocess.run(['gh','api','-X','PUT','-f','commit_message=fix `x`','repos/o/r/pulls/5/merge'])"
CMD
)
assert_opaque "1552 api argv backtick in single-quoted element" "$api_bt_sq"
api_bt_dq=$(cat <<'CMD'
python3 -c 'import subprocess; subprocess.run(["gh","api","-f","commit_title=Use `foo`","repos/o/r/pulls/5/merge"])'
CMD
)
assert_opaque "1552 api argv backtick in double-quoted element" "$api_bt_dq"
assert_opaque "1552 split-tail element" "execFileSync('gh', 'pr merge 5'.split(' '))"
assert_opaque "1552 concat split-tail" "['gh'] + 'pr merge 5'.split()"
assert_opaque "1552 JS backtick argv" '[`gh`,`pr`,`merge`]'
assert_opaque "1552 joined list" "['gh','pr'] + ['merge','5']"
assert_opaque "1552 star-unpack list" "[*['gh','pr'], 'merge']"

# Readable: merge yes, opaque no, optional expected PR.
assert_readable() {
  local label="$1" cmd="$2" want_pr="${3:-}"
  local got
  if ! is_merge_command "$cmd"; then
    echo "FAIL [$label]: not detected as merge; cmd=[$cmd]" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  if merge_command_uses_variable "$cmd"; then
    echo "FAIL [$label]: target unexpectedly opaque; cmd=[$cmd]" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  if [ -n "$want_pr" ]; then
    got=$(extract_pr_number "$cmd")
    if [ "$got" != "$want_pr" ]; then
      echo "FAIL [$label]: want pr=[$want_pr] got=[$got]; cmd=[$cmd]" >&2
      FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
      return
    fi
  fi
  echo "PASS [$label]"; PASS=$((PASS+1))
}

# Wrong-PR wrappers: opaque, and must not resolve to the branch PR.
export MOCK_BRANCH_PR=1546
assert_opaque "1552 sh -c argv wrapper" "['sh','-c', 'gh pr merge 5']"
assert_opaque "1552 bash -c argv wrapper" "['bash','-c', 'gh pr merge 5']"
assert_opaque "1552 zsh -c argv wrapper" "['zsh','-c', 'gh pr merge 5']"
assert_opaque "1552 xargs merge" "echo 5 | xargs gh pr merge"
assert_opaque "1552 perl qw merge" "perl -e 'system qw(gh pr merge 5)'"
assert_opaque "1552 perl qw glab mr" "perl -e 'system qw(glab mr merge 5)'"
assert_opaque "1552 perl system list" "perl -e \"system('gh','pr','merge',5)\""
assert_pr "1552 sh -c does not inherit branch PR" "['sh','-c', 'gh pr merge 5']" ""
assert_pr "1552 xargs does not inherit branch PR" "echo 5 | xargs gh pr merge" ""
assert_pr "1552 perl qw does not inherit branch PR" "perl -e 'system qw(gh pr merge 5)'" ""
assert_pr "1552 perl qw glab does not inherit branch MR" "perl -e 'system qw(glab mr merge 5)'" ""

# Wrapper opacity is statement-local: an earlier xargs / -c must not poison a
# later plain merge separated by ; && || or a newline outside quotes.
assert_readable "1552 xargs then plain merge stays readable" \
  "ls | xargs echo; gh pr merge 5 --repo o/r --squash" "5"
assert_readable "1552 xargs && plain merge stays readable" \
  "find . -name '*.tmp' | xargs rm -f && gh pr merge 5 --repo o/r --squash" "5"
xargs_nl=$(printf '%s\n%s' 'ls | xargs echo' 'gh pr merge 5 --repo o/r --squash')
assert_readable "1552 xargs newline then plain merge stays readable" "$xargs_nl" "5"
assert_readable "1552 sh -c elsewhere then plain merge stays readable" \
  "python3 -c \"import subprocess; subprocess.run(['bash','-c','make test'])\" && gh pr merge 5 --repo o/r" "5"

# Quoted separators inside xargs -I{} sh -c '…' must NOT split the statement
# (#1552 round 2). Same statement + xargs = opaque (no 80-char window).
_m1552=$(printf '%s %s %s' gh pr merge)
assert_opaque "1552 xargs sh -c quoted semicolon" "xargs -I{} sh -c 'cd x; ${_m1552} {}'"
assert_opaque "1552 xargs sh -c quoted &&" "xargs -I{} sh -c 'cd x && ${_m1552} {}'"
assert_opaque "1552 xargs sh -c quoted ||" "xargs -I{} sh -c 'false || ${_m1552} {}'"
xargs_qnl=$(printf "xargs -I{} sh -c 'cd x\n%s {}'" "$_m1552")
assert_opaque "1552 xargs sh -c quoted newline" "$xargs_qnl"
_pad90=$(awk 'BEGIN{for(i=0;i<90;i++)printf "x"}')
assert_opaque "1552 xargs >80 chars before merge same statement" \
  "xargs -I{} sh -c '${_pad90}; ${_m1552} {}'"
assert_pr "1552 xargs quoted semicolon does not inherit branch PR" \
  "xargs -I{} sh -c 'cd x; ${_m1552} {}'" ""

# Round 3: quote-like text before the wrapper must not let its target inherit
# the branch PR. The open-quote case deliberately has malformed shell text;
# the scanner must fail closed when it still contains a merge phrase.
q_comment=$(printf "true # don't\necho 5 | xargs -I{} sh -c 'x; %s {}'" "$_m1552")
q_heredoc=$(printf "cat <<EOT\ndon't\nEOT\necho 5 | xargs -I{} sh -c 'x; %s {}'" "$_m1552")
q_ansi=$(printf "echo 5 | xargs -I{} sh -c \$'a\\'b; %s {}'" "$_m1552")
q_unclosed=$(printf "echo 'unfinished; echo 5 | xargs -I{} sh -c 'x; %s {}'" "$_m1552")
assert_opaque "1552 comment apostrophe before xargs is opaque" "$q_comment"
assert_opaque "1552 heredoc apostrophe before xargs is opaque" "$q_heredoc"
assert_opaque "1552 escaped quote in ANSI-C string is opaque" "$q_ansi"
assert_opaque "1552 unclosed quote with merge phrase is opaque" "$q_unclosed"
assert_pr "1552 comment apostrophe does not inherit branch PR" "$q_comment" ""
assert_pr "1552 heredoc apostrophe does not inherit branch PR" "$q_heredoc" ""
assert_pr "1552 ANSI-C escaped quote does not inherit branch PR" "$q_ansi" ""
assert_pr "1552 unclosed quote does not inherit branch PR" "$q_unclosed" ""
unset MOCK_BRANCH_PR

# Fail-before evidence: the pre-#1552 lib must miss these shapes. The saved
# copy is optional (CI has no /tmp fixture); when present, each case must fail.
BEFORE_LIB="${EXTRACT_PR_BEFORE_LIB:-/tmp/_lib-extract-pr-1552-before.sh}"
if [ -f "$BEFORE_LIB" ]; then
  before_shim=$(mktemp -d)
  printf '%s\n' '#!/bin/bash' 'case "$*" in *number*) printf "%s\n" "${MOCK_BRANCH_PR:-}";; esac' 'exit 0' \
    > "$before_shim/gh"
  chmod +x "$before_shim/gh"
  printf '%s\n' '#!/bin/bash' 'case "$*" in *"mr view"*) printf "{\"iid\":%s}\n" "${MOCK_BRANCH_PR:-}";; esac' 'exit 0' \
    > "$before_shim/glab"
  chmod +x "$before_shim/glab"
  before_out=$(mktemp)
  PATH="$before_shim:$PATH" MOCK_BRANCH_PR=1546 bash -c '
    . "$1"
    fail=0
    check() {
      local label="$1" cmd="$2" mode="$3"
      case "$mode" in
        detect)
          if is_merge_command "$cmd" && merge_command_uses_variable "$cmd"; then
            echo "UNEXPECTED-PASS $label"; fail=1
          else
            echo "FAIL-BEFORE-OK $label"
          fi
          ;;
        opaque)
          if merge_command_uses_variable "$cmd"; then
            echo "UNEXPECTED-PASS $label"; fail=1
          else
            echo "FAIL-BEFORE-OK $label"
          fi
          ;;
      esac
    }
    check "padded" "['\'' gh'\'','\''pr'\'','\''merge'\'','\''5'\'']" detect
    check "flags" "['\''gh'\'','\''-R'\'','\''o/r'\'','\''pr'\'','\''merge'\'','\''5'\'']" detect
    check "glab" "['\''glab'\'','\''mr'\'','\''merge'\'','\''5'\'']" detect
    check "api-comma" "['\''gh'\'','\''api'\'','\''-f'\'','\''m=a,b'\'','\''repos/o/r/pulls/5/merge'\'']" detect
    check "split-tail" "execFileSync('\''gh'\'', '\''pr merge 5'\''.split('\'' '\''))" detect
    check "backtick" "[\`gh\`,\`pr\`,\`merge\`]" detect
    check "joined" "['\''gh'\'','\''pr'\''] + ['\''merge'\'','\''5'\'']" detect
    check "sh-c" "['\''sh'\'','\''-c'\'', '\''gh pr merge 5'\'']" opaque
    check "xargs" "echo 5 | xargs gh pr merge" opaque
    check "qw" "perl -e '\''system qw(gh pr merge 5)'\''" opaque
    check "qw-glab" "perl -e '\''system qw(glab mr merge 5)'\''" opaque
    exit "$fail"
  ' _ "$BEFORE_LIB" > "$before_out" 2>&1
  before_rc=$?
  if [ "$before_rc" -eq 0 ] && grep -q 'FAIL-BEFORE-OK' "$before_out" && ! grep -q 'UNEXPECTED-PASS' "$before_out"; then
    echo "PASS [1552 fail-before evidence against saved pre-change lib]"
    PASS=$((PASS+1))
  else
    echo "FAIL [1552 fail-before evidence]: rc=$before_rc" >&2
    cat "$before_out" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}1552-fail-before "
  fi
  rm -rf "$before_shim" "$before_out"
else
  echo "NOTE: not counted [1552 fail-before evidence — no BEFORE_LIB at $BEFORE_LIB]"
fi

# Round-2 fail-before: quoted-separator xargs forms fail on 9240c7f head.
HEAD_R2_LIB="${EXTRACT_PR_HEAD_R2_LIB:-/tmp/_lib-extract-pr-1552-head-9240c7f.sh}"
if [ -f "$HEAD_R2_LIB" ]; then
  before_shim=$(mktemp -d)
  printf '%s\n' '#!/bin/bash' 'case "$*" in *number*) printf "%s\n" "${MOCK_BRANCH_PR:-}";; esac' 'exit 0' \
    > "$before_shim/gh"
  chmod +x "$before_shim/gh"
  before_out=$(mktemp)
  PATH="$before_shim:$PATH" MOCK_BRANCH_PR=1546 bash -c '
    . "$1"
    fail=0
    m=$(printf "%s %s %s" gh pr merge)
    check() {
      local label="$1" cmd="$2"
      if merge_command_uses_variable "$cmd"; then
        echo "UNEXPECTED-PASS $label"; fail=1
      else
        echo "FAIL-BEFORE-OK $label"
      fi
    }
    check "xargs-q-semi" "xargs -I{} sh -c \"cd x; ${m} {}\""
    check "xargs-q-and" "xargs -I{} sh -c \"cd x && ${m} {}\""
    check "xargs-q-or" "xargs -I{} sh -c \"false || ${m} {}\""
    qnl=$(printf "xargs -I{} sh -c \"cd x\\n%s {}\"" "$m")
    check "xargs-q-nl" "$qnl"
    pad90=$(awk "BEGIN{for(i=0;i<90;i++)printf \"x\"}")
    check "xargs-long" "xargs -I{} sh -c \"${pad90}; ${m} {}\""
    exit "$fail"
  ' _ "$HEAD_R2_LIB" > "$before_out" 2>&1
  before_rc=$?
  if [ "$before_rc" -eq 0 ] && grep -q 'FAIL-BEFORE-OK' "$before_out" && ! grep -q 'UNEXPECTED-PASS' "$before_out"; then
    echo "PASS [1552 round-2 fail-before against head 9240c7f lib]"
    PASS=$((PASS+1))
  else
    echo "FAIL [1552 round-2 fail-before]: rc=$before_rc" >&2
    cat "$before_out" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}1552-fail-before-r2 "
  fi
  rm -rf "$before_shim" "$before_out"
else
  echo "NOTE: not counted [1552 round-2 fail-before — no HEAD_R2_LIB at $HEAD_R2_LIB]"
fi

# --- Bash 3.2 time bound (PR #1546 security review, H1) --------------------
# A gate that times out does not block, so a padded merge could skip every
# gate. Run /bin/bash directly with a SIGKILL watchdog. The watchdog's EXIT
# trap also kills its sleep child. Large inputs are built from files in the
# child process; the test runner never passes them as an argv string.
if [ -x /bin/bash ]; then
  _run_perf_watchdog() {
    local script="$1" out="$2" limit_s="$3"
    local perf_pid watchdog_pid sleep_pid perf_rc
    PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash "$script" "$out" &
    perf_pid=$!
    (
      sleep "$limit_s" &
      sleep_pid=$!
      trap 'kill "$sleep_pid" 2>/dev/null; wait "$sleep_pid" 2>/dev/null || true' EXIT
      trap 'exit 0' TERM
      wait "$sleep_pid"
      kill -9 "$perf_pid" 2>/dev/null || true
    ) &
    watchdog_pid=$!
    wait "$perf_pid" 2>/dev/null
    perf_rc=$?
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    [ "$perf_rc" -eq 0 ] && [ -s "$out" ]
  }

  _run_perf_bound() {
    local lines="$1" limit_s="$2" label="$3"
    local perf_dir
    perf_dir=$(mktemp -d)
    {
      echo '#!/bin/bash'
      echo ". \"$LIB_SRC\""
      echo 'm=$(printf "%s %s %s" gh pr merge)'
      echo 'w=merge'
      echo "padfile=\$(mktemp)"
      echo "{ printf '%s 5 --repo o/r --squash\\n' \"\$m\""
      echo "  i=0; while [ \$i -lt $lines ]; do echo true; i=\$((i+1)); done"
      echo '} > "$padfile"'
      echo 'cmd=$(cat "$padfile")'
      echo 'merge_command_uses_variable "$cmd" >/dev/null'
      echo 'merge_command_uses_variable "['\''/usr/bin/gh'\'','\''-R'\'','\''o/r'\'','\''pr'\'','\''$w'\'','\''5'\'']" >/dev/null'
      echo 'xcmd=$(printf "echo 5 | xargs %s" "$m")'
      echo 'merge_command_uses_variable "$xcmd" >/dev/null'
      echo 'echo done > "$1"'
      echo 'rm -f "$padfile"'
    } > "$perf_dir/run.sh"
    if _run_perf_watchdog "$perf_dir/run.sh" "$perf_dir/out" "$limit_s"; then
      echo "PASS [$label]"; PASS=$((PASS+1))
    else
      echo "FAIL [$label]"; FAIL=$((FAIL+1))
      FAILED_CASES="$FAILED_CASES perf-bash32-$lines"
    fi
    rm -rf "$perf_dir"
  }

  _run_long_statement_bound() {
    local bytes="$1" run="$2" limit_s=8 perf_dir start_s elapsed_s
    perf_dir=$(mktemp -d)
    {
      echo '#!/bin/bash'
      echo ". \"$LIB_SRC\""
      echo 'm=$(printf "%s %s %s" gh pr merge)'
      echo "padfile=\"$perf_dir/pad\""
      echo "cmdfile=\"$perf_dir/command\""
      echo "head -c $bytes /dev/zero | tr '\\000' x > \"\$padfile\""
      echo 'printf "%s 5 --repo o/r --body " "$m" > "$cmdfile"'
      echo 'cat "$padfile" >> "$cmdfile"'
      echo 'cmd=$(cat "$cmdfile")'
      echo 'if merge_command_uses_variable "$cmd"; then exit 1; fi'
      echo 'echo done > "$1"'
    } > "$perf_dir/run.sh"
    start_s=$(date +%s)
    if _run_perf_watchdog "$perf_dir/run.sh" "$perf_dir/out" "$limit_s"; then
      elapsed_s=$(($(date +%s) - start_s))
      echo "PASS [long statement ${bytes} bytes run ${run}: ${elapsed_s}s]"
      PASS=$((PASS+1))
    else
      echo "FAIL [long statement ${bytes} bytes run ${run}: >${limit_s}s or wrong result]"
      FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES long-statement-$bytes-$run"
    fi
    rm -rf "$perf_dir"
  }

  _run_perf_bound 3000 10 "3,000-line command checked within 10s under /bin/bash"
  _run_perf_bound 6000 10 "6,000-line command checked within 10s under /bin/bash"
  for _perf_run in 1 2 3 4 5 6; do
    _run_long_statement_bound 200000 "$_perf_run"
    _run_long_statement_bound 800000 "$_perf_run"
  done
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
