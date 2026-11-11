#!/usr/bin/env bash
# Exercise read-only PR commands with local fixtures.
# shellcheck disable=SC1091,SC2154
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_lib-apexyard-cli.sh"
sb=$(cd "$sb" && pwd -P)
root=$(cd "$(dirname "$CLI")/.." && pwd)
mkdir -p "$sb/ops/.claude/skills/status" "$sb/ops/workspace"
cp -R "$root/.claude/hooks" "$sb/ops/.claude/"
cp "$root/.claude/skills/status/briefing.sh" "$sb/ops/.claude/skills/status/"
echo 'company: test' > "$sb/ops/onboarding.yaml"
printf 'projects:\n  - name: app\n    repo: org/app\n' > "$sb/ops/apexyard.projects.yaml"
git -C "$sb/ops" init -b main >/dev/null
clone="$sb/ops/workspace/app"
git clone "$sb/fixture" "$clone" >/dev/null 2>&1
git -C "$clone" remote set-url origin https://github.com/org/app.git
git -C "$clone" worktree add -b feature/GH-1-test "$sb/tree" >/dev/null 2>&1
export APEXYARD_OPS_ROOT="$sb/ops" APEXYARD_PR_STATUS="$sb/tools/pr-status"
export EXPECT_CLONE="$clone"
cat > "$APEXYARD_GH" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
[ "$1 $2" = 'pr list' ] || exit 2
printf '[{"number":1,"url":"url","title":"Ready"},{"number":2,"url":"url","title":"Blocked"},{"number":3,"url":"url","title":"Failed"},{"number":4,"url":"url","title":"Unknown"},{"number":5,"url":"url","title":"Bad JSON"},{"number":6,"url":"url","title":"No head"}]\n'
FAKE
cat > "$APEXYARD_PR_STATUS" <<'FAKE'
#!/bin/bash
[ "$PWD" = "$EXPECT_CLONE" ] && [ "$APEXYARD_DISABLE_RESOLUTION_CACHE" = 1 ] || exit 9
status=satisfied
head=abc
case "$1" in
  *#2) status=missing ;;
  *#3) exit 1 ;;
  *#4) status='not verified' ;;
  *#5) echo invalid; exit ;;
  *#6) head='' ;;
esac
jq -n --arg status "$status" --arg head "$head" '{head:{sha:$head},next_action:"Approve the PR.",items:[{section:"records",name:"rex",status:$status,detail:"review"},{section:"records",name:"ceo",status:"missing",detail:"approval"}]}'
FAKE
chmod +x "$APEXYARD_GH" "$APEXYARD_PR_STATUS"
run_at() {
  local dir=$1
  shift
  rc=0
  (cd "$dir" && bash "$CLI" "$@") > "$sb/out" 2> "$sb/err" || rc=$?
}
before=$(git -C "$clone" for-each-ref)
ops_before=$(git -C "$sb/ops" for-each-ref)
for dir in "$clone" "$sb/tree" "$sb/ops"; do
  run_at "$dir" why 1 --repo app
  check 'why succeeds' test "$rc" = 0
  check 'next action first' test "$(head -1 "$sb/out")" = "$(cd "$clone" && "$APEXYARD_PR_STATUS" org/app#1 --json | jq -r .next_action)"
  check 'full table' grep -q ceo "$sb/out"
done
for target in 1 app#1 org/app#1; do
  run_at "$clone" why "$target" --json
  check 'why JSON' python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["verified"] and d["repo"]=="org/app" and d["pr"]==1 and len(d["items"])==2' "$sb/out"
done
run_at "$sb/ops" why 1
check 'ops prompt' test "$rc" = 2
check 'numbered selection' grep -q '1) app' "$sb/err"
run_at "$clone" why 3 --json
check 'why failure code' test "$rc" = 1
check 'why failure JSON' python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["verified"] is False and d["next_action"] is None' "$sb/out"
run_at "$clone" why 5
check 'bad JSON failure' test "$rc" = 1
check 'failure plain line' grep -Fxq 'not verified: invalid PR status JSON' "$sb/out"
run_at "$sb/ops" queue --json
check 'queue succeeds' test "$rc" = 0
check 'queue JSON' python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert [r["pr"] for r in d["ready"]]==[1]; assert [r["pr"] for r in d["not_verified"]]==[3,4,5,6]; assert d["blocked_count"]==1' "$sb/out"
run_at "$sb/ops" queue
check 'ready line' grep -Fxq 'org/app#1 Ready' "$sb/out"
check 'unknown line' grep -q '^not verified: org/app#4 ' "$sb/out"
run_at "$sb/ops" status --json
check 'status JSON' python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert set(d)=={"workspace","ticket","branch","role_set"}; assert d["workspace"]=="(ops)"' "$sb/out"
check 'clone refs unchanged' test "$(git -C "$clone" for-each-ref)" = "$before"
check 'ops refs unchanged' test "$(git -C "$sb/ops" for-each-ref)" = "$ops_before"
check 'only read forge calls' python3 -c 'import sys; calls=open(sys.argv[1]).read().splitlines(); assert calls; assert all(c.startswith(("pr view ","pr list ","pr checks ")) or (c.startswith("api ") and ("--method GET" in c or "-X GET" in c or "query=" in c) and "mutation" not in c) for c in calls)' "$FAKE_GH_LOG"
finish
