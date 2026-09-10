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
  if [ "$expected" = blocked ] && [ "$rc" -eq 2 ] && printf '%s' "$output" | grep -q 'review-class agent is read-only'; then
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
run_case 'git status remains available' 'git status --short' allowed
run_case 'git diff remains available' 'git diff --check' allowed
run_case 'quoted prose is not a mutation' "printf '%s\\n' 'git commit is forbidden'" allowed
run_case 'heredoc review prose is not a mutation' $'cat <<EOF > /tmp/review-body\nDo not run git commit during review.\nEOF' allowed

rm -f "$TMP/.claude/session/active-reviewer"
run_case 'without active review mutations are unchanged' 'git commit -m "orchestrator work"' allowed

echo 'PASS: all review mutation cases'
