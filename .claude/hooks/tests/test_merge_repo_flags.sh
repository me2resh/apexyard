#!/bin/bash
# Regression for #1588: mixed repo spellings must not split merge targets.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/.claude/hooks"
cp "$ROOT"/_lib-*.sh "$SB/.claude/hooks/"
for gate in block-unreviewed-merge block-merge-on-red-ci require-design-review-for-ui require-architecture-review; do
  cp "$ROOT/$gate.sh" "$SB/.claude/hooks/"
done
if [ -n "${LIB_PR_OVERRIDE:-}" ]; then
  cp "$LIB_PR_OVERRIDE" "$SB/.claude/hooks/_lib-extract-pr.sh"
fi
. "$SB/.claude/hooks/_lib-extract-pr.sh"
PASS=0
FAIL=0
check_repo() {
  local cmd="$1" want="$2" got
  got=$(extract_explicit_repo_from_command "$cmd")
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1))
  else
    echo "FAIL: $cmd: repo=$got, expected $want"
    FAIL=$((FAIL+1))
  fi
}
for a in '-R ' '--repo ' '--repo=' '-R='; do
  check_repo "gh pr merge 42 ${a}owner/repo" owner/repo
  for b in '-R ' '--repo ' '--repo=' '-R='; do
    check_repo "gh pr merge 42 ${a}owner/repo ${b}owner/repo" owner/repo
    if command -v has_conflicting_repo_flags >/dev/null 2>&1 &&
        ! has_conflicting_repo_flags "gh pr merge 42 ${a}owner/repo ${b}owner/repo"; then
      PASS=$((PASS+1))
    else
      echo "FAIL: identical repo flags flagged as conflicting: $a / $b"
      FAIL=$((FAIL+1))
    fi
    cmd="gh pr merge 42 ${a}other/repo ${b}owner/repo"
    check_repo "$cmd" owner/repo
    input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
    for gate in block-unreviewed-merge block-merge-on-red-ci require-design-review-for-ui require-architecture-review; do
      stderr=$(cd "$SB" && APEXYARD_OPS_DISABLE_PIN=1 bash ".claude/hooks/$gate.sh" <<< "$input" 2>&1 >/dev/null)
      rc=$?
      if [ "$rc" = 2 ] && echo "$stderr" | grep -q 'BLOCKED: merge command has conflicting repo flags'; then
        PASS=$((PASS+1))
      else
        echo "FAIL: $gate ($a / $b): rc=$rc, stderr=$stderr"
        FAIL=$((FAIL+1))
      fi
    done
  done
done
# Separate merge statements keep their own repo declarations (#1568).
if command -v has_conflicting_repo_flags >/dev/null 2>&1 &&
    ! has_conflicting_repo_flags 'gh pr merge 5 -R a/a; gh pr merge 7 --repo=b/b'; then
  PASS=$((PASS+1))
else
  echo "FAIL: separate merge statements counted as conflicting flags"
  FAIL=$((FAIL+1))
fi
check_repo 'tracker_pr_merge owner/repo 42 squash' owner/repo
check_repo 'glab mr merge 42 -R=owner/repo' owner/repo
check_repo 'echo --repo=other/repo; gh pr merge 42 -R owner/repo' owner/repo
echo "PASS: $PASS FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
