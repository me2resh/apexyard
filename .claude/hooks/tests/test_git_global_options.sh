#!/bin/bash
# Presence, ref extraction, and -C retargeting for git global options.
# Covers me2resh/apexyard#1730 and #1731.

set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
export CLAUDE_CODE_SESSION_ID=marker-test

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$ROOT/.claude/hooks/_lib-git-global.sh"
HOOKS="$ROOT/.claude/hooks"

# shellcheck disable=SC1090
. "$LIB"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp" "${sb:-}" "${other:-}" "${feature:-}" "${protected:-}"' EXIT
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

# Redirections must not become background-job separators.
for cmd in 'npm test 2>&1 | tail -5 && git log' 'git status 2>&1; git log' 'echo note >&2; git log' 'make &> out.log && git log' 'echo note 1>&2; git log' 'make &>> out.log && git log' 'cat <&0; git log'; do
  if git_prepare_invocation "$cmd" log "$PWD"; then rc=0; else rc=$?; fi
  check "redirect-$cmd" 0 "$rc"
done
if git_prepare_invocation 'sleep 1 & git push' push "$PWD"; then rc=0; else rc=$?; fi
check background-fails-closed 1 "$rc"

# Check tilde handling without a repository probe.
for option in --git-dir --work-tree; do
  git_prepare_invocation "git $option=~/x commit" commit /base
  check "tilde-equals-$option" "$option=/base/./~/x" "${GIT_REPLAY_ARGS[2]}"
  git_prepare_invocation "git $option ~/x commit" commit /base
  check "tilde-word-$option" "$option=$HOME/x" "${GIT_REPLAY_ARGS[2]}"
  git_prepare_invocation "git $option='~/x' commit" commit /base
  check "tilde-quoted-$option" "$option=/base/./~/x" "${GIT_REPLAY_ARGS[2]}"
done
git_prepare_invocation 'git -C ~/x commit' commit /base
check tilde-dash-c "$HOME/x" "$GIT_DASH_C"
git_prepare_invocation "git -C '~/x' commit" commit /base
check tilde-quoted-dash-c /base/./~/x "$GIT_DASH_C"

pat=$(git_subcommand_payload_pattern commit)
printf '%s\n' '{"command":"git -C /tmp/repo commit -m x"}' | grep -qE "$pat" \
  && echo PASS payload-dash-c || { echo FAIL payload-dash-c >&2; fail=1; }
printf '%s\n' '{"command":"git commitment"}' | grep -qE "$pat" \
  && { echo FAIL payload-commitment-not-commit >&2; fail=1; } || echo PASS payload-commitment-not-commit
printf '%s\n' '{"command":"git -C \"a b\" commit -m x"}' | grep -qE "$pat" \
  && echo PASS payload-quoted-dash-C || { echo FAIL payload-quoted-dash-C >&2; fail=1; }
# #1748 row 5: single-quoted -C / --git-dir values with a space (no jq).
printf '%s\n' "{\"command\":\"git -C 'a b' commit -m x\"}" | grep -qE "$pat" \
  && echo PASS payload-single-quoted-dash-C || { echo FAIL payload-single-quoted-dash-C >&2; fail=1; }
printf '%s\n' "{\"command\":\"git --git-dir='a b/.git' commit -m x\"}" | grep -qE "$pat" \
  && echo PASS payload-single-quoted-git-dir || { echo FAIL payload-single-quoted-git-dir >&2; fail=1; }
printf '%s\n' "{\"command\":\"git -C 'a b' status\"}" | grep -qE "$pat" \
  && { echo FAIL payload-single-quoted-status-not-commit >&2; fail=1; } || echo PASS payload-single-quoted-status-not-commit
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
printf '%s' "$payload" | bash "$HOOKS/check-secrets.sh" >"$test_tmp/secrets.out" 2>"$test_tmp/secrets.err"
rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -q 'hardcoded secrets' "$test_tmp/secrets.err"; then
  echo PASS secrets-dash-c
else
  echo "FAIL secrets-dash-c rc=$rc" >&2
  cat "$test_tmp/secrets.err" >&2
  fail=1
fi

# A callback must not consume the remaining invocation prefixes.
read_stdin_callback() {
  cat >/dev/null
  printf '%s\n' "$GIT_DASH_C" >> "$test_tmp/visited"
  if [ -n "${scan_secret:-}" ]; then
    git_target diff --cached | grep -q 'abcdefghijklmnopqr' && return 2
  fi
  return 0
}
payload=$(jq -nc --arg command "git -C $other commit; git -C $other commit; git -C $sb commit" \
  --arg cwd "$other" '{tool_input:{command:$command},cwd:$cwd}')
git_visit_invocations read_stdin_callback block "$payload" commit
check stdin-all-visited 3 "$(wc -l < "$test_tmp/visited" | tr -d ' ')"
scan_secret=1
if git_visit_invocations read_stdin_callback block "$payload" commit; then
  rc=0
else
  rc=$?
fi
check stdin-third-secret-blocks 2 "$rc"
check stdin-secret-all-visited 6 "$(wc -l < "$test_tmp/visited" | tr -d ' ')"
unset scan_secret

# A bad subject with a global option is rejected.
payload=$(jq -nc --arg command "git -C $sb commit -m \"bad message without a type\"" \
  '{tool_input:{command:$command}}')
set +e
printf '%s' "$payload" | bash "$HOOKS/validate-commit-format.sh" >/dev/null 2>"$test_tmp/fmt.err"
rc=$?
set -e
if [ "$rc" -eq 2 ]; then
  echo PASS format-bad-dash-c
else
  echo "FAIL format-bad-dash-c rc=$rc" >&2
  cat "$test_tmp/fmt.err" >&2
  fail=1
fi

payload=$(jq -nc --arg command "git -c core.quotepath=off commit -m \"fix: probe message\"" \
  '{tool_input:{command:$command}}')
set +e
printf '%s' "$payload" | bash "$HOOKS/validate-commit-format.sh" >/dev/null 2>"$test_tmp/fmt.err"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo PASS format-good-dash-c
else
  echo "FAIL format-good-dash-c rc=$rc" >&2
  cat "$test_tmp/fmt.err" >&2
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
    '{tool_name:"Bash",tool_input:{command:$command,cwd:$cwd},cwd:$cwd}')
  set +e
  printf '%s' "$payload" | (cd "$cwd" && bash "$hook") >"$test_tmp/hook.out" 2>"$test_tmp/hook.err"
  rc=$?
  set -e
  printf '%s' "$rc"
}
rc=$(run_hook "$HOOKS/block-main-push.sh" "git -C $feature push origin main" "$other")
if [ "$rc" -eq 2 ]; then
  echo PASS block-protected-dash-c
else
  echo "FAIL block-protected-dash-c rc=$rc" >&2
  cat "$test_tmp/hook.err" >&2
  fail=1
fi
rc=$(run_hook "$HOOKS/block-main-push.sh" "git -C $feature push origin feature/GH-1-x" "$other")
if [ "$rc" -eq 0 ]; then
  echo PASS block-feature-dash-c
else
  echo "FAIL block-feature-dash-c rc=$rc" >&2
  cat "$test_tmp/hook.err" >&2
  fail=1
fi
rc=$(run_hook "$HOOKS/block-main-push.sh" "git stash push -m wip" "$other")
if [ "$rc" -eq 0 ]; then
  echo PASS block-stash-push
else
  echo "FAIL block-stash-push rc=$rc" >&2
  cat "$test_tmp/hook.err" >&2
  fail=1
fi
rc=$(run_hook "$HOOKS/block-main-push.sh" "git -C $feature push" "$protected")
if [ "$rc" -eq 0 ]; then
  echo PASS block-bare-dash-c
else
  echo "FAIL block-bare-dash-c rc=$rc" >&2
  cat "$test_tmp/hook.err" >&2
  fail=1
fi
rc=$(run_hook "$HOOKS/validate-branch-name.sh" "git -C $feature push origin fix/no-ticket-name" "$other")
if [ "$rc" -eq 2 ]; then
  echo PASS branch-bad-dash-c
else
  echo "FAIL branch-bad-dash-c rc=$rc" >&2
  cat "$test_tmp/hook.err" >&2
  fail=1
fi
rc=$(run_hook "$HOOKS/validate-branch-name.sh" "git -C $feature push origin feature/GH-1-x" "$other")
if [ "$rc" -eq 0 ]; then
  echo PASS branch-good-dash-c
else
  echo "FAIL branch-good-dash-c rc=$rc" >&2
  cat "$test_tmp/hook.err" >&2
  fail=1
fi
rc=$(run_hook "$HOOKS/validate-branch-name.sh" "git log --grep=push" "$other")
if [ "$rc" -eq 0 ]; then
  echo PASS branch-grep-push
else
  echo "FAIL branch-grep-push rc=$rc" >&2
  cat "$test_tmp/hook.err" >&2
  fail=1
fi

# Give protected-commit probes existing history.
seed_history() {
  local repo="$1" tree commit
  tree=$(git -C "$repo" mktree </dev/null)
  commit=$(git -C "$repo" -c user.name=Test -c user.email=test@example.invalid commit-tree "$tree" -m fixture)
  git -C "$repo" update-ref HEAD "$commit"
}
# Use real repositories for each review probe.
git -C "$sb" symbolic-ref HEAD refs/heads/main
seed_history "$sb"
check b1-secrets-plain 2 "$(run_hook "$HOOKS/check-secrets.sh" "git -C $feature commit -m 'fix: first' && git commit -m 'fix: second'" "$sb")"
check b1-protected-commit 2 "$(run_hook "$HOOKS/block-main-push.sh" "git -C $feature commit -m 'fix: first' && git commit -m 'fix: second'" "$sb")"
check b1-secrets-unquoted 2 "$(run_hook "$HOOKS/check-secrets.sh" "git -C $feature commit -m a && git commit -m b" "$sb")"
check b1-commit-unquoted 2 "$(run_hook "$HOOKS/block-main-push.sh" "git -C $feature commit -m a && git commit -m b" "$sb")"
check b1-no-space-separator 2 "$(run_hook "$HOOKS/check-secrets.sh" "git -C $feature commit;git commit" "$sb")"
check b1-protected-push 2 "$(run_hook "$HOOKS/block-main-push.sh" "git -C $feature push && git push" "$sb")"
check b1-quoted-prefix 2 "$(run_hook "$HOOKS/check-secrets.sh" "echo \"git -C $other commit\" && git commit -m x" "$sb")"

# Use a missing-ticket branch for the second push target.
git -C "$sb" symbolic-ref HEAD refs/heads/fix/no-ticket-name
check b1-branch 2 "$(run_hook "$HOOKS/validate-branch-name.sh" "git -C $feature push && git push" "$sb")"
printf 'FROM scratch\n' > "$sb/Dockerfile"
git -C "$sb" add Dockerfile
check b1-agdr 2 "$(run_hook "$HOOKS/require-agdr-for-arch-changes.sh" "git -C $feature commit -m 'fix: first' && git commit -m 'fix: second'" "$sb")"
# Stage private configuration directly in the index. Do not create the file.
blob=$(printf 'company: private\n' | git -C "$sb" hash-object -w --stdin)
git -C "$sb" update-index --add --cacheinfo "100644,$blob,onboarding.yaml"
check b1-onboarding 2 "$(run_hook "$HOOKS/block-onboarding-in-git.sh" "git -C $feature commit -m 'fix: first' && git commit -m 'fix: second'" "$sb")"

# Keep bootstrap markers inside the disposable fixture.
mkdir -p "$sb/.claude/session"
printf handover > "$sb/.claude/session/active-bootstrap.marker-test"
check b1-bootstrap-status 0 "$(run_hook "$HOOKS/warn-bootstrap-scope.sh" "git -C $feature commit -m 'fix: first' && git commit -m 'fix: second'" "$sb")"
if grep -q 'Bootstrap exemption is active' "$test_tmp/hook.err"; then
  echo PASS b1-bootstrap-warning
else
  echo FAIL b1-bootstrap-warning >&2
  fail=1
fi

git -C "$sb" symbolic-ref HEAD refs/heads/main
work=$(dirname "$sb")
leaf=$(basename "$sb")
for cmd in "git -C $work -C $leaf commit" "git -C $sb -C . commit"; do
  check b2-secrets 2 "$(run_hook "$HOOKS/check-secrets.sh" "$cmd" "$other")"
  check b2-protected-commit 2 "$(run_hook "$HOOKS/block-main-push.sh" "$cmd" "$other")"
done
check b2-protected-push 2 "$(run_hook "$HOOKS/block-main-push.sh" "git -C $work -C $leaf push" "$other")"
check h1-relative-git-dir 2 "$(run_hook "$HOOKS/check-secrets.sh" "git -C $sb --git-dir=.git commit" "$other")"
check h1-relative-work-tree 2 "$(run_hook "$HOOKS/block-main-push.sh" "git -C $sb --git-dir=.git --work-tree=. commit" "$other")"

for gate in check-secrets block-main-push validate-commit-format require-agdr-for-arch-changes block-onboarding-in-git validate-branch-name block-agent-routing-drift verify-commit-refs; do
  verb=commit
  [ "$gate" != validate-branch-name ] || verb=push
  for path in '"$HOME/x"' '/nonexistent' '"/a"b' '"`pwd`"' '"$(pwd)"' '$(printf /a)' '`printf /a`'; do
    check "h2-$gate-$path" 2 "$(run_hook "$HOOKS/$gate.sh" "git -C $path $verb" "$other")"
    if ! grep -q 'cannot resolve the git -C target; use a literal path' "$test_tmp/hook.err"; then
      echo "FAIL h2-message-$gate" >&2
      fail=1
    fi
  done
done
# Use a disposable home directory for shell-style tilde expansion.
mkdir -p "$test_tmp/home/realdir"
git -C "$test_tmp/home/realdir" init -q -b main
seed_history "$test_tmp/home/realdir"
HOME="$test_tmp/home" check h2-tilde 2 "$(HOME="$test_tmp/home" run_hook "$HOOKS/block-main-push.sh" 'git -C ~/realdir commit' "$other")"
if grep -q 'Cannot commit directly' "$test_tmp/hook.err"; then
  echo PASS h2-tilde-target
else
  echo FAIL h2-tilde-target >&2
  fail=1
fi
mkdir -p "$other/~/realdir"
git -C "$other/~/realdir" init -q -b feature/GH-1-literal
check h2-quoted-tilde 0 "$(HOME="$test_tmp/home" run_hook "$HOOKS/block-main-push.sh" 'git -C "~/realdir" commit' "$other")"
check h2-single-quoted-tilde 0 "$(HOME="$test_tmp/home" run_hook "$HOOKS/block-main-push.sh" "git -C '~/realdir' commit" "$other")"
for option in --git-dir --work-tree; do
  check "h2-$option-substitution" 2 "$(run_hook "$HOOKS/check-secrets.sh" "git $option=\"\$HOME/x\" commit" "$other")"
  check "h2-$option-command-substitution" 2 "$(run_hook "$HOOKS/check-secrets.sh" "git $option=\"\$(printf /a)\" commit" "$other")"
  check "h2-$option-missing" 2 "$(run_hook "$HOOKS/check-secrets.sh" "git $option=/nonexistent commit" "$other")"
done
for gate in pre-push-gate warn-stale-review-markers warn-bootstrap-scope; do
  verb=push
  [ "$gate" != warn-bootstrap-scope ] || verb=commit
  check "h2-advisory-$gate" 0 "$(run_hook "$HOOKS/$gate.sh" "git -C /nonexistent $verb" "$other")"
done

# Diff checks must not execute repository conversion or monitor commands.
printf '#!/bin/bash\necho ran >> "%s"\nprintf sanitized\n' "$test_tmp/executed" > "$test_tmp/unsafe-diff"
chmod +x "$test_tmp/unsafe-diff"
git -C "$sb" config diff.external "$test_tmp/unsafe-diff"
git -C "$sb" config core.fsmonitor "$test_tmp/unsafe-diff"
git -C "$sb" config diff.probe.textconv "$test_tmp/unsafe-diff"
printf 'secret.txt diff=probe\n' > "$sb/.gitattributes"
check h6-secret-diff 2 "$(run_hook "$HOOKS/check-secrets.sh" "git -C $sb commit" "$other")"
check h6-no-execution no "$(if [ -e "$test_tmp/executed" ]; then printf yes; else printf no; fi)"

# A loaded marker must not disable dispatcher routing.
mkdir -p "$test_tmp/dispatch"
cp "$HOOKS/dispatch-bash.sh" "$HOOKS/_lib-git-global.sh" "$HOOKS/_lib-extract-pr.sh" "$HOOKS/_lib-command-scrub.sh" "$HOOKS/_lib-awk-fallback.sh" "$HOOKS/_lib-strip-heredoc.sh" "$test_tmp/dispatch/"
for gate in $(sed -nE 's/^# APEXYARD_DISPATCH_GATE: Bash[^|]*\|[^|]*\|([^ ]+)\.sh$/\1/p' "$HOOKS/dispatch-bash.sh" | sort -u); do
  printf '#!/bin/bash\ncat >/dev/null\necho %s >> "$DISPATCH_LOG"\n' "$gate" > "$test_tmp/dispatch/$gate.sh"
  chmod +x "$test_tmp/dispatch/$gate.sh"
done
payload=$(jq -nc '{tool_name:"Bash",tool_input:{command:"echo hello"}}')
printf '%s' "$payload" | _LIB_GIT_GLOBAL_LOADED=1 DISPATCH_LOG="$test_tmp/dispatch.log" bash "$test_tmp/dispatch/dispatch-bash.sh" >/dev/null 2>"$test_tmp/dispatch.err"
check h5-commit-routed yes "$(grep -q check-secrets "$test_tmp/dispatch.log" && printf yes)"
check h5-push-routed yes "$(grep -q pre-push-gate "$test_tmp/dispatch.log" && printf yes)"

if [ "$fail" -ne 0 ]; then
  echo FAIL
  exit 1
fi
echo PASS
exit 0
