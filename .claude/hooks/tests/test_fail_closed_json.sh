#!/bin/bash
# Regression tests for #1152 slice 1: jq failure must not turn covered writes
# into silent passes.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/jq" <<'EOF'
#!/bin/bash
exit 127
EOF
chmod +x "$TMP/jq"

PASS=0; FAIL=0
check() {
  local name="$1" hook="$2" payload="$3" rc
  rc=$(printf '%s' "$payload" | PATH="$TMP:$PATH" bash "$ROOT/$hook" >/dev/null 2>&1; echo $?)
  if [ "$rc" -eq 2 ]; then echo "PASS [$name]"; PASS=$((PASS+1));
  else echo "FAIL [$name] expected rc=2 got rc=$rc" >&2; FAIL=$((FAIL+1)); fi
}

check "secrets commit" .claude/hooks/check-secrets.sh \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'
check "protected push" .claude/hooks/block-main-push.sh \
  '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
check "private tracker write" .claude/hooks/block-private-refs-in-public-repos.sh \
  '{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo me2resh/apexyard"}}'
# #1206 H1: gh pr review and gh pr merge were absent from this degraded-path
# regex, so a broken jq silently passed exactly the two shapes #1206 added.
check "private tracker write: gh pr review" .claude/hooks/block-private-refs-in-public-repos.sh \
  '{"tool_name":"Bash","tool_input":{"command":"gh pr review 5 --repo me2resh/apexyard"}}'
check "private tracker write: gh pr merge" .claude/hooks/block-private-refs-in-public-repos.sh \
  '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 5 --repo me2resh/apexyard"}}'
# #1206: gh api writes must also fail closed when jq cannot parse the payload.
check "private tracker write: gh api issues" .claude/hooks/block-private-refs-in-public-repos.sh \
  '{"tool_name":"Bash","tool_input":{"command":"gh api repos/me2resh/apexyard/issues -f body=leak"}}'
# #1206 H2: the wrapper shapes must fail closed here too, for the same reason.
check "private tracker write: tracker_review_submit wrapper" .claude/hooks/block-private-refs-in-public-repos.sh \
  '{"tool_name":"Bash","tool_input":{"command":"tracker_review_submit \"me2resh/apexyard\" \"5\" \"comment\""}}'
check "private tracker write: tracker_pr_merge wrapper" .claude/hooks/block-private-refs-in-public-repos.sh \
  '{"tool_name":"Bash","tool_input":{"command":"tracker_pr_merge \"me2resh/apexyard\" \"5\" \"squash\""}}'
check "private tracker write: tracker_create wrapper" .claude/hooks/block-private-refs-in-public-repos.sh \
  '{"tool_name":"Bash","tool_input":{"command":"tracker_create \"me2resh/apexyard\" \"a title\""}}'
check "active Edit" .claude/hooks/require-active-ticket.sh \
  '{"tool_name":"Edit","tool_input":{"file_path":"src/app.ts"}}'
check "active Bash write" .claude/hooks/require-active-ticket.sh \
  '{"tool_name":"Bash","tool_input":{"command":"printf x > src/app.ts"}}'

read_rc=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | PATH="$TMP:$PATH" bash "$ROOT/.claude/hooks/require-active-ticket.sh" >/dev/null 2>&1; echo $?)
if [ "$read_rc" -eq 0 ]; then echo "PASS [active Bash read]"; PASS=$((PASS+1));
else echo "FAIL [active Bash read] expected rc=0 got rc=$read_rc" >&2; FAIL=$((FAIL+1)); fi

check "staging" .claude/hooks/block-git-add-all.sh \
  '{"tool_name":"Bash","tool_input":{"command":"git add -A"}}'
check "onboarding" .claude/hooks/block-onboarding-in-git.sh \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'
check "branch" .claude/hooks/validate-branch-name.sh \
  '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
check "commit-format" .claude/hooks/validate-commit-format.sh \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'

echo "fail-closed JSON smoke tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
