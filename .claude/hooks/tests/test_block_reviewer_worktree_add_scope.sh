#!/bin/bash
# Issue #1509: during an active review, git worktree add to a path outside the
# ops fork and managed workspace is allowed. The same command targeting a path
# inside the ops fork or workspace/ stays blocked.
#
# Each case below fails against the pre-#1509 hook (fail-before is verified
# outside this file against a copy kept outside the worktree). This file never
# asserts fail-before itself.
set -u

SRC_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOK_SOURCE=${BRRM_HOOK_SOURCE:-$SRC_ROOT/.claude/hooks/block-reviewer-repo-mutation.sh}
export GIT_CEILING_DIRECTORIES="${GIT_CEILING_DIRECTORIES:-/}"

TMP_RAW=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-1509-wt-scope.XXXXXX")
TMP=$(cd "$TMP_RAW" && pwd -P)
trap 'rm -rf "$TMP_RAW"' EXIT

ops="$TMP/ops"
outside="$TMP/outside-wt"
mkdir -p "$ops/.claude/session" "$ops/.claude/hooks" "$ops/workspace/demo" "$TMP/scratch"
touch "$ops/.apexyard-fork"
: > "$ops/onboarding.yaml"
: > "$ops/apexyard.projects.yaml"
printf '%s\n' 'sample/project#1509:rex' > "$ops/.claude/session/active-reviewer"

cp "$HOOK_SOURCE" "$ops/.claude/hooks/block-reviewer-repo-mutation.sh"
for lib in _lib-strip-heredoc.sh _lib-path-resolve.sh _lib-review-markers.sh; do
  if [ -f "$SRC_ROOT/.claude/hooks/$lib" ]; then
    cp "$SRC_ROOT/.claude/hooks/$lib" "$ops/.claude/hooks/$lib"
  fi
done

PASS=0
FAIL=0

run_case() {
  local name="$1" command="$2" expected="$3"
  local input output rc
  input=$(jq -cn --arg command "$command" '{tool_input:{command:$command}}')
  output=$(
    cd "$ops" || exit 1
    printf '%s' "$input" | env -u CLAUDE_CODE_SESSION_ID APEXYARD_REVIEW_OPS_ROOT="$ops" \
      /bin/bash "$ops/.claude/hooks/block-reviewer-repo-mutation.sh" 2>&1
  )
  rc=$?
  if [ "$expected" = blocked ] && [ "$rc" -eq 2 ] && printf '%s' "$output" | grep -q 'BLOCKED:'; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  elif [ "$expected" = allowed ] && [ "$rc" -eq 0 ] && ! printf '%s' "$output" | grep -q 'BLOCKED:'; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (rc=$rc expected=$expected output=$output)" >&2
    FAIL=$((FAIL + 1))
  fi
}

# AC1: docs allow worktree add outside governed trees. Pre-#1509 the whole-
# command allow regex missed `cd …&&git` (no spaces), so MUTATING treated
# `worktree add` as `git add` and blocked.
run_case '#1509 AC allow: cd scratch&&git worktree add outside path' \
  "cd $TMP/scratch&&git worktree add $outside abcdef1234567890" allowed

# AC1b: compound command after worktree add also missed the old ^…$ allow regex.
run_case '#1509 AC allow: outside worktree add in a compound command' \
  "git worktree add $outside abcdef1234567890 && true" allowed

# AC2: path inside the ops fork must stay blocked (pre-#1509 blanket-allowed).
run_case '#1509 AC block: git worktree add inside ops fork' \
  "git worktree add $ops/review-wt abcdef1234567890" blocked

# AC3: path inside managed workspace must stay blocked (pre-#1509 blanket-allowed).
run_case '#1509 AC block: git worktree add inside managed workspace' \
  "git worktree add $ops/workspace/demo/review-wt abcdef1234567890" blocked

# Review of the first #1509 build: a scoped allow must never allow the rest
# of a compound command, and every worktree add segment is checked.
run_case '#1509 block: outside worktree add then git push' \
  "git worktree add $outside abcdef1234567890 && git push origin x" blocked
run_case '#1509 block: outside worktree add then git commit' \
  "git worktree add $outside abcdef1234567890; git commit -m x" blocked
run_case '#1509 block: git commit then outside worktree add' \
  "git commit -m x; git worktree add $outside abcdef1234567890" blocked
run_case '#1509 block: second worktree add inside the ops fork' \
  "git worktree add $outside abcdef1234567890 && git worktree add $ops/inner abcdef1234567890" blocked
run_case '#1509 block: --track takes no value, so the path is still checked' \
  "cd $TMP/scratch && git worktree add --track $ops/inner main" blocked
run_case '#1509 block: relative path that resolves into the ops fork' \
  "cd $TMP/scratch && git worktree add ../ops/inner abcdef1234567890" blocked
run_case '#1509 block: git -c option before worktree add' \
  "git -c core.hooksPath=/x worktree add $outside abcdef1234567890" blocked
run_case '#1509 block: environment prefix before worktree add' \
  "GIT_CONFIG_COUNT=1 git worktree add $outside abcdef1234567890" blocked
run_case '#1509 block: expansion in a worktree add segment' \
  "git worktree add $outside \$(git push) " blocked
run_case '#1509 allow: git -C scratch worktree add outside path' \
  "git -C $TMP/scratch worktree add $outside abcdef1234567890" allowed
run_case '#1509 allow: worktree add then run tests in it' \
  "cd $TMP/scratch && git worktree add $outside abcdef1234567890 && cd $outside && bash run.sh" allowed

# Review of PR #1518: a lone `&` hid the next command from later checks,
# and the path parser could read the wrong word.
run_case '#1509 block: outside worktree add then & git push' \
  "git worktree add $outside abcdef1234567890 & git push origin x" blocked
run_case '#1509 block: outside worktree add then |& git push' \
  "git worktree add $outside abcdef1234567890 |& git push origin x" blocked
run_case '#1509 block: grouped short options -fb' \
  "cd $TMP/scratch && git worktree add -fb x $ops/inner abcdef1234567890" blocked
run_case '#1509 block: abbreviated long option --reas' \
  "git worktree add --lock --reas $TMP/ok $ops/inner abcdef1234567890" blocked
run_case '#1509 block: relative path after cd -' \
  "cd $ops && cd $TMP/scratch && cd - && git worktree add inner abcdef1234567890" blocked
run_case '#1509 allow: listed option -f' \
  "git worktree add -f $outside abcdef1234567890" allowed
run_case '#1509 allow: listed option --detach' \
  "git worktree add --detach $outside abcdef1234567890" allowed

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
