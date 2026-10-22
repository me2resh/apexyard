#!/bin/bash
# #1842 (AgDR-0271): the commit-format check reads the commit message past
# each redirection, as the shell does. A redirection before the git verb,
# before the git word or among the commit arguments does not hide the
# message. Each block case has an allow twin with the same shape and a
# valid message. A message that the check cannot read blocks.
#
# Each case runs validate-commit-format.sh, or dispatch-bash.sh, from this
# source tree with the working directory in a temp fixture repo.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"
HOOKS="$ROOT/.claude/hooks"

PASS=0
FAIL=0
FAILED_CASES=""

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FX="$TMP/fx"
mkdir -p "$FX"
git -C "$FX" init -q
git -C "$FX" checkout -q -b feature/GH-1842-fixture
printf 'a\n' > "$FX/a.txt"
git -C "$FX" add a.txt
git -C "$FX" -c user.email=test@example.com -c user.name=test commit -q -m "chore: init"
GOOD_FILE="$TMP/good-msg.txt"
BAD_FILE="$TMP/bad-msg.txt"
printf 'fix(#1842): valid subject from a file\n' > "$GOOD_FILE"
printf 'not a valid subject\n' > "$BAD_FILE"

V=commit
GOOD='"fix(#1842): valid subject"'
BAD='"not a valid subject"'
NL=$'\n'
SUBJ="BLOCKED: Commit subject"

# run_case <label> <hook> <command> <want rc> <want stderr regex or "">
run_case() {
  local label="$1" hook="$2" cmd="$3" want_rc="$4" want_re="$5"
  local input got got_rc
  input=$(jq -nc --arg c "$cmd" --arg d "$FX" \
    '{tool_name:"Bash", tool_input:{command:$c}, cwd:$d}')
  got=$(cd "$FX" && printf '%s' "$input" | /bin/bash "$HOOKS/$hook" 2>&1 >/dev/null)
  got_rc=$?
  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc" >&2
    echo "    stderr: ${got:0:300}" >&2
    FAIL=$((FAIL + 1)); FAILED_CASES="${FAILED_CASES}[${label}] "
    return
  fi
  if [ -n "$want_re" ] && ! printf '%s\n' "$got" | grep -qE "$want_re"; then
    echo "FAIL [$label]: stderr did not match /$want_re/" >&2
    echo "    stderr: ${got:0:300}" >&2
    FAIL=$((FAIL + 1)); FAILED_CASES="${FAILED_CASES}[${label}] "
    return
  fi
  echo "PASS [$label]"
  PASS=$((PASS + 1))
}

# pair <label> <hook> <command with @MSG@>: the bad message blocks on the
# subject rule, and the valid message passes.
pair() {
  local label="$1" hook="$2" shape="$3"
  run_case "$label: bad message blocks" "$hook" "${shape//@MSG@/$BAD}" 2 "$SUBJ"
  run_case "$label: valid message passes" "$hook" "${shape//@MSG@/$GOOD}" 0 ""
}

H=validate-commit-format.sh
D=dispatch-bash.sh

# --- AC1 + AC3: a redirection among the commit arguments -------------------
pair "args: 2>&1 at the end" "$H" "git ${V} -m @MSG@ 2>&1"
pair "args: >/dev/null at the end" "$H" "git ${V} -m @MSG@ >/dev/null"
pair "args: >/dev/null 2>&1 at the end" "$H" "git ${V} -q -m @MSG@ >/dev/null 2>&1"
pair "args: &> file" "$H" "git ${V} -m @MSG@ &>$TMP/all.log"
pair "args: 2>> file" "$H" "git ${V} -m @MSG@ 2>>$TMP/err.log"
pair "args: quoted target with a blank" "$H" "git ${V} -m @MSG@ 2>\"$TMP/err file\""
pair "args: target glued to the message" "$H" "git ${V} -m @MSG@>$TMP/out.log"
pair "args: close a descriptor" "$H" "git ${V} -m @MSG@ 2>&-"
pair "args: named descriptor" "$H" "git ${V} -m @MSG@ {fd}>$TMP/fd.log"
pair "args: input from /dev/null" "$H" "git ${V} -m @MSG@ </dev/null"
pair "args: redirection before -m" "$H" "git ${V} 2>&1 -m @MSG@"
pair "args: redirection between -m and the message" "$H" "git ${V} -m 2>&1 @MSG@"
pair "args: --message= with 2>&1" "$H" "git ${V} --message=@MSG@ 2>&1"

# --- AC1 + AC3: a redirection before the verb or before the git word -------
pair "verb: 2>&1 before the verb" "$H" "git 2>&1 ${V} -m @MSG@"
pair "verb: >/dev/null before the verb" "$H" "git >/dev/null ${V} -m @MSG@"
pair "verb: after -C and before the verb" "$H" "git -C . 2>/dev/null ${V} -m @MSG@"
pair "verb: before the git word" "$H" ">/dev/null git ${V} -m @MSG@"
pair "verb: 2>&1 before the git word" "$H" "2>&1 git ${V} -m @MSG@"
pair "verb: after an assignment" "$H" "GIT_EDITOR=true git 2>&1 ${V} -m @MSG@"

# --- A message file and a short option group with a redirection -----------
run_case "file: -F bad file with 2>&1: block" "$H" "git ${V} -F $BAD_FILE 2>&1" 2 "$SUBJ"
run_case "file: -F good file with 2>&1: allow" "$H" "git ${V} -F $GOOD_FILE 2>&1" 0 ""
run_case "file: redirection before the verb, bad file: block" "$H" \
  "git 2>&1 ${V} -F $BAD_FILE" 2 "$SUBJ"
run_case "file: redirection before the verb, good file: allow" "$H" \
  "git 2>&1 ${V} -F $GOOD_FILE" 0 ""
run_case "file: glued -F with a redirection, bad file: block" "$H" \
  "git ${V} -F$BAD_FILE >/dev/null" 2 "$SUBJ"
run_case "file: glued -F with a redirection, good file: allow" "$H" \
  "git ${V} -F$GOOD_FILE >/dev/null" 0 ""
pair "group: -am with 2>&1" "$H" "git ${V} -am @MSG@ 2>&1"
pair "group: -sm with >/dev/null" "$H" "git ${V} -sm @MSG@ >/dev/null"
pair "group: glued -m with 2>&1" "$H" "git ${V} -m@MSG@ 2>&1"
pair "group: -am with no redirection" "$H" "git ${V} -am @MSG@"
run_case "group: -S before -m with a redirection, bad: block" "$H" \
  "git ${V} -S -m $BAD 2>&1" 2 "$SUBJ"

# --- AC2: a message that the check cannot read blocks ---------------------
run_case "unread: -F - from an input file: block" "$H" \
  "git ${V} -F - <$GOOD_FILE" 2 "cannot read a commit message from an input redirection"
run_case "unread: --file=- from an input file: block" "$H" \
  "git ${V} --file=- <$GOOD_FILE" 2 "cannot read a commit message from an input redirection"
run_case "unread: -F - from a here-string: block" "$H" \
  "git ${V} -F - <<<$GOOD" 2 "cannot read a commit message from an input redirection"
run_case "unread: process substitution as a target: block" "$H" \
  "git ${V} -m $GOOD >(cat)" 2 "cannot read this commit command past a redirection"
run_case "unread: process substitution before the verb: block" "$H" \
  "git >(cat) ${V} -m $GOOD" 2 "BLOCKED"
run_case "unread: unclosed quote in a target: block" "$H" \
  "git ${V} -m $GOOD 2>\"$TMP/x" 2 "cannot read this commit command past a redirection"
run_case "unread: unclosed quote in a word: block" "$H" \
  "git ${V} -m \"fix(#1842): open" 2 "cannot safely parse"
run_case "unread: -F good file with input from /dev/null: allow" "$H" \
  "git ${V} -F $GOOD_FILE </dev/null" 0 ""

# --- A redirection does not hide a second command ---------------------------
run_case "compound: line break in a redirection target: block" "$H" \
  "git ${V} -m $GOOD >$TMP/out${NL}git -C . ${V} -m $BAD" 2 "compound commit commands"
run_case "compound: 2>&1 and a pipe: block" "$H" \
  "git ${V} -m $GOOD 2>&1 | tail -1" 2 "compound commit commands"
run_case "compound: 2>&1 and &&: block" "$H" \
  "git ${V} -m $GOOD 2>&1 && git log -1" 2 "compound commit commands"
run_case "compound: 2>&1 and a trailing &: block" "$H" \
  "git ${V} -m $GOOD 2>&1 &" 2 "compound commit commands"
run_case "compound: ; before a redirected verb: block" "$H" \
  "cd . ; git 2>&1 ${V} -m $BAD" 2 "compound commit commands"
run_case "not a commit: git log with 2>&1 and prose: allow" "$H" \
  "git log --oneline 2>&1 ; echo ${V}" 0 ""
run_case "interactive commit with 2>&1: allow" "$H" "git ${V} 2>&1" 0 ""

# --- Through the dispatcher -----------------------------------------------
pair "dispatcher: 2>&1 before the verb" "$D" "git 2>&1 ${V} -m @MSG@"
pair "dispatcher: >/dev/null 2>&1 at the end" "$D" "git ${V} -m @MSG@ >/dev/null 2>&1"
pair "dispatcher: -am with 2>&1" "$D" "git ${V} -am @MSG@ 2>&1"
run_case "dispatcher: -F - from an input file: block" "$D" \
  "git ${V} -F - <$BAD_FILE" 2 "cannot read a commit message from an input redirection"

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
