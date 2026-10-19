#!/bin/bash
# Merge-matcher regressions for #1761 (#1757, #1758, #1760).
#
# Step 1: a literal merge is not a variable target, under the system awk
# and under mawk when mawk is installed. The argv -c window stays 200
# characters. A variable merge and a shell -c wrapper still block.

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

check_window "bsd awk"
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
