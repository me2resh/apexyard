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
check 'next step doctor' grep -q '1. Run apexyard doctor.' "$sb/public.out"
check 'next step open' grep -q "2. Open $sb/public in your coding agent." "$sb/public.out"
check 'next step setup' grep -q '3. Run /setup.' "$sb/public.out"
check 'next step windows' grep -q '4. On Windows, use Git Bash or WSL.' "$sb/public.out"
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
# Each wizard run uses its own local remote and target.
export FAKE_REMOTE="$sb/defaults.git"
printf '\n\n\n\n\n' | /bin/bash "$CLI" init -i --dir "$sb/defaults" > "$sb/defaults.out" 2> "$sb/defaults.err"
check 'wizard defaults create' grep -q 'repo create example-org/ops --private' "$FAKE_GH_LOG"
check 'wizard defaults folder' test -d "$sb/defaults/.git"
check 'org choices' grep -q 'Your account: example-org. Your organisations: acme, beta.' "$sb/defaults.err"
check 'wizard question default' grep -Fq 'Repository name [ops]' "$sb/defaults.err"
export FAKE_REMOTE="$sb/answers.git"
printf 'acme\nteam-ops\nPUBLIC\n%s\ncodex\ny\n' "$sb/answers" | /bin/bash "$CLI" init --interactive > "$sb/answers.out" 2> "$sb/answers.err"
check 'wizard answers create' grep -q 'repo create acme/team-ops --public' "$FAKE_GH_LOG"
check 'wizard answers folder' test -d "$sb/answers/.git"
creates=$(grep -c 'repo create' "$FAKE_GH_LOG")
if printf '\n\n\n\nno\n' | /bin/bash "$CLI" init -i --dir "$sb/cancel" > "$sb/cancel.out" 2> "$sb/cancel.err"; then rc=0; else rc=$?; fi
check 'cancel exit' test "$rc" = 0
check 'cancel message' grep -q 'Nothing created.' "$sb/cancel.out"
check 'cancel no create' test "$(grep -c 'repo create' "$FAKE_GH_LOG")" = "$creates"
check 'cancel no folder' test ! -e "$sb/cancel"
export FAKE_REMOTE="$sb/retry.git"
printf '\nbad name!\nops2\n\n\n\ny\n' | /bin/bash "$CLI" init -i --dir "$sb/retry" > "$sb/retry.out" 2> "$sb/retry.err"
check 'invalid name reason' grep -q 'invalid repository name' "$sb/retry.err"
check 'valid name after retry' grep -q 'repo create example-org/ops2 --private' "$FAKE_GH_LOG"
if printf '\n' | /bin/bash "$CLI" init -i --dir "$sb/eof" > "$sb/eof.out" 2> "$sb/eof.err"; then rc=0; else rc=$?; fi
check 'wizard eof exit' test "$rc" = 2
check 'wizard eof reason' grep -q 'no answer for Repository name' "$sb/eof.err"
check 'wizard eof no folder' test ! -e "$sb/eof"
printf '\n\n' | /bin/bash "$CLI" init -i --org acme --name x --dir "$sb/skipped" --dry-run > "$sb/skipped.out" 2> "$sb/skipped.err"
check 'flag skips org question' test "$(grep -c 'GitHub account or organisation for the new repo' "$sb/skipped.err" || true)" = 0
check 'flag skips name question' test "$(grep -c 'Repository name' "$sb/skipped.err" || true)" = 0
check 'dry run skips confirmation' test "$(grep -c 'Create it?' "$sb/skipped.err" || true)" = 0
check 'wizard dry run no folder' test ! -e "$sb/skipped"
export FAKE_REMOTE="$sb/yes.git"
/bin/bash "$CLI" init --yes --interactive --dir "$sb/yes" < /dev/null > "$sb/yes.out" 2> "$sb/yes.err"
check 'yes creates' test -d "$sb/yes/.git"
check 'yes skips prompts' test "$(grep -Ec 'Repository name|Create it\?|GitHub account or organisation' "$sb/yes.err" || true)" = 0
check 'piped default no prompts' test "$(grep -Ec 'Repository name|Create it\?|GitHub account or organisation' "$sb/init.out" || true)" = 0
printf 'bad org!\nacme\nops3\ninvalid\nprivate\n%s\n%s\ninvalid\npi\n' "$sb/ops" "$sb/validated" | /bin/bash "$CLI" init -i --dry-run > "$sb/validated.out" 2> "$sb/validated.err"
check 'invalid org reason' grep -q 'invalid organisation name' "$sb/validated.err"
check 'invalid visibility reason' grep -q 'enter private or public' "$sb/validated.err"
check 'invalid folder reason' grep -q 'target directory is not empty' "$sb/validated.err"
check 'invalid agent reason' grep -q 'invalid agent: invalid' "$sb/validated.err"
check 'retried values in plan' grep -q 'Create acme/ops3 --private' "$sb/validated.out"
if /bin/bash "$CLI" init -i --org acme --name x --private --dir "$sb/confirm-eof" --agent codex < /dev/null > "$sb/confirm-eof.out" 2> "$sb/confirm-eof.err"; then rc=0; else rc=$?; fi
check 'confirmation eof exit' test "$rc" = 2
check 'confirmation eof reason' grep -q 'no answer for Create it?' "$sb/confirm-eof.err"
/bin/bash "$CLI" init -i -y --dry-run --dir "$sb/short-yes" < /dev/null > "$sb/short-yes.out" 2> "$sb/short-yes.err"
check 'short yes skips prompts' test ! -s "$sb/short-yes.err"
if printf '\n\n\n\nN\n' | /bin/bash "$CLI" init -i --dir "$sb/cancel-upper" > "$sb/cancel-upper.out" 2> "$sb/cancel-upper.err"; then rc=0; else rc=$?; fi
check 'capital N cancels' grep -q 'Nothing created.' "$sb/cancel-upper.out"
check 'capital N no folder' test ! -e "$sb/cancel-upper"
printf '\n\n\n~/tilde-ops\n\n' | /bin/bash "$CLI" init -i --dry-run > "$sb/tilde.out" 2> "$sb/tilde.err"
check 'tilde folder expands' grep -Fq "into $HOME/tilde-ops with" "$sb/tilde.out"
mkdir -p "$HOME/full"
echo x > "$HOME/full/file"
printf '\n\n\n~/full\n~/empty-ops\n\n' | /bin/bash "$CLI" init -i --dry-run > "$sb/tilde-retry.out" 2> "$sb/tilde-retry.err"
check 'tilde non-empty asks again' grep -q 'target directory is not empty' "$sb/tilde-retry.err"
check 'tilde retry in plan' grep -Fq "into $HOME/empty-ops with" "$sb/tilde-retry.out"
export FAKE_REMOTE="$sb/no-newline.git"
printf '\n\n\n%s\n\ny' "$sb/no-newline" | /bin/bash "$CLI" init -i > "$sb/no-newline.out" 2> "$sb/no-newline.err" || true
check 'last answer without newline' test -d "$sb/no-newline/.git"
finish
