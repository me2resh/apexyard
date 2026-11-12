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
check 'company left for onboarding' grep -q 'name: "Your Company Name"' "$sb/ops/onboarding.yaml"
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
check 'next step doctor' grep -q "1. Run 'apexyard doctor'." "$sb/public.out"
check 'next step open' grep -Fq "2. Run: cd $sb/public && claude /onboard" "$sb/public.out"
check 'next step windows' grep -q '3. On Windows, use Git Bash or WSL.' "$sb/public.out"
check 'no agent start without wizard' test ! -e "$FAKE_AGENT_LOG"
if /bin/bash "$CLI" init --org other --name ops --dir "$sb/ops" > "$sb/refuse.out" 2>&1; then rc=0; else rc=$?; fi
check 'refuse nonempty' test "$rc" = 2
check 'refusal reason' grep -q 'not empty' "$sb/refuse.out"
check 'dry run succeeds' /bin/bash "$CLI" init --org other --name other-ops --dry-run --dir "$sb/dry" > "$sb/dry.out" 2>&1
check 'dry run no directory' test ! -e "$sb/dry"
check 'dry run no create' test "$(grep -c 'repo create' "$FAKE_GH_LOG")" = 2
if APEXYARD_GH="$sb/missing" /bin/bash "$CLI" init --org other --name ops --dir "$sb/missing-dir" > "$sb/missing.out" 2>&1; then rc=0; else rc=$?; fi
check 'missing gh exit' test "$rc" = 2
check 'missing gh message' grep -q 'required command not found' "$sb/missing.out"
creates=$(grep -c 'repo create' "$FAKE_GH_LOG")
if /bin/bash "$CLI" init --dir "$sb/notty-both" < /dev/null > "$sb/notty-both.out" 2>&1; then rc=0; else rc=$?; fi
check 'no terminal exit' test "$rc" = 2
check 'no terminal names org' grep -q -- '--org' "$sb/notty-both.out"
check 'no terminal names name' grep -q -- '--name' "$sb/notty-both.out"
check 'no terminal no prompt' test "$(grep -Ec 'Repository name|Create it\?' "$sb/notty-both.out" || true)" = 0
check 'no terminal no folder' test ! -e "$sb/notty-both"
if /bin/bash "$CLI" init --org other --dir "$sb/notty-name" < /dev/null > "$sb/notty-name.out" 2>&1; then rc=0; else rc=$?; fi
check 'no terminal one missing exit' test "$rc" = 2
check 'no terminal omits given flag' test "$(grep -c -- '--org' "$sb/notty-name.out" || true)" = 0
check 'no terminal names missing flag' grep -q -- '--name' "$sb/notty-name.out"
check 'no terminal creates nothing' test "$(grep -c 'repo create' "$FAKE_GH_LOG")" = "$creates"
check 'main branch' test "$(git -C "$sb/ops" branch --show-current)" = main
export FAKE_REMOTE="$sb/branch.git" APEXYARD_FRAMEWORK_REF=main
echo new > "$sb/fixture/new.txt"
git -C "$sb/fixture" add -- new.txt
git -C "$sb/fixture" commit -m newer >/dev/null
check 'branch ref succeeds' /bin/bash "$CLI" init --org other --name branch-ops --dir "$sb/branch" > "$sb/branch.out" 2>&1
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
check 'retried values in plan' grep -q 'Create the private GitHub repo acme/ops3' "$sb/validated.out"
if /bin/bash "$CLI" init -i --org acme --name x --private --dir "$sb/confirm-eof" --agent codex < /dev/null > "$sb/confirm-eof.out" 2> "$sb/confirm-eof.err"; then rc=0; else rc=$?; fi
check 'confirmation eof exit' test "$rc" = 2
check 'confirmation eof reason' grep -q 'no answer for Create it?' "$sb/confirm-eof.err"
/bin/bash "$CLI" init -i -y --dry-run --dir "$sb/short-yes" < /dev/null > "$sb/short-yes.out" 2> "$sb/short-yes.err"
check 'short yes skips prompts' test ! -s "$sb/short-yes.err"
if printf '\n\n\n\nN\n' | /bin/bash "$CLI" init -i --dir "$sb/cancel-upper" > "$sb/cancel-upper.out" 2> "$sb/cancel-upper.err"; then rc=0; else rc=$?; fi
check 'capital N cancels' grep -q 'Nothing created.' "$sb/cancel-upper.out"
check 'capital N no folder' test ! -e "$sb/cancel-upper"
printf '\n\n\n~/tilde-ops\n\n' | /bin/bash "$CLI" init -i --dry-run > "$sb/tilde.out" 2> "$sb/tilde.err"
check 'tilde folder expands' grep -Fq "into $HOME/tilde-ops." "$sb/tilde.out"
mkdir -p "$HOME/full"
echo x > "$HOME/full/file"
printf '\n\n\n~/full\n~/empty-ops\n\n' | /bin/bash "$CLI" init -i --dry-run > "$sb/tilde-retry.out" 2> "$sb/tilde-retry.err"
check 'tilde non-empty asks again' grep -q 'target directory is not empty' "$sb/tilde-retry.err"
check 'tilde retry in plan' grep -Fq "into $HOME/empty-ops." "$sb/tilde-retry.out"
export FAKE_REMOTE="$sb/no-newline.git"
printf '\n\n\n%s\n\ny' "$sb/no-newline" | /bin/bash "$CLI" init -i > "$sb/no-newline.out" 2> "$sb/no-newline.err" || true
check 'last answer without newline' test -d "$sb/no-newline/.git"
check 'intro in wizard' grep -Fq 'ApexYard init creates your ops repo.' "$sb/defaults.err"
check 'intro not in non-wizard' test "$(grep -c 'ApexYard init creates your ops repo.' "$sb/init.out" || true)" = 0
check 'plan download' grep -Fq "1. Download ApexYard (main) into $sb/skipped." "$sb/skipped.out"
check 'plan history reason' grep -Fq 'You get the full framework history, so updates can merge cleanly.' "$sb/skipped.out"
check 'plan link' grep -Fq "2. Link your copy to the framework repo as 'upstream'." "$sb/skipped.out"
check 'plan update reason' grep -Fq "'apexyard update' uses this link to bring in new versions." "$sb/skipped.out"
check 'plan create' grep -Fq '3. Create the private GitHub repo acme/x and upload your copy.' "$sb/skipped.out"
check 'plan not fork' grep -Fq 'This repo is yours. It is not a fork.' "$sb/skipped.out"
check 'plan local files' grep -Fq '4. Create two local setup files: onboarding.yaml and apexyard.projects.yaml.' "$sb/skipped.out"
check 'plan local reason' grep -Fq 'They stay on this computer until you commit them.' "$sb/skipped.out"
check 'plan no rename jargon' test "$(grep -c 'Rename origin' "$sb/skipped.out" || true)" = 0
for n in 1 2 3 4; do
  check "progress $n" grep -Fq "[$n/4]" "$sb/init.out"
done
check 'done message' grep -Fq "Done. Your ops repo is example-org/ops, in $sb/ops." "$sb/init.out"
export FAKE_GH_EXISTING="$sb/existing"
echo 'acme/taken' > "$FAKE_GH_EXISTING"
export FAKE_GH_CHECK_TARGET="$sb/name-retry"
printf 'taken\nfresh\n' | /bin/bash "$CLI" init -i --org acme --private --dir "$sb/name-retry" --agent codex --dry-run > "$sb/name-retry.out" 2> "$sb/name-retry.err"
check 'taken wizard message' grep -Fq 'acme/taken already exists on GitHub. Choose a different name.' "$sb/name-retry.err"
check 'fresh wizard plan' grep -Fq 'GitHub repo acme/fresh and upload your copy.' "$sb/name-retry.out"
check 'retry checked before clone' test "$(grep -c 'view: target absent' "$FAKE_GH_LOG")" -ge 2
check 'retry no early clone' test "$(grep -c 'view: target exists' "$FAKE_GH_LOG" || true)" = 0
unset FAKE_GH_CHECK_TARGET
creates=$(grep -c 'repo create' "$FAKE_GH_LOG")
if /bin/bash "$CLI" init --org acme --name taken --dir "$sb/taken" > "$sb/taken.out" 2>&1; then rc=0; else rc=$?; fi
check 'taken non-wizard exit' test "$rc" = 2
check 'taken non-wizard message' grep -Fq 'acme/taken already exists on GitHub. Choose a different name.' "$sb/taken.out"
check 'taken no folder' test ! -e "$sb/taken"
check 'taken no create' test "$(grep -c 'repo create' "$FAKE_GH_LOG")" = "$creates"
if /bin/bash "$CLI" init -i --org acme --name taken --private --dir "$sb/taken-flags" --agent codex --dry-run > "$sb/taken-flags.out" 2>&1; then rc=0; else rc=$?; fi
check 'taken wizard flags exit' test "$rc" = 2
check 'taken wizard flags no plan' test "$(grep -c 'This is what will happen:' "$sb/taken-flags.out" || true)" = 0
unset FAKE_GH_EXISTING
export FAKE_GH_FAIL_CREATE=1
if /bin/bash "$CLI" init --org acme --name fresh --dir "$sb/create-fail" > "$sb/create-fail.out" 2>&1; then rc=0; else rc=$?; fi
check 'create failure exit' test "$rc" -ne 0
check 'create failure removes new folder' test ! -e "$sb/create-fail"
check 'create failure message' grep -Fq "Init stopped at step 3. It removed $sb/create-fail. Nothing was created on GitHub." "$sb/create-fail.out"
unset FAKE_GH_FAIL_CREATE
if FAKE_GH_FAIL_PUSH=1 /bin/bash "$CLI" init --org acme --name pushfail --dir "$sb/push-fail" > "$sb/push-fail.out" 2>&1; then rc=0; else rc=$?; fi
check 'push failure exit' test "$rc" -ne 0
check 'push failure keeps folder' test -d "$sb/push-fail/.git"
check 'push failure message' grep -Fq "The GitHub repo acme/pushfail exists, but the upload failed. It kept $sb/push-fail." "$sb/push-fail.out"
check 'push failure next step' grep -Fq "Finish with: cd $sb/push-fail && git push -u origin main" "$sb/push-fail.out"
check 'push failure no nothing-created claim' test "$(grep -c 'Nothing was created' "$sb/push-fail.out" || true)" = 0
export FAKE_GH_FAIL_CREATE=1
mkdir "$sb/existing-target"
if /bin/bash "$CLI" init --org acme --name fresh --dir "$sb/existing-target" > "$sb/existing-target.out" 2>&1; then rc=0; else rc=$?; fi
check 'existing target failure exit' test "$rc" -ne 0
check 'existing target kept' test -d "$sb/existing-target/.git"
unset FAKE_GH_FAIL_CREATE
# Missing setup input fails only after the remote has been created.
git -C "$sb/fixture" rm onboarding.example.yaml >/dev/null
git -C "$sb/fixture" commit -m 'missing setup fixture' >/dev/null
export FAKE_REMOTE="$sb/setup-fail.git"
if /bin/bash "$CLI" init --org acme --name fresh --dir "$sb/setup-fail" > "$sb/setup-fail.out" 2>&1; then rc=0; else rc=$?; fi
check 'setup failure exit' test "$rc" -ne 0
check 'setup failure keeps local repo' test -d "$sb/setup-fail/.git"
check 'setup failure keeps remote' test -d "$FAKE_REMOTE"
check 'setup failure recovery' grep -Fq "Init stopped at step 4. The GitHub repo acme/fresh exists. Finish with: cd $sb/setup-fail and run /onboard." "$sb/setup-fail.out"
unset FAKE_GH_FAIL_CREATE FAKE_GH_EXISTING
# Restore the setup input that the failure row removed.
printf 'company:\n  name: "Your Company Name"\nteam:\n  - name: "Your Name"\n' > "$sb/fixture/onboarding.example.yaml"
git -C "$sb/fixture" add -- onboarding.example.yaml
git -C "$sb/fixture" commit -m 'restore setup fixture' >/dev/null
export FAKE_REMOTE="$sb/handoff.git"
printf 'y\ny\n' | GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0='Test Owner' \
  /bin/bash "$CLI" init -i --org acme --name handoff --private --dir "$sb/handoff" --agent claude > "$sb/handoff.out" 2> "$sb/handoff.err" || true
check 'handoff question' grep -Fq 'Open it in Claude now and start /onboard?' "$sb/handoff.err"
check 'handoff starts onboard in repo' grep -Fxq "$sb/handoff /onboard" "$FAKE_AGENT_LOG"
check 'owner name written' grep -q '  - name: "Test Owner"' "$sb/handoff/onboarding.yaml"
check 'handoff company placeholder' grep -q 'name: "Your Company Name"' "$sb/handoff/onboarding.yaml"
export FAKE_REMOTE="$sb/nohandoff.git"
printf 'y\nn\n' | /bin/bash "$CLI" init -i --org acme --name nohandoff --private --dir "$sb/nohandoff" --agent claude > "$sb/nohandoff.out" 2> "$sb/nohandoff.err" || true
check 'handoff declined' test "$(grep -c nohandoff "$FAKE_AGENT_LOG" || true)" = 0
check 'handoff declined next steps' grep -Fq "Run: cd $sb/nohandoff && claude /onboard" "$sb/nohandoff.out"
export FAKE_REMOTE="$sb/codexhand.git"
printf 'y\n' | /bin/bash "$CLI" init -i --org acme --name codexhand --private --dir "$sb/codexhand" --agent codex > "$sb/codexhand.out" 2> "$sb/codexhand.err" || true
check 'other agent no question' test "$(grep -c 'Open it in Claude now' "$sb/codexhand.err" || true)" = 0
check 'other agent next step' grep -Fq "2. Open $sb/codexhand in codex and run /onboard." "$sb/codexhand.out"
# Optional install commands are always sandbox fakes.
ln -s "$(command -v jq)" "$sb/tools/jq"
export PATH="$sb/tools:/usr/bin:/bin" FAKE_COCKPIT_LOG="$sb/cockpit.log"
cat > "$sb/tools/pipx" <<'SH'
#!/usr/bin/env bash
printf 'pipx %s\n' "$*" >> "$FAKE_COCKPIT_LOG"
echo fake-secret-must-stay-hidden
exit "${FAKE_PIPX_STATUS:-0}"
SH
cat > "$sb/tools/example-cockpit" <<'SH'
#!/usr/bin/env bash
printf 'cockpit %s\n' "$*" >> "$FAKE_COCKPIT_LOG"
echo fake-secret-must-stay-hidden
exit "${FAKE_SETUP_STATUS:-0}"
SH
chmod +x "$sb/tools/pipx" "$sb/tools/example-cockpit"
check 'flag off output silent' test "$(grep -ic cockpit "$sb/init.out" || true)" = 0
/bin/bash "$CLI" init --help > "$sb/help.out"
check 'flag off help silent' test "$(grep -ic cockpit "$sb/help.out" || true)" = 0
if /bin/bash "$CLI" init --cockpit > "$sb/disabled.out" 2>&1; then rc=0; else rc=$?; fi
check 'disabled option exit' test "$rc" = 2
check 'disabled option message' grep -Fq 'unknown option: --cockpit' "$sb/disabled.out"
export APEXYARD_COCKPIT=1 APEXYARD_COCKPIT_SOURCE=git+https://example.invalid/example-cockpit.git APEXYARD_COCKPIT_CMD=example-cockpit
for mode in yes no default direct install-fail setup-fail missing override unconfigured; do
  export FAKE_REMOTE="$sb/cockpit-$mode.git"
  target="$sb/cockpit-$mode"
  : > "$FAKE_COCKPIT_LOG"
  case "$mode" in
    yes) printf 'y\ny\ny\n' | /bin/bash "$CLI" init -i --org acme --name "$mode" --private --dir "$target" --agent claude > "$target.out" 2>&1 ;;
    no|default)
      answer=n
      [ "$mode" != default ] || answer=''
      printf 'y\n%s\n' "$answer" | /bin/bash "$CLI" init -i --org acme --name "$mode" --private --dir "$target" --agent codex > "$target.out" 2>&1 ;;
    *)
      export FAKE_PIPX_STATUS=0 FAKE_SETUP_STATUS=0
      [ "$mode" != install-fail ] || export FAKE_PIPX_STATUS=1
      [ "$mode" != setup-fail ] || export FAKE_SETUP_STATUS=1
      # Point at a pipx that does not exist. Removing the stub from PATH
      # would let a system pipx in /usr/bin run and reach the network.
      [ "$mode" != missing ] || export APEXYARD_PIPX="$sb/no-such-pipx"
      saved_source=$APEXYARD_COCKPIT_SOURCE
      if [ "$mode" = override ]; then
        export APEXYARD_COCKPIT_SOURCE=git+file:///sandbox/example-cockpit APEXYARD_COCKPIT_TAG=test-tag
      fi
      [ "$mode" != unconfigured ] || unset APEXYARD_COCKPIT_SOURCE APEXYARD_COCKPIT_CMD
      check "$mode exits zero" /bin/bash "$CLI" init --yes --cockpit --org acme --name "$mode" --dir "$target" > "$target.out" 2>&1
      export APEXYARD_COCKPIT_SOURCE=$saved_source APEXYARD_COCKPIT_CMD=example-cockpit
      unset APEXYARD_COCKPIT_TAG APEXYARD_PIPX ;;
  esac
  check "$mode keeps setup" test -f "$target/onboarding.yaml"
  check "$mode next steps" grep -q 'Next:' "$target.out"
  check "$mode output hides child secrets" test "$(grep -c fake-secret "$target.out" || true)" = 0
  case "$mode" in
    no|default|missing|unconfigured) check "$mode skips commands" test ! -s "$FAKE_COCKPIT_LOG" ;;
    override) check 'source and tag overrides' grep -Fxq 'pipx install git+file:///sandbox/example-cockpit@test-tag' "$FAKE_COCKPIT_LOG" ;;
    *) check "$mode pinned source" grep -Fxq 'pipx install git+https://example.invalid/example-cockpit.git@v0.15.2' "$FAKE_COCKPIT_LOG" ;;
  esac
  case "$mode" in
    yes|direct|setup-fail|override) check "$mode setup folders" grep -Fxq "cockpit setup --ops $target --portfolio $target" "$FAKE_COCKPIT_LOG" ;;
  esac
  case "$mode" in
    unconfigured) check 'not configured message' grep -q 'it is not configured' "$target.out" ;;
    missing) check 'missing pipx guidance' grep -q 'pipx is missing. Install pipx' "$target.out" ;;
    install-fail) check 'access guidance' grep -q 'Request access to the Cockpit package' "$target.out"
      check 'failed install skips setup' test "$(grep -c '^cockpit' "$FAKE_COCKPIT_LOG" || true)" = 0 ;;
    setup-fail) check 'setup guidance' grep -q 'Cockpit setup failed.' "$target.out" ;;
    yes) check 'handoff after install' grep -Fxq "$target /onboard" "$FAKE_AGENT_LOG"
      check 'exact install question' grep -Fq 'Install the Cockpit too? [y/N]' "$target.out" ;;
  esac
  check "$mode argv has no secret" test "$(grep -c fake-secret "$FAKE_COCKPIT_LOG" || true)" = 0
done
unset APEXYARD_COCKPIT APEXYARD_COCKPIT_SOURCE APEXYARD_COCKPIT_CMD FAKE_PIPX_STATUS FAKE_SETUP_STATUS
if FAKE_GH_OFFLINE=1 FAKE_GH_ORIGIN_FAIL=1 /bin/bash "$CLI" init --org acme --name offline --dir "$sb/offline" > "$sb/offline.out" 2>&1; then rc=0; else rc=$?; fi
check 'offline push failure exit' test "$rc" -ne 0
check 'offline origin keeps clone' test -d "$sb/offline/.git"
check 'offline recovery guidance' grep -Fq 'git push -u origin main' "$sb/offline.out"

finish
