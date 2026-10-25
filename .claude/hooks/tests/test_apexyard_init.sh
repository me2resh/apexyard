#!/usr/bin/env bash
# Test repository creation without network access.
# The shared fixture defines sb.
# shellcheck disable=SC1091,SC2154
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_lib-apexyard-cli.sh"
check 'init succeeds' init_ops
check upstream test "$(git -C "$sb/ops" remote get-url upstream)" = "$sb/fixture"
check origin test "$(git -C "$sb/ops" remote get-url origin)" = "$FAKE_REMOTE"
check version test "$(cat "$sb/ops/.claude/framework-version")" = v1.0.0
check 'default org' grep -q 'name: "example-org"' "$sb/ops/onboarding.yaml"
check registry test -f "$sb/ops/apexyard.projects.yaml"
check 'private create' grep -q 'repo create example-org/ops --private --source=. --remote=origin --push' "$FAKE_GH_LOG"
check 'template flags absent' test "$(grep -Ec -- '--fork|--template' "$FAKE_GH_LOG")" = 0
check 'full history' git -C "$sb/ops" merge-base --is-ancestor v1.0.0 HEAD
check 'local setup untracked' test -z "$(git -C "$sb/ops" ls-files onboarding.yaml apexyard.projects.yaml)"
check 'commit identity not saved' test -z "$(git -C "$sb/ops" config --local --get user.name || true)"
check 'version commit' test "$(git -C "$sb/ops" log -1 --format=%s)" = 'chore: record framework version'
export FAKE_REMOTE="$sb/public.git"
check public /bin/bash "$CLI" init --org other --name public-ops --public --dir "$sb/public" > "$sb/public.out" 2>&1
check 'public create' grep -q 'repo create other/public-ops --public' "$FAKE_GH_LOG"
if /bin/bash "$CLI" init --dir "$sb/ops" > "$sb/refuse.out" 2>&1; then rc=0; else rc=$?; fi
check 'refuse nonempty' test "$rc" = 2
check 'refusal reason' grep -q 'not empty' "$sb/refuse.out"
check 'dry run succeeds' /bin/bash "$CLI" init --org other --dry-run --dir "$sb/dry" > "$sb/dry.out" 2>&1
check 'dry run no directory' test ! -e "$sb/dry"
check 'dry run no create' test "$(grep -c 'repo create' "$FAKE_GH_LOG")" = 2
if APEXYARD_GH="$sb/missing" /bin/bash "$CLI" init --dir "$sb/missing-dir" > "$sb/missing.out" 2>&1; then rc=0; else rc=$?; fi
check 'missing gh exit' test "$rc" = 2
check 'missing gh message' grep -q 'required command not found' "$sb/missing.out"
check 'main branch' test "$(git -C "$sb/ops" branch --show-current)" = main
export FAKE_REMOTE="$sb/branch.git" APEXYARD_FRAMEWORK_REF=main
echo new > "$sb/fixture/new.txt"
git -C "$sb/fixture" add -- new.txt
git -C "$sb/fixture" commit -m newer >/dev/null
check 'branch ref succeeds' /bin/bash "$CLI" init --org other --dir "$sb/branch" > "$sb/branch.out" 2>&1
check 'branch version' test "$(cat "$sb/branch/.claude/framework-version")" = "$(git -C "$sb/fixture" describe --tags --always)"
finish
