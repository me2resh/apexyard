#!/bin/bash
# Regression tests for the advisory in #1940.
# Blocking matches and substring matches must both fail this suite.
set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOK_SRC=${RAW_WORKTREE_REMOVAL_HOOK:-$ROOT/.claude/hooks/warn-raw-worktree-removal.sh}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/raw-worktree-warning.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
HOOK_COMMAND=("$BASH" "$HOOK_SRC")

# Detect any attempt to inspect or execute Git from the advisory.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/git" <<'STUB'
#!/bin/sh
printf 'unexpected Git call\n' >> "$RAW_WARNING_GIT_LOG"
exit 2
STUB
chmod +x "$TMP/bin/git"
export RAW_WARNING_GIT_LOG="$TMP/git.log"
export PATH="$TMP/bin:$PATH"

check_payload() {
  local label="$1" payload="$2" want="$3" rc=0
  printf '%s' "$payload" | "${HOOK_COMMAND[@]}" >"$TMP/out" 2>"$TMP/err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL [$label]: exit $rc, expected 0"
    FAIL=$((FAIL + 1))
  elif [ -s "$TMP/out" ]; then
    echo "FAIL [$label]: unexpected stdout"
    FAIL=$((FAIL + 1))
  elif [ "$want" -eq 0 ] && [ -s "$TMP/err" ]; then
    echo "FAIL [$label]: expected silence"
    FAIL=$((FAIL + 1))
  elif [ "$want" -eq 1 ] && ! {
    grep -qF '/approve-merge' "$TMP/err" &&
    grep -qF 'owner check' "$TMP/err" &&
    grep -qF 'live or unknown owner' "$TMP/err" &&
    grep -qF 'preservation check' "$TMP/err" &&
    grep -qF 'uncommitted or unpushed work' "$TMP/err" &&
    grep -qF 'remove-worktree.sh' "$TMP/err"
  }; then
    echo "FAIL [$label]: missing risk or cleanup advice"
    FAIL=$((FAIL + 1))
  else
    echo "PASS [$label]"
    PASS=$((PASS + 1))
  fi
}

check_command() {
  local payload
  payload=$(jq -nc --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c}}')
  check_payload "$1" "$payload" "$3"
}

check_command 'absolute path' 'git worktree remove /abs/wt' 1
check_command 'repository option' 'git -C /abs/repo worktree remove /abs/wt' 1
check_command 'force option' 'git worktree remove --force /abs/wt' 1
check_command 'short force and separator' 'git -C /abs/repo worktree remove -f -- /abs/wt' 1
check_command 'relative path' 'git worktree remove ../topic' 1
check_command 'surrounding whitespace' $' \t git worktree remove /abs/wt \t ' 1
check_command 'surrounding newlines' $'\n git worktree remove /abs/wt \n' 1
check_command 'tab separators' $'git\t-C\t/abs/repo\tworktree\tremove\t/abs/wt' 1

check_command 'cleanup helper' '.claude/skills/approve-merge/remove-worktree.sh /abs/wt' 0
check_command 'cleanup helper through Bash' 'bash .claude/skills/approve-merge/remove-worktree.sh /abs/wt' 0
check_command 'worktree list' 'git worktree list' 0
check_command 'worktree add' 'git worktree add /abs/wt topic' 0
check_command 'echo mention' 'echo "git worktree remove x"' 0
check_command 'grep mention' "grep -n 'worktree remove' file" 0
check_command 'commit mention' 'git commit -m "worktree remove notes"' 0
check_command 'heredoc mention' $'cat <<\'TEXT\'\ngit worktree remove x\nTEXT' 0
check_command 'and chain' 'git worktree remove x && echo done' 0
check_command 'semicolon chain' 'cd x; git worktree remove y' 0
check_command 'or chain' 'git worktree remove x || echo failed' 0
check_command 'pipeline' 'git worktree remove x | cat' 0
check_command 'background command' 'git worktree remove x &' 0
check_command 'internal newline' $'git worktree remove x\necho done' 0
check_command 'substitution mention' 'echo $(git worktree remove x)' 0
check_command 'substituted operand' 'git worktree remove $(echo x)' 0
check_command 'backtick operand' 'git worktree remove `echo x`' 0
check_command 'output redirection' 'git worktree remove x > log' 0
check_command 'input redirection' 'git worktree remove x < file' 0
check_command 'heredoc operand' $'git worktree remove x <<TEXT\nnotes\nTEXT' 0
check_command 'quoted command' '"git worktree remove x"' 0
check_command 'quoted operand' 'git worktree remove "x"' 0
check_command 'quoted repository' "git -C '/abs/repo' worktree remove x" 0
check_command 'variable operand' 'git worktree remove $TARGET' 0
check_command 'escaped operand' 'git worktree remove work\ tree' 0
check_command 'glob operand' 'git worktree remove topic*' 0
check_command 'extra operand' 'git worktree remove x y' 0
check_command 'missing operand' 'git worktree remove' 0
check_command 'option without operand' 'git worktree remove --force' 0
check_command 'missing repository path' 'git -C worktree remove x' 0
check_command 'comment suffix' 'git worktree remove x # notes' 0
check_command 'alias invocation' 'g worktree remove x' 0
check_command 'empty command' '' 0

check_payload 'non-Bash tool' '{"tool_name":"Edit","tool_input":{"command":"git worktree remove x"}}' 0
check_payload 'other shell tool' '{"tool_name":"exec_command","tool_input":{"command":"git worktree remove x"}}' 0
check_payload 'missing tool' '{"tool_input":{"command":"git worktree remove x"}}' 0
check_payload 'missing command' '{"tool_name":"Bash","tool_input":{}}' 0
check_payload 'non-string command' '{"tool_name":"Bash","tool_input":{"command":12}}' 0
check_payload 'array command' '{"tool_name":"Bash","tool_input":{"command":["git worktree remove x"]}}' 0
check_payload 'malformed JSON' '{broken' 0
check_payload 'empty input' '' 0
check_payload 'array input' '[]' 0
check_payload 'multiple JSON inputs' $'{"tool_name":"Bash","tool_input":{"command":"git worktree remove x"}}\n{}' 0
check_payload 'escaped NUL joins keyword' '{"tool_name":"Bash","tool_input":{"command":"git worktree re\u0000move x"}}' 0
check_payload 'escaped NUL in nonmatch' '{"tool_name":"Bash","tool_input":{"command":"echo\u0000notes"}}' 0

# Raw NUL bytes must reach the hook without entering a Bash variable.
for position in key suffix; do
  rc=0
  {
    case "$position" in
      key)
        printf '{"tool_na\000me":"Bash","tool_input":{"command":"git worktree remove x"}}'
        ;;
      suffix)
        printf '{"tool_name":"Bash","tool_input":{"command":"git worktree remove x"}}\000'
        ;;
    esac
  } | "${HOOK_COMMAND[@]}" >"$TMP/out" 2>"$TMP/err" || rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ]; then
    echo "PASS [raw NUL $position]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [raw NUL $position]: expected silence and exit 0"
    FAIL=$((FAIL + 1))
  fi
done

if [ -s "$RAW_WARNING_GIT_LOG" ]; then
  echo 'FAIL [no Git execution]: advisory invoked Git'
  FAIL=$((FAIL + 1))
else
  echo 'PASS [no Git execution]'
  PASS=$((PASS + 1))
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
