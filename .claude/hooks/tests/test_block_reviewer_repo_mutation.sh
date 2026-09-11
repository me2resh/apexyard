#!/bin/bash
# Regression tests for #1233: review-class agents stay read-only while the
# active-reviewer marker is present.
set -u

SRC_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOK="$SRC_ROOT/.claude/hooks/block-reviewer-repo-mutation.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-review-mutation.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude/session" "$TMP/.claude/hooks"
touch "$TMP/.apexyard-fork"
git -C "$TMP" init -q
cp "$HOOK" "$TMP/.claude/hooks/"
cp "$SRC_ROOT/.claude/hooks/_lib-strip-heredoc.sh" "$TMP/.claude/hooks/"
printf '%s\n' 'me2resh/apexyard#1233:rex' > "$TMP/.claude/session/active-reviewer"

run_case() {
  local name="$1" command="$2" expected="$3"
  local input output rc
  input=$(jq -cn --arg command "$command" '{tool_input:{command:$command}}')
  output=$(cd "$TMP" && printf '%s' "$input" | "$TMP/.claude/hooks/block-reviewer-repo-mutation.sh" 2>&1)
  rc=$?
  if [ "$expected" = blocked ] && [ "$rc" -eq 2 ] && printf '%s' "$output" | grep -q 'BLOCKED:'; then
    echo "PASS: $name"
  elif [ "$expected" = allowed ] && [ "$rc" -eq 0 ]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (rc=$rc output=$output)" >&2
    return 1
  fi
}

run_case 'git commit is blocked' 'git commit -m "reviewed"' blocked
run_case 'git push is blocked' 'cd repo && git push origin fix/1233-review-agent-read-only' blocked
run_case 'git restore is blocked' 'git -C repo restore tracked.md' blocked
run_case 'git stash is blocked' 'git stash push -m save' blocked
run_case 'git commit before separator is blocked' 'git commit;' blocked
run_case 'git push before separator is blocked' 'git push; echo done' blocked
run_case 'newline-separated git mutation is blocked' $'echo review\ngit commit' blocked
run_case 'git tag is blocked' 'git tag release-candidate' blocked
run_case 'git update-ref is blocked' 'git update-ref refs/heads/reviewed HEAD' blocked
run_case 'git fetch is blocked' 'git fetch origin' blocked
run_case 'git checkout-index is blocked' 'git checkout-index --all' blocked
run_case 'git apply is blocked' 'git apply fix.patch' blocked
run_case 'git submodule update is blocked' 'git submodule update --init' blocked
run_case 'git worktree add remains available for orchestration' 'git worktree add ../review-copy HEAD' allowed
run_case 'git worktree add with branch remains available' 'git worktree add -b reviewer-copy ../review-copy HEAD' allowed
run_case 'git worktree lock is blocked' 'git worktree lock ../review-copy' blocked
run_case 'git notes is blocked' 'git notes add -m note HEAD' blocked
run_case 'git revert is blocked' 'git revert HEAD' blocked
run_case 'git am is blocked' 'git am review.patch' blocked
run_case 'git bisect is blocked' 'git bisect start' blocked
run_case 'git config is blocked' 'git config user.name Reviewer' blocked
run_case 'git reflog is blocked' 'git reflog expire --all' blocked
run_case 'git replace is blocked' 'git replace HEAD HEAD^' blocked
run_case 'git sparse-checkout is blocked' 'git sparse-checkout set src' blocked
run_case 'git filter-branch is blocked' 'git filter-branch -- --all' blocked
run_case 'git gc is blocked' 'git gc' blocked
run_case 'git init is blocked' 'git init' blocked
run_case 'git status remains available' 'git status --short' allowed
run_case 'git diff remains available' 'git diff --check' allowed
run_case 'git rev-parse remains available' 'git rev-parse HEAD' allowed
run_case 'git remote get-url remains available' 'git remote get-url origin' allowed
run_case 'git remote add is blocked' 'git remote add backup https://example.invalid/repo.git' blocked
run_case 'git branch show-current remains available' 'git branch --show-current' allowed
run_case 'git config get remains available' 'git config --get user.name' allowed
run_case 'git reflog show remains available' 'git reflog -1' allowed
run_case 'git notes show remains available' 'git notes show HEAD' allowed
run_case 'git worktree list remains available' 'git worktree list' allowed
run_case 'git branch create is blocked' 'git branch reviewer-copy' blocked
run_case 'git config write is blocked' 'git config user.name Reviewer' blocked
run_case 'git notes add is blocked' 'git notes add -m note HEAD' blocked
run_case 'git worktree remove is blocked' 'git worktree remove ../review-copy' blocked
run_case 'git submodule status remains available' 'git submodule status' allowed
run_case 'git sparse-checkout list remains available' 'git sparse-checkout list' allowed
run_case 'git format-patch stdout remains available' 'git format-patch --stdout HEAD~1..HEAD' allowed
run_case 'git fast-export remains available' 'git fast-export HEAD' allowed
run_case 'git rerere status remains available' 'git rerere status' allowed
run_case 'git maintenance list remains available' 'git maintenance list' allowed
run_case 'git C config get remains available' 'git -C repo config --get user.name' allowed
run_case 'git format-patch file write is blocked' 'git format-patch HEAD~1..HEAD' blocked
run_case 'git submodule update remains blocked' 'git submodule update --init' blocked
run_case 'git fast-export marks write is blocked' 'git fast-export --export-marks=marks.txt HEAD' blocked
run_case 'git archive output write is blocked' 'git archive --output=archive.tar HEAD' blocked
run_case 'git archive short output write is blocked' 'git archive -o archive.tar HEAD' blocked
run_case 'git archive short equals output is blocked' 'git archive -o=archive.tar HEAD' blocked
run_case 'git C archive output write is blocked' 'git -C repo archive -o archive.tar HEAD' blocked
run_case 'git archive attached short output is blocked' 'git archive -oarchive.tar HEAD' blocked
run_case 'git C archive attached short output is blocked' 'git -C repo archive -oarchive.tar HEAD' blocked
run_case 'quoted prose is not a mutation' "printf '%s\\n' 'git commit is forbidden'" allowed
run_case 'heredoc review prose is not a mutation' $'cat <<EOF > /tmp/review-body\nDo not run git commit during review.\nEOF' allowed

rm -f "$TMP/.claude/session/active-reviewer"
run_case 'without active review mutations are unchanged' 'git commit -m "orchestrator work"' allowed

echo 'PASS: all review mutation cases'
