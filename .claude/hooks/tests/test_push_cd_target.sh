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
# Use local bare repositories. Do not contact a network remote.
git init -q --bare "$TEMP/empty.git"
git init -q --bare "$TEMP/full.git"
git -C "$TEMP/sibling-main" -c user.name=Test -c user.email=test@example.invalid -c core.hooksPath=/dev/null commit -q --allow-empty -m fixture
git --git-dir="$TEMP/full.git" fetch -q "$TEMP/sibling-main" main:main
git -C "$TEMP/sibling-main" remote add origin "$TEMP/empty.git"
run first-main 0 'cd ../sibling-main && git add a && git commit -m m && git push -u origin HEAD' block-main-push.sh 'first push to an empty remote: allowed'
# Check command-controlled programs. Each marker must remain absent.
marker="$TEMP/probe-executed"
absent() {
  if [ ! -e "$marker" ]; then
    echo "PASS $1-marker-absent"; pass=$((pass+1))
  else
    echo "FAIL $1-marker-present"; fail=$((fail+1))
    rm -f "$marker"
  fi
}
run unsafe-ext 2 "cd ../sibling-main && git -c protocol.ext.allow=always push \"ext::sh -c touch% $marker\" main"
absent unsafe-ext
git -C "$TEMP/sibling-main" remote add unsafe "ext::sh -c touch% $marker"
run unsafe-remote 2 'cd ../sibling-main && git push unsafe main'
absent unsafe-remote
for option in --receive-pack --exec --upload-pack -o --push-option; do
  run "unsafe-$option" 2 "cd ../sibling-main && git push $option=\"touch $marker\" origin main"
  absent "unsafe-$option"
done
for helper in fd unknown; do
  run "unsafe-$helper" 2 "cd ../sibling-main && git push '$helper::test' main"
done
run unsafe-dash-url 2 'cd ../sibling-main && git push -- -remote main'
for selector in --git-dir --work-tree; do
  run "unsafe-$selector" 2 "cd ../sibling-main && git $selector='$TEMP/sibling-main' push origin main"
done
# Use a local SSH stub. Do not connect to a network host.
cat > "$TEMP/fail-ssh" <<'SSH'
#!/bin/sh
exit 1
SSH
chmod +x "$TEMP/fail-ssh"
export GIT_SSH="$TEMP/fail-ssh"
export GIT_SSH_COMMAND="$TEMP/fail-ssh"
git -C "$TEMP/sibling-main" remote add ssh-target 'host.invalid:repo'
run unsafe-ssh-command 2 "cd ../sibling-main && git -c core.sshCommand=\"touch $marker\" push ssh-target main"
absent unsafe-ssh-command
unset GIT_SSH GIT_SSH_COMMAND
for config in uploadpack credential.helper; do
  run "ignored-$config" 0 "cd ../sibling-main && git -c $config=\"!touch $marker\" push origin main"
  absent "ignored-$config"
done
run ignored-globals 0 'cd ../sibling-main && git --exec-path=/nonexistent --namespace=other --config-env=core.sshCommand=MISSING push origin main'
run repeated-dash-c 0 'git -C .. -C sibling-main push origin main'
run first-force 2 'cd ../sibling-main && git push --force origin HEAD'
run first-short-force 2 'cd ../sibling-main && git push -f origin HEAD'
run first-lease 2 'cd ../sibling-main && git push --force-with-lease origin HEAD'
run first-plus 2 'cd ../sibling-main && git push origin +HEAD:main'
run first-all 2 'cd ../sibling-main && git push --all origin'
run first-mirror 2 'cd ../sibling-main && git push --mirror origin'
run first-delete 2 'cd ../sibling-main && git push --delete origin main'
run first-colon 2 'cd ../sibling-main && git push origin :main'
run first-url 0 "cd ../sibling-main && git push '$TEMP/empty.git' main" block-main-push.sh 'first push to an empty remote: allowed'
mkdir "$TEMP/no-timeout"
ln -s "$(command -v jq)" "$TEMP/no-timeout/jq"
PATH_SAVE="$PATH"
PATH="$TEMP/no-timeout:/usr/bin:/bin:/usr/sbin:/sbin"
run first-fallback 0 'cd ../sibling-main && git push origin HEAD' block-main-push.sh 'first push to an empty remote: allowed'
PATH="$PATH_SAVE"
cat > "$TEMP/slow-ssh" <<'SSH'
#!/bin/sh
exec sleep 30
SSH
chmod +x "$TEMP/slow-ssh"
export GIT_SSH_COMMAND="$TEMP/slow-ssh"
run probe-timeout 2 'cd ../sibling-main && git push ssh://example.invalid/repo HEAD'
PATH="$TEMP/no-timeout:/usr/bin:/bin:/usr/sbin:/sbin"
run probe-fallback-timeout 2 'cd ../sibling-main && git push ssh://example.invalid/repo HEAD'
PATH="$PATH_SAVE"
unset GIT_SSH_COMMAND
run first-cd-chained-dash-c 0 'cd ..; git -C sibling-feature -C ../sibling-main push origin HEAD' block-main-push.sh 'first push to an empty remote: allowed'
run first-dash-c 0 'git -C ../sibling-main push origin HEAD' block-main-push.sh 'first push to an empty remote: allowed'
git -C "$TEMP/sibling-main" config branch.main.remote origin
run first-configured 0 'cd ../sibling-main && git push' block-main-push.sh 'first push to an empty remote: allowed'
git -C "$TEMP/sibling-main" remote set-url origin "$TEMP/full.git"
run later-main 2 'cd ../sibling-main && git add a && git commit -m m && git push -u origin HEAD'
git -C "$TEMP/sibling-feature" remote add origin "$TEMP/full.git"
run feature-explicit-main 2 'cd ../sibling-feature && git push origin main'
git -C "$TEMP/sibling-main" remote set-url origin "$TEMP/missing.git"
run missing-remote 2 'cd ../sibling-main && git push -u origin HEAD'
git -C "$TEMP/ops" remote add origin "$TEMP/empty.git"
run empty-dev 0 'git push origin dev' block-main-push.sh 'first push to an empty remote: allowed'
git --git-dir="$TEMP/empty.git" fetch -q "$TEMP/sibling-main" main:main
run later-dev 2 'git push origin dev'
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
