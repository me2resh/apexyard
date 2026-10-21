#!/bin/bash
# #1831: the push gates read the destination ref past a redirection.
#
# validate-branch-name.sh and block-main-push.sh read the push destination
# through _lib-extract-push-ref.sh. That code cut the command at the first
# redirection. A redirection before the git verb, or among the push
# arguments, hid the ref, and both gates fell back to local HEAD.
#
# This suite runs the real gates in a hermetic setup with two repositories:
# the working directory is on a feature branch with a valid name, and a
# second repository is on main. Each block case has an allow twin.
# Fail-before uses the hooks tree at a pinned dev commit (build rule 10a).
set -u
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
ROOT=$(cd "$TEST_DIR/../../.." && pwd)
HOOKS="$ROOT/.claude/hooks"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

# Placeholders keep the git command word off the parent shell line.
G=gi
G="${G}t"
BAD=notaticket-branch
GOOD=feature/GH-1831-x

TMP=$(mktemp -d)
scratch=""
trap 'rm -rf "$TMP" "${scratch:-}"' EXIT

# Hermetic repositories. Never change git config: pass -c for the commit.
make_repo() {
  local dir="$1" branch="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" -c user.email=test@example.com -c user.name=Test \
    -c core.hooksPath=/dev/null -c commit.gpgsign=false \
    commit -q --allow-empty -m init
  git -C "$dir" checkout -q -B "$branch"
}
CWD_REPO="$TMP/cwd"
OTHER_REPO="$TMP/other"
make_repo "$CWD_REPO" "$GOOD"
make_repo "$OTHER_REPO" main

# Print the exit code of one gate for one command, run from the cwd repo.
gate_rc() {
  local hooks="$1" gate="$2" cmd="$3" payload rc=0
  payload=$(jq -cn --arg c "$cmd" --arg d "$CWD_REPO" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  (cd "$CWD_REPO" && printf '%s' "$payload" | /bin/bash "$hooks/$gate" >/dev/null 2>&1) || rc=$?
  printf '%s' "$rc"
}

expect() {
  local want="$1" gate="$2" cmd="$3" label="$4" got
  got=$(gate_rc "$HOOKS" "$gate" "$cmd")
  if [ "$got" = "$want" ]; then
    pass "$label (${gate%.sh} rc=$got): $cmd"
  else
    fail "$label (${gate%.sh} rc=$got, want $want): $cmd"
  fi
}

# Run the shared extractor on one command.
core() {
  /bin/bash -c '. "$1/_lib-extract-push-ref.sh" || exit 9; _extract_push_ref_core "$2"' _ "$HOOKS" "$1"
}

VBN=validate-branch-name.sh
BMP=block-main-push.sh

# Each redirection operator class from #1835 (_git_redir_op), with a glued
# target, a digit target, a spaced target, a quoted target with a blank, a
# substitution target and a named descriptor.
redirs=(
  '>o' '>>o' '2>o' '&>o' '&>>o' '>|o' '>!o' '>>|o' '>>!o' '&>|o' '&>!o'
  '>&|o' '>>&o' '>&2' '2>&1' '2>&-' '<i' '<&0' '<<<x' '<<E' '<<-E'
  '{fd}>o' '> o' '2> o' '>"o p"' ">'o p'" '>$(echo o)'
)

# Unit: each operator class at each position of the redirection, through
# both extractors that the gates use. One bash process runs the whole set,
# because one gate call costs about half a second.
# before: between the git word and the verb. among: between the verb and
# the remote. after: after the ref (the old code read these already).
unit_out=$(/bin/bash -c '
  . "$1/_lib-extract-push-ref.sh" || exit 9
  G="$2"; BAD="$3"; GOOD="$4"; shift 4
  for r in "$@"; do
    for pos in before among after; do
      for ref in "$BAD" "$GOOD" main; do
        case "$pos" in
          before) cmd="$G $r push origin $ref" ;;
          among) cmd="$G push $r origin $ref" ;;
          after) cmd="$G push origin $ref $r" ;;
        esac
        got=$(_extract_push_ref_core "$cmd")
        if [ "$got" = "$ref" ]; then echo "PASS: extractor reads the ref ($pos): $cmd"
        else echo "FAIL: extractor reads the ref ($pos, got $got): $cmd"; fi
        all=$(_extract_all_push_refs_core "$cmd")
        if [ "$all" = "$ref" ]; then echo "PASS: scan of all pushes reads the ref ($pos): $cmd"
        else echo "FAIL: scan of all pushes reads the ref ($pos, got $all): $cmd"; fi
      done
    done
  done
' _ "$HOOKS" "$G" "$BAD" "$GOOD" "${redirs[@]}" 2>&1)
while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    *) fail "${line#FAIL: }" ;;
  esac
done <<EOF_UNIT
$unit_out
EOF_UNIT

# Real gates: one operator from each family, before the verb and among the
# arguments. Each block case has an allow twin.
for r in '>o' '2>&1' '&>>o' '>"o p"'; do
  for pos in before among; do
    case "$pos" in
      before) form="$G $r push origin %s" ;;
      among) form="$G push $r origin %s" ;;
    esac
    # shellcheck disable=SC2059
    expect 2 "$VBN" "$(printf "$form" "$BAD")" "branch-name blocks a bad ref, redirection $pos"
    # shellcheck disable=SC2059
    expect 0 "$VBN" "$(printf "$form" "$GOOD")" "branch-name allows a good ref, redirection $pos"
    # shellcheck disable=SC2059
    expect 2 "$BMP" "$(printf "$form" main)" "main-push blocks main, redirection $pos"
    # shellcheck disable=SC2059
    expect 0 "$BMP" "$(printf "$form" "$GOOD")" "main-push allows a feature ref, redirection $pos"
  done
done

# A refspec destination, a quoted ref and a push option, past a redirection.
expect 2 "$VBN" "$G >/dev/null push origin HEAD:$BAD" "refspec destination"
expect 0 "$VBN" "$G >/dev/null push origin HEAD:$GOOD" "refspec destination twin"
expect 2 "$BMP" "$G >/dev/null push origin +HEAD:refs/heads/main" "full refspec to main"
expect 0 "$BMP" "$G >/dev/null push origin +HEAD:refs/heads/$GOOD" "full refspec twin"
expect 2 "$VBN" "$G push -u >o origin \"$BAD\"" "quoted ref after an option"
expect 0 "$VBN" "$G push -u >o origin \"$GOOD\"" "quoted ref twin"
expect 2 "$BMP" "$G push -o ci.skip 2>&1 origin main" "option value then a redirection"
expect 0 "$BMP" "$G push -o ci.skip 2>&1 origin $GOOD" "option value twin"

# Chains: the redirected push after another command or another push.
expect 2 "$VBN" "echo hi; $G >o push origin $BAD" "chain: redirected push after echo"
expect 0 "$VBN" "echo hi; $G >o push origin $GOOD" "chain twin"
expect 2 "$BMP" "$G push origin $GOOD && $G push 2>&1 origin main" "chain: second push to main"
expect 0 "$BMP" "$G push origin $GOOD && $G push 2>&1 origin $GOOD" "chain twin: second push to a feature ref"
expect 2 "$BMP" "$G push origin $BAD 2>&1 | tail -5; $G >o push origin main" "chain with a pipe"
expect 0 "$BMP" "$G push origin $BAD 2>&1 | tail -5; $G >o push origin $GOOD" "chain with a pipe twin"

# #1831 B1: a unit separator byte (0x1F) in the push arguments. The walk
# uses that byte to split the line, so it fails closed. Each block case has
# a twin with no byte, at top level and with a redirection before the verb.
US=$'\037'
for pre in "$G" "$G >o"; do
  expect 2 "$VBN" "$pre push origin $BAD #$US" "branch-name fails closed on a 0x1F byte"
  expect 0 "$VBN" "$pre push origin $GOOD #x" "branch-name twin without the byte"
  expect 2 "$BMP" "$pre push origin main #$US" "main-push fails closed on a 0x1F byte"
  expect 0 "$BMP" "$pre push origin $GOOD #x" "main-push twin without the byte"
done
# A good ref with the byte also fails closed: the gate cannot read the words.
expect 2 "$BMP" "$G push origin $GOOD; echo \"$US\"" "main-push fails closed on a 0x1F byte after the push"
rc=0
/bin/bash -c '. "$1/_lib-git-global.sh" || exit 9; git_push_ref_words "$2" >/dev/null' _ "$HOOKS" "$G push origin main$US" || rc=$?
if [ "$rc" = 2 ]; then
  pass "word walk returns 2 for a 0x1F byte"
else
  fail "word walk returns 2 for a 0x1F byte (rc=$rc)"
fi

# Rex A3: the open-word fallback splits at blanks. The open word stays one
# piece; the words after it do not join it.
got=$(/bin/bash -c '. "$1/_lib-git-global.sh" || exit 9; git_push_ref_words "$2"' _ "$HOOKS" "$G push origin \"$GOOD next words" | tr '\n' '|')
if [ "$got" = "origin|\"$GOOD|next|words|" ]; then
  pass "open-word fallback splits at blanks"
else
  fail "open-word fallback splits at blanks (got '$got')"
fi

# Tag pushes stay exempt past a redirection.
expect 0 "$VBN" "$G >o push origin tag v1.2.3" "tag push with tag keyword"
expect 0 "$VBN" "$G push 2>&1 origin refs/tags/v1.2.3" "tag push by full ref"
expect 0 "$VBN" "$G >o push --tags origin" "tag push with --tags"
expect 0 "$BMP" "$G >o push origin tag v1.2.3" "main-push: tag push with tag keyword"
expect 0 "$BMP" "$G push 2>&1 origin --tags" "main-push: tag push with --tags"
# Block twin: a branch push next to a tag push is still checked.
expect 2 "$BMP" "$G >o push origin --tags && $G >o push origin main" "tag push and a push to main"

# Ref-less pushes past a redirection use the branch of the selected repo.
expect 0 "$BMP" "$G >o push origin" "ref-less push from the feature repo"
expect 2 "$BMP" "$G >o -C $OTHER_REPO push origin" "ref-less push from the main repo"
expect 0 "$BMP" "$G 2>&1 -C $CWD_REPO push" "ref-less push with -C to the feature repo"
expect 2 "$BMP" "$G 2>&1 -C $OTHER_REPO push" "ref-less push with -C to the main repo"
expect 0 "$VBN" "$G >o push origin" "branch-name: ref-less push on a good branch"

# Fail closed: the push arguments cannot be read.
fail_closed=(
  "$G push >\"o origin $GOOD"
  "$G push origin >\"o $GOOD"
  "$G push >\$(x origin $GOOD"
  "$G push origin $GOOD >'o"
  "$G push >! o origin $GOOD"
  "$G push &>! o origin $GOOD"
  "$G >o push origin \"$GOOD"
  "$G push <(echo) origin $GOOD"
)
fail_twins=(
  "$G push >\"o\" origin $GOOD"
  "$G push origin >\"o\" $GOOD"
  "$G push >\$(x) origin $GOOD"
  "$G push origin $GOOD >'o'"
  "$G push >!o origin $GOOD"
  "$G push &>!o origin $GOOD"
  "$G >o push origin \"$GOOD\""
  "$G push <i origin $GOOD"
)
# Unit: each shape returns 3 from both extractors; each twin reads the ref.
for cmd in "${fail_closed[@]}"; do
  rc=0
  core "$cmd" >/dev/null || rc=$?
  rc_all=0
  /bin/bash -c '. "$1/_lib-extract-push-ref.sh" || exit 9; _extract_all_push_refs_core "$2"' _ "$HOOKS" "$cmd" >/dev/null || rc_all=$?
  if [ "$rc" = 3 ] && [ "$rc_all" = 3 ]; then
    pass "extractors return 3 for unreadable push words: $cmd"
  else
    fail "extractors return 3 for unreadable push words (rc=$rc, all=$rc_all): $cmd"
  fi
done
for cmd in "${fail_twins[@]}"; do
  got=$(core "$cmd")
  if [ "$got" = "$GOOD" ]; then
    pass "extractor reads readable push words: $cmd"
  else
    fail "extractor reads readable push words (got '$got'): $cmd"
  fi
done
# Real gates: four shapes and their twins in both gates.
for i in 0 2 4 6; do
  expect 2 "$VBN" "${fail_closed[i]}" "branch-name fails closed on unreadable push words"
  expect 2 "$BMP" "${fail_closed[i]}" "main-push fails closed on unreadable push words"
  expect 0 "$VBN" "${fail_twins[i]}" "branch-name allows readable push words"
  expect 0 "$BMP" "${fail_twins[i]}" "main-push allows readable push words"
done
# No redirection: an open quote reads as before.
expect 0 "$BMP" "$G push origin \"$GOOD" "open quote with no redirection"

# No regression for prose: an open quote after a push word, with no
# redirection, reads as before (#584 arrow case too).
expect 0 "$BMP" "$G commit -m \"the $G push gate's check\"" "prose with an apostrophe"
expect 0 "$VBN" "$G commit -m \"fix a -> b\" && $G push origin $GOOD" "arrow in a commit message"
expect 2 "$VBN" "$G commit -m \"fix a -> b\" && $G push origin $BAD" "arrow twin"

# Unit: the shared extractor returns the ref, or 3 when it cannot read it.
for cmd in "$G push origin $BAD" "$G >o push origin $BAD" "$G 2>o push origin $BAD" \
  "$G push >o origin $BAD" "echo hi; $G >o push origin $BAD" \
  "$G push origin $BAD 2>&1 | tail -5"; do
  got=$(core "$cmd")
  if [ "$got" = "$BAD" ]; then
    pass "extractor reads the ref: $cmd"
  else
    fail "extractor reads the ref (got '$got'): $cmd"
  fi
done
rc=0
core "$G push >\"o origin $BAD" >/dev/null || rc=$?
if [ "$rc" = 3 ]; then
  pass "extractor returns 3 for unreadable push words"
else
  fail "extractor returns 3 for unreadable push words (rc=$rc)"
fi

# Fail-before: the same gates at a pinned dev commit miss the ref. The pin
# is the #1835 squash on dev. PUSH_REF_1831_BASE_HOOKS or
# PUSH_REF_1831_BASE_REF overrides the pin.
FAIL_BEFORE_PIN=defd0597094d80e72e366de76bf62127410fea98
BASE_HOOKS="${PUSH_REF_1831_BASE_HOOKS:-}"
fb_note=""
if [ -z "$BASE_HOOKS" ]; then
  BASE_REF="${PUSH_REF_1831_BASE_REF:-$FAIL_BEFORE_PIN}"
  if git -C "$ROOT" rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null 2>&1; then
    scratch=$(mktemp -d)
    git -C "$ROOT" archive "$BASE_REF" .claude/hooks | tar -x -C "$scratch"
    BASE_HOOKS="$scratch/.claude/hooks"
  else
    # Shallow CI clones can miss the pinned commit.
    fb_note="pinned base ${BASE_REF} is not in this clone"
  fi
fi
if [ -z "$fb_note" ] && [ ! -f "$BASE_HOOKS/_lib-extract-push-ref.sh" ]; then
  fb_note="no base _lib-extract-push-ref.sh"
fi
if [ -z "$fb_note" ] && grep -q 'git_push_ref_words' "$BASE_HOOKS/_lib-git-global.sh" 2>/dev/null; then
  fb_note="base ${BASE_REF:-override} already reads past redirections"
fi
if [ -z "$fb_note" ]; then
  fb_total=0
  fb_miss=0
  # The old cut needs a blank, digits and then `>` or `|`. Thus `&>` before
  # the verb was read on base; among the arguments it was not.
  for r in '>o' '&>o' '2>&1'; do
    for form in "$G $r push origin %s" "$G push $r origin %s"; do
      [ "$form" != "$G &>o push origin %s" ] || continue
      for pair in "$VBN:$BAD" "$BMP:main"; do
        gate="${pair%%:*}"
        # shellcheck disable=SC2059
        cmd=$(printf "$form" "${pair#*:}")
        fb_total=$((fb_total + 1))
        got=$(gate_rc "$BASE_HOOKS" "$gate" "$cmd")
        if [ "$got" = 0 ]; then
          fb_miss=$((fb_miss + 1))
        else
          fail "fail-before: base already blocks (${gate%.sh} rc=$got): $cmd"
        fi
      done
    done
  done
  if [ "$fb_miss" -eq "$fb_total" ]; then
    pass "fail-before: ${fb_miss} of ${fb_total} block cases pass on base"
  fi
else
  echo "NOTE: skip fail-before: ${fb_note}"
fi

# Timing: the word walk stays linear for words separated by blanks. Time
# the extractor on N and 2N plain words. The 2N run must finish within 3
# times the N run plus 0.5 seconds. The old quadratic walk took 4 times as
# long for each doubling.
TIMEFORMAT=%R
long_secs() {
  local n="$1" many cmd
  many=$(printf -- ' -v%.0s' $(seq "$n"))
  cmd="$G >o push$many origin $GOOD"
  { time core "$cmd" >/dev/null; } 2>&1 | tail -n 1
}
t1=$(long_secs 2000)
t2=$(long_secs 4000)
limit=$(awk -v a="$t1" 'BEGIN { printf "%.2f", a * 3 + 0.5 }')
if awk -v t="$t2" -v l="$limit" 'BEGIN { exit !(t <= l) }'; then
  pass "linear time: 4000 words ${t2}s, 2000 words ${t1}s, limit ${limit}s"
else
  fail "linear time: 4000 words ${t2}s is over ${limit}s (2000 words ${t1}s)"
fi
got=$(core "$G >o push$(printf -- ' -v%.0s' $(seq 4000)) origin $BAD")
if [ "$got" = "$BAD" ]; then
  pass "long push still reads the ref"
else
  fail "long push still reads the ref (got '$got')"
fi

echo "TOTAL $PASS passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
