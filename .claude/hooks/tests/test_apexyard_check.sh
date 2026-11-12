#!/usr/bin/env bash
# Offline checks for `apexyard check`. No network. Real hooks run on fixture repos.
# shellcheck disable=SC1091,SC2154
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_lib-apexyard-cli.sh"
sb=$(cd "$sb" && pwd -P)
root=$(cd "$(dirname "$CLI")/.." && pwd)
export APEXYARD_DISABLE_RESOLUTION_CACHE=1
mkdir -p "$sb/ops/.claude/skills" "$sb/ops/workspace"
cp -R "$root/.claude/hooks" "$sb/ops/.claude/"
printf 'company: test\n' > "$sb/ops/onboarding.yaml"
printf 'projects:\n  - name: app\n    repo: org/app\n  - name: bare\n    repo: org/bare\n' > "$sb/ops/apexyard.projects.yaml"
git -C "$sb/ops" init -b main >/dev/null
export APEXYARD_OPS_ROOT="$sb/ops"
# The seed repo holds stub pre-push scripts that read FAKE_* variables.
mkdir -p "$sb/seed/bin"
cat > "$sb/seed/bin/run-pre-push-checks.sh" <<'SH'
#!/bin/bash
[ -z "${FAKE_SKIP:-}" ] || echo "WARN: pre-push checks bypassed by skip marker in HEAD commit message." >&2
echo "stub pre-push output"
exit "${FAKE_PREPUSH_RC:-0}"
SH
cat > "$sb/seed/bin/run-configured-pre-push-checks.sh" <<'SH'
#!/bin/bash
exit "${FAKE_CONFIGURED_RC:-0}"
SH
git -C "$sb/seed" init -b main >/dev/null
git -C "$sb/seed" add -- bin
git -C "$sb/seed" commit -m 'chore: seed' >/dev/null
git clone --bare "$sb/seed" "$sb/origin.git" >/dev/null 2>&1
clone="$sb/ops/workspace/app"
git clone "$sb/origin.git" "$clone" >/dev/null 2>&1
git -C "$clone" remote set-url origin https://github.com/org/app.git
# The bare clone has no stub scripts and no base ref.
mkdir -p "$sb/ops/workspace/bare"
git -C "$sb/ops/workspace/bare" init -b main >/dev/null
git -C "$sb/ops/workspace/bare" remote add origin https://github.com/org/bare.git
git -C "$sb/ops/workspace/bare" commit --allow-empty -m 'chore: first' >/dev/null
run_at() {
  local dir=$1
  shift
  rc=0
  (cd "$dir" && bash "$CLI" check "$@") > "$sb/out" 2>"$sb/err" || rc=$?
}
snapshot() {
  {
    git -C "$1" status --porcelain
    git -C "$1" for-each-ref
    git -C "$1" ls-files -s
    git -C "$1" log --all --format=%H
    git -C "$1" worktree list --porcelain
    find "$1" "$sb/ops/.claude/session" "$sb/ops/.claude/markers" \
      -path '*/.git' -prune -o -type f -print 2>/dev/null | LC_ALL=C sort | xargs cksum 2>/dev/null || true
    (cd "$1" && cksum < "$(git rev-parse --git-path index)")
  } > "$2"
}
status_of() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print([c["status"] for c in d["checks"] if c["name"]==sys.argv[2]][0])' "$sb/out" "$1"
}
git -C "$clone" checkout -q -b feature/GH-5-good-name
echo one > "$clone/file.txt"
git -C "$clone" add -- file.txt
git -C "$clone" commit -q -m 'feat: add file'
# A good branch passes every check, from the clone.
snapshot "$clone" "$sb/before"
run_at "$clone"
snapshot "$clone" "$sb/after"
check 'all pass exits zero' test "$rc" = 0
check 'header' grep -Fxq 'Repo: org/app  Branch: feature/GH-5-good-name' "$sb/out"
for name in pre-push configured-pre-push branch-name commit-format commit-refs secrets; do
  check "pass $name" grep -Eq "^pass +$name\$" "$sb/out"
done
check 'advisory line' grep -Fxq 'Advisory: this is a local result. The required check on the pull request decides.' "$sb/out"
check 'no file, ref, index or marker change' cmp "$sb/before" "$sb/after"
# JSON has one record per check.
run_at "$clone" --json
check 'json exits zero' test "$rc" = 0
check 'json shape' python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["repo"] == "org/app" and d["branch"] == "feature/GH-5-good-name"
assert d["base"] and "advisory" in d
names = [c["name"] for c in d["checks"]]
assert names == ["pre-push", "configured-pre-push", "branch-name", "commit-format", "commit-refs", "secrets"], names
assert all(set(c) == {"name", "status", "message"} for c in d["checks"])
assert all(c["status"] == "pass" for c in d["checks"])
' "$sb/out"
# A failing script check exits non-zero and shows the others.
FAKE_PREPUSH_RC=1 run_at "$clone"
check 'script fail exits one' test "$rc" = 1
check 'script fail line' grep -Eq '^FAIL +pre-push' "$sb/out"
check 'other checks still run' grep -Eq '^pass +branch-name$' "$sb/out"
FAKE_CONFIGURED_RC=1 run_at "$clone" --json
check 'configured fail json' test "$(status_of configured-pre-push)" = fail
# Quotes and a body in a commit message must not cause a false failure.
# shellcheck disable=SC2016
git -C "$clone" commit -q --allow-empty -m "feat: add \"quoted\" don't thing" \
  -m 'Body line with $dollar and `tick`.'
run_at "$clone"
check 'quoted multi-line message passes' grep -Eq '^pass +commit-format$' "$sb/out"
git -C "$clone" reset -q --soft HEAD~1
# A bad commit subject fails the commit-format check.
git -C "$clone" commit -q --allow-empty -m 'wip stuff'
run_at "$clone"
check 'bad commit exits one' test "$rc" = 1
check 'bad commit line' grep -Eq '^FAIL +commit-format' "$sb/out"
git -C "$clone" reset -q --soft HEAD~1
# A merge commit in the range is not checked as a commit subject.
git -C "$clone" checkout -q -b feature/GH-8-side
git -C "$clone" commit -q --allow-empty -m 'feat: side work'
git -C "$clone" checkout -q -b feature/GH-9-merged feature/GH-5-good-name
git -C "$clone" commit -q --allow-empty -m 'feat: main work'
git -C "$clone" merge -q --no-ff -m "Merge branch 'feature/GH-8-side' into feature/GH-9-merged" feature/GH-8-side
run_at "$clone"
check 'merge commit exits zero' test "$rc" = 0
check 'merge commit passes commit-format' grep -Eq '^pass +commit-format$' "$sb/out"
git -C "$clone" checkout -q feature/GH-5-good-name
git -C "$clone" branch -q -D feature/GH-8-side feature/GH-9-merged
# A skip marker shows as not verified, never pass.
FAKE_SKIP=1 run_at "$clone" --json
check 'skip marker not verified' test "$(status_of pre-push)" = not_verified
git -C "$clone" checkout -q -b badname
run_at "$clone"
check 'bad branch exits one' test "$rc" = 1
check 'bad branch hook message' grep -Fq "doesn't follow naming convention" "$sb/out"
git -C "$clone" checkout -q feature/GH-5-good-name
# A worktree checks its own branch.
git -C "$clone" worktree add -q -b feature/GH-6-in-worktree "$sb/wt" >/dev/null 2>&1
run_at "$sb/wt"
check 'worktree exits zero' test "$rc" = 0
check 'worktree branch' grep -Fxq 'Repo: org/app  Branch: feature/GH-6-in-worktree' "$sb/out"
# The ops repo needs a project choice, then checks the clone.
run_at "$sb/ops" --repo app
check 'ops with repo exits zero' test "$rc" = 0
check 'ops checks clone branch' grep -Fxq 'Repo: org/app  Branch: feature/GH-5-good-name' "$sb/out"
run_at "$sb/ops"
check 'ops without repo exits two' test "$rc" = 2
# Checks that cannot run show not verified, never pass.
git -C "$sb/ops/workspace/bare" checkout -q -b feature/GH-7-bare
run_at "$sb/ops" --repo bare --json
check 'not verified exits zero' test "$rc" = 0
check 'missing script' test "$(status_of pre-push)" = not_verified
check 'missing configured script' test "$(status_of configured-pre-push)" = not_verified
check 'no base commit-format' test "$(status_of commit-format)" = not_verified
check 'no base commit-refs' test "$(status_of commit-refs)" = not_verified
check 'branch still checked' test "$(status_of branch-name)" = pass
git -C "$clone" checkout -q --detach
run_at "$clone" --json
check 'detached branch-name' test "$(status_of branch-name)" = not_verified
check 'detached exits zero' test "$rc" = 0
git -C "$clone" checkout -q feature/GH-5-good-name
# Without jq no hook runs, and no hook check passes.
shim="$sb/shim"
mkdir -p "$shim"
for tool in bash git sed tr cut cat mktemp rm dirname basename awk head tail grep python3 env readlink sort find xargs cksum ls mkdir wc printf cmp; do
  src=$(command -v "$tool" 2>/dev/null) || continue
  ln -sf "$src" "$shim/$tool"
done
rc=0
(cd "$clone" && PATH="$shim" bash "$CLI" check --json) > "$sb/out" 2>"$sb/err" || rc=$?
check 'no jq exits zero' test "$rc" = 0
check 'no jq JSON valid' python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$sb/out"
for name in branch-name commit-format commit-refs secrets; do
  check "no jq $name" test "$(status_of $name)" = not_verified
done
# Bad usage.
run_at "$clone" --unknown
check 'unknown option exits two' test "$rc" = 2
run_at "$sb"
check 'outside any repo exits two' test "$rc" = 2
finish
