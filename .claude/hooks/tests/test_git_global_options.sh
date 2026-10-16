#!/bin/bash
# Presence, ref extraction, and -C retargeting for git global options.
# Covers me2resh/apexyard#1730 and #1731.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$ROOT/.claude/hooks/_lib-git-global.sh"
HOOKS="$ROOT/.claude/hooks"

# shellcheck disable=SC1090
. "$LIB"

fail=0
check() {
  local name="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    echo "PASS $name"
  else
    echo "FAIL $name want=$(printf %q "$want") got=$(printf %q "$got")" >&2
    fail=1
  fi
}

has() {
  if command_has_git_subcommand "$1" "$2"; then
    printf yes
  else
    printf no
  fi
}

check stash-push no "$(has "git stash push -m wip" push)"
check grep-push no "$(has "git log --grep=push" push)"
check log-push no "$(has "git log --oneline push" push)"
check push-helper no "$(has "git push-helper origin" push)"
check mygit no "$(has "mygit push origin main" push)"
check commitment no "$(has "git commitment" commit)"
check plain-push yes "$(has "git push origin main" push)"
check dash-c-push yes "$(has "git -C /repo push origin main" push)"
check dash-c-quoted yes "$(has "git -C \"/some dir/repo\" push origin main" push)"
check dash-c-single yes "$(has "git -C '/some dir/repo' push origin main" push)"
check dash-small-c yes "$(has "git -c core.quotepath=off commit -m x" commit)"
check git-dir yes "$(has "git --git-dir=/some/repo/.git push origin main" push)"
check git-dir-sp yes "$(has "git --git-dir /some/repo/.git push origin main" push)"
check work-tree yes "$(has "git --work-tree /some/repo push origin main" push)"
check no-pager yes "$(has "git --no-pager push origin main" push)"
check quoted-text yes "$(has "echo 'run git push later'" push)"
check cd-and yes "$(has "cd /some/repo && git -C /other commit -m x" commit)"

git_prepare_invocation "git -C /repo -c core.quotepath=off commit -m x" commit ""
check dash-c-value /repo "$GIT_DASH_C"
check replay-flag -C "${GIT_REPLAY_ARGS[0]:-}"
check replay-dir /repo "${GIT_REPLAY_ARGS[1]:-}"

args=$(git_push_args "git -C /repo push origin feature/GH-1-x")
check push-args " origin feature/GH-1-x" "$args"

args=$(git_push_args "git -C \"/some dir\" push origin main")
check quoted-push-args " origin main" "$args"

c=$(git_invocation_dash_c "git -C /other status && git -C /real -c a=b commit" commit)
check bound-commit /real "$c"

c=$(git_invocation_dash_c "git commit -m x && git -C /other log" commit)
check not-later "" "$c"

c=$(git_invocation_dash_c "cd /real && git -C /other status && git commit" commit)
check cd-not-other "" "$c"

git_prepare_invocation "git -C rel/repo commit -m x" commit "/base"
check relative-c /base/rel/repo "$GIT_DASH_C"

pat=$(git_subcommand_payload_pattern commit)
printf '%s\n' '{"command":"git -C /tmp/repo commit -m x"}' | grep -qE "$pat" \
  && echo PASS payload-dash-c || { echo FAIL payload-dash-c >&2; fail=1; }
printf '%s\n' '{"command":"git commitment"}' | grep -qE "$pat" \
  && { echo FAIL payload-commitment >&2; fail=1; } || echo PASS payload-commitment
printf '%s\n' '{"command":"git commit -m x"}' | grep -qE "$pat" \
  && echo PASS payload-plain || { echo FAIL payload-plain >&2; fail=1; }
printf '%s\n' '{"command":"git --git-dir /some/repo/.git commit"}' | grep -qE "$pat" \
  && echo PASS payload-git-dir || { echo FAIL payload-git-dir >&2; fail=1; }

# Secret scan reads the -C repository, not the hook process directory.
sb=$(mktemp -d)
other=$(mktemp -d)
git -C "$sb" init -q
git -C "$sb" config user.email test@example.com
git -C "$sb" config user.name test
key_name='api_key'
printf '%s = "%s"\n' "$key_name" 'abcdefghijklmnopqr' > "$sb/secret.txt"
git -C "$sb" add secret.txt
payload=$(jq -nc --arg command "git -C $sb commit -m \"fix: add secret\"" --arg cwd "$other" \
  '{tool_input:{command:$command,cwd:$cwd},cwd:$cwd}')
set +e
printf '%s' "$payload" | bash "$HOOKS/check-secrets.sh" >/tmp/git-global-secrets.out 2>/tmp/git-global-secrets.err
rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -q 'hardcoded secrets' /tmp/git-global-secrets.err; then
  echo PASS secrets-dash-c
else
  echo "FAIL secrets-dash-c rc=$rc" >&2
  cat /tmp/git-global-secrets.err >&2
  fail=1
fi

# A bad subject with a global option is rejected.
payload=$(jq -nc --arg command "git -C $sb commit -m \"bad message without a type\"" \
  '{tool_input:{command:$command}}')
set +e
printf '%s' "$payload" | bash "$HOOKS/validate-commit-format.sh" >/dev/null 2>/tmp/git-global-fmt.err
rc=$?
set -e
if [ "$rc" -eq 2 ]; then
  echo PASS format-bad-dash-c
else
  echo "FAIL format-bad-dash-c rc=$rc" >&2
  cat /tmp/git-global-fmt.err >&2
  fail=1
fi

payload=$(jq -nc --arg command "git -c core.quotepath=off commit -m \"fix: probe message\"" \
  '{tool_input:{command:$command}}')
set +e
printf '%s' "$payload" | bash "$HOOKS/validate-commit-format.sh" >/dev/null 2>/tmp/git-global-fmt.err
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo PASS format-good-dash-c
else
  echo "FAIL format-good-dash-c rc=$rc" >&2
  cat /tmp/git-global-fmt.err >&2
  fail=1
fi

# Push ref extraction ignores the -C value.
# shellcheck disable=SC1090
. "$HOOKS/_lib-extract-push-ref.sh"
ref=$(extract_push_ref "git -C $sb push origin feature/GH-1-x")
check extract-ref feature/GH-1-x "$ref"
ref=$(extract_push_ref "git -C $sb push origin HEAD:refs/heads/fix/no-ticket-name")
check extract-dst fix/no-ticket-name "$ref"

# Protected-branch and branch-name gates must see git -C push.
feature=$(mktemp -d)
protected=$(mktemp -d)
git -C "$feature" init -q -b feature/GH-1-x
git -C "$feature" config user.email test@example.com
git -C "$feature" config user.name test
git -C "$feature" commit -q --allow-empty -m "fix: init"
git -C "$protected" init -q -b dev
git -C "$protected" config user.email test@example.com
git -C "$protected" config user.name test
git -C "$protected" commit -q --allow-empty -m "fix: init"
run_hook() {
  local hook="$1" command="$2" cwd="$3"
  local payload rc
  payload=$(jq -nc --arg command "$command" --arg cwd "$cwd" \
    '{tool_input:{command:$command,cwd:$cwd},cwd:$cwd}')
  set +e
  printf '%s' "$payload" | (cd "$cwd" && bash "$hook") >/tmp/git-global-hook.out 2>/tmp/git-global-hook.err
  rc=$?
  set -e
  printf '%s' "$rc"
}
rc=$(run_hook "$HOOKS/block-main-push.sh" "git -C $feature push origin main" "$other")
if [ "$rc" -eq 2 ]; then
  echo PASS block-protected-dash-c
else
  echo "FAIL block-protected-dash-c rc=$rc" >&2
  cat /tmp/git-global-hook.err >&2
  fail=1
fi
rc=$(run_hook "$HOOKS/block-main-push.sh" "git -C $feature push origin feature/GH-1-x" "$other")
if [ "$rc" -eq 0 ]; then
  echo PASS block-feature-dash-c
else
  echo "FAIL block-feature-dash-c rc=$rc" >&2
  cat /tmp/git-global-hook.err >&2
  fail=1
fi
rc=$(run_hook "$HOOKS/block-main-push.sh" "git stash push -m wip" "$other")
if [ "$rc" -eq 0 ]; then
  echo PASS block-stash-push
else
  echo "FAIL block-stash-push rc=$rc" >&2
  cat /tmp/git-global-hook.err >&2
  fail=1
fi
rc=$(run_hook "$HOOKS/block-main-push.sh" "git -C $feature push" "$protected")
if [ "$rc" -eq 0 ]; then
  echo PASS block-bare-dash-c
else
  echo "FAIL block-bare-dash-c rc=$rc" >&2
  cat /tmp/git-global-hook.err >&2
  fail=1
fi
rc=$(run_hook "$HOOKS/validate-branch-name.sh" "git -C $feature push origin fix/no-ticket-name" "$other")
if [ "$rc" -eq 2 ]; then
  echo PASS branch-bad-dash-c
else
  echo "FAIL branch-bad-dash-c rc=$rc" >&2
  cat /tmp/git-global-hook.err >&2
  fail=1
fi
rc=$(run_hook "$HOOKS/validate-branch-name.sh" "git -C $feature push origin feature/GH-1-x" "$other")
if [ "$rc" -eq 0 ]; then
  echo PASS branch-good-dash-c
else
  echo "FAIL branch-good-dash-c rc=$rc" >&2
  cat /tmp/git-global-hook.err >&2
  fail=1
fi
rc=$(run_hook "$HOOKS/validate-branch-name.sh" "git log --grep=push" "$other")
if [ "$rc" -eq 0 ]; then
  echo PASS branch-grep-push
else
  echo "FAIL branch-grep-push rc=$rc" >&2
  cat /tmp/git-global-hook.err >&2
  fail=1
fi

rm -rf "$sb" "$other" "$feature" "$protected"
rm -f /tmp/git-global-secrets.out /tmp/git-global-secrets.err /tmp/git-global-fmt.err

if [ "$fail" -ne 0 ]; then
  echo FAIL
  exit 1
fi
echo PASS
exit 0
