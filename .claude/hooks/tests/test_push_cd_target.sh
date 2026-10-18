#!/bin/bash
# Check push targets in command chains. Do not execute the command text.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
HOOKS="$ROOT/.claude/hooks"
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
pass=0
fail=0
for spec in ops:dev sibling-main:main sibling-feature:feature/x 'space repo:feature/GH-1-good'; do
  git init -q -b "${spec#*:}" "$TEMP/${spec%%:*}"
done
run() {
  local name="$1" want="$2" cmd="$3" hook="${4:-block-main-push.sh}" message="${5:-}" rc
  jq -nc --arg cmd "$cmd" --arg cwd "$TEMP/ops" \
    '{tool_input:{command:$cmd},cwd:$cwd}' > "$TEMP/input"
  (cd "${HOOK_CWD:-$TEMP/ops}" && bash "$HOOKS/$hook" < "$TEMP/input") > "$TEMP/out" 2>&1
  rc=$?
  if [ "$rc" = "$want" ] && { [ -z "$message" ] || grep -q "$message" "$TEMP/out"; }; then
    echo "PASS $name"; pass=$((pass+1))
  else
    echo "FAIL $name rc=$rc"; cat "$TEMP/out"; fail=$((fail+1))
  fi
}
# Give the existing fixtures history. Keep the new fixture unborn.
for repo in ops sibling-main; do
  git -C "$TEMP/$repo" -c user.name=Test -c user.email=test@example.invalid -c core.hooksPath=/dev/null commit -q --allow-empty -m fixture
done
git init -q -b main "$TEMP/unborn-main"
git -C "$TEMP/unborn-main" remote add origin https://example.invalid/unborn
run unborn-commit 2 'cd ../unborn-main && git commit -m m' block-main-push.sh "protected branch 'main'"
run unborn-setup 2 'cd ../unborn-main && git add a && git commit -m m && git push -u origin HEAD'
run unborn-config 2 'cd ../unborn-main && git -c x=y commit -m m' block-main-push.sh "protected branch 'main'"
run unborn-config-env 2 'cd ../unborn-main && git --config-env=x=Y commit -m m'
run unborn-env 2 'cd ../unborn-main && GIT_DIR=.git git commit -m m'
run unborn-amend 2 'cd ../unborn-main && git commit --amend -m m'
run unborn-two-commits 2 'cd ../unborn-main && git commit -m m && git commit -m n'
run unborn-then-existing 2 'cd ../unborn-main && git commit -m m && cd ../sibling-main && git commit -m n'
git -C "$TEMP/unborn-main" fetch -q "$TEMP/ops" dev:refs/remotes/origin/main
run unborn-tracking 2 'cd ../unborn-main && git add a && git commit -m m && git push -u origin HEAD' block-main-push.sh 'Cannot push'
run long-feature 0 'cd ../sibling-feature && git add a && git commit -m m && git push -u origin HEAD'
run long-main 2 'cd ../sibling-main && git add a && git commit -m m && git push -u origin HEAD' block-main-push.sh "('main')"
run explicit-main 2 'cd ../sibling-feature && git push origin main'
run plain-dev 2 'git push origin HEAD' block-main-push.sh "('dev')"
run invalid-cd 2 'cd /nonexistent && git push origin HEAD' block-main-push.sh "BLOCKED: cannot resolve"
run cd-dash-c 2 'cd ../sibling-feature; git -C ../sibling-main push origin HEAD' block-main-push.sh "('main')"
HOOK_CWD="$ROOT"
run payload-relative-feature 0 'cd ../sibling-feature && git add a && git commit -m m && git push -u origin HEAD'
run payload-relative-main 2 'cd ../sibling-main && git push origin HEAD' block-main-push.sh "('main')"
unset HOOK_CWD
run parent-dash-c 2 'cd ..; git -C sibling-main push origin HEAD' block-main-push.sh "('main')"
run single-cd 0 'cd ../sibling-feature && git push origin HEAD'
run quoted 0 "cd '../space repo' && git push origin HEAD"
run double-quoted 0 'cd "../space repo" && git push origin HEAD'
run multiple-cd 0 'cd ..; cd sibling-feature; git push origin HEAD'
run later-cd 2 'git push origin HEAD; cd ../sibling-feature'
run nonrepo 2 'cd ..; git push origin HEAD'
# Resolve each invocation independently, including identical command prefixes.
run later-push-main 2 'cd ../sibling-feature; git push origin HEAD; cd ../sibling-main; git push origin HEAD' block-main-push.sh "('main')"
run later-commit-main 2 'cd ../sibling-feature; git commit -m a; cd ../sibling-main; git commit -m b' block-main-push.sh "protected branch 'main'"
run mixed-invocation-counts 0 'cd ../sibling-feature; git commit -m a; git push origin HEAD; git push origin HEAD; cd ../sibling-main; git status'
run later-invalid-cd 2 'cd ../sibling-feature; git push origin HEAD; cd /nonexistent; git push origin HEAD' block-main-push.sh 'BLOCKED: cannot resolve'
run dynamic-cd 2 'cd "$TARGET"; git push origin HEAD' block-main-push.sh 'BLOCKED: cannot resolve'
run substitution-cd 2 'cd $(pwd); git push origin HEAD' block-main-push.sh 'BLOCKED: cannot resolve'
run malformed-cd 2 'cd "../sibling-feature; git push origin HEAD' block-main-push.sh 'BLOCKED: cannot resolve'
run cd-chained-dash-c 2 'cd ..; git -C sibling-feature -C ../sibling-main push origin HEAD' block-main-push.sh "('main')"
run concatenated-cd 0 'cd ../"space repo"; git push origin HEAD'
HOME_SAVE="$HOME"
export HOME="$TEMP"
run tilde 0 'cd ~/sibling-feature && git push origin HEAD'
export HOME="$HOME_SAVE"
run branch-target 2 'cd ../sibling-feature && git add a && git push origin HEAD' validate-branch-name.sh "feature/x"
run branch-valid 0 "cd '../space repo'; git push origin HEAD" validate-branch-name.sh
# Check the shared target used by the advisory pre-push gate.
# shellcheck disable=SC1090
. "$HOOKS/_lib-git-global.sh"
git_prepare_invocation 'cd ../sibling-feature; git -C ../sibling-main push origin HEAD' push "$TEMP/ops"
if [ "$(git_target branch --show-current)" = main ]; then
  echo 'PASS shared-pre-push-target'; pass=$((pass+1))
else
  echo 'FAIL shared-pre-push-target'; fail=$((fail+1))
fi
# Create local fixtures. Do not contact a remote.
git -C "$TEMP/sibling-main" -c user.name=Test -c user.email=test@example.invalid -c core.hooksPath=/dev/null commit -q --allow-empty -m fixture
git -C "$TEMP/sibling-main" remote add origin https://example.invalid/repo
run never-fetched-main 2 'cd ../sibling-main && git push -u origin HEAD' block-main-push.sh "('main')"
run commit-before-first-push 2 'git commit -m m && cd ../sibling-main && git push -u origin feature/GH-1-good' block-main-push.sh "protected branch 'dev'"
run existing-setup 2 'cd ../sibling-main && git add a && git commit -m m && git push -u origin feature/GH-1-good' block-main-push.sh "protected branch 'main'"
run commit-after-cd 2 'cd ../sibling-main && git commit -m m && git push origin feature/GH-1-good' block-main-push.sh "protected branch 'main'"
for shape in '( cd ../sibling-feature && git push )' 'if cd ../sibling-feature; then git push; fi' '{ cd ../sibling-feature; git push; }' 'command cd ../sibling-feature && git push' 'false || cd ../sibling-feature && git push' 'pushd ../sibling-feature && git push' 'cd ../sibling-feature & git push' 'builtin cd ../sibling-feature && git push' 'popd && git push' '\cd ../sibling-feature && git push'; do
  run "unresolved-$shape" 2 "$shape" block-main-push.sh 'cannot resolve the cd target'
done
for shape in 'cd ../sibling-feature && git push' 'cd ../sibling-feature; git push' $'cd ../sibling-feature\ngit push' 'cd ../sibling-feature || exit 1; git push' 'cd ../sibling-feature || exit 1 && git push' 'cd ../sibling-feature || return 2; git push' 'cd ../sibling-feature || return 2 && git push'; do
  run "supported-$shape" 0 "$shape"
done
# Reviewer regressions: every command remains text, never executed.
for verb in push commit; do
  for shape in "cd ../sibling-feature && (cd ../sibling-main && git $verb)" "if true; then cd ../sibling-main; fi; git $verb" "{ cd ../sibling-main; }; git $verb" "builtin cd ../sibling-main && git $verb"; do
    run "review-compound-$verb-$shape" 2 "$shape"
  done
done
run review-commit-before-first-push 2 'git commit -m m && cd ../sibling-main && git push origin feature/GH-1-good' block-main-push.sh "protected branch 'dev'"
run repeated-dash-c 2 'git -C .. -C sibling-main push origin main'
run never-fetched-bare 2 'cd ../sibling-main && git push'
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
