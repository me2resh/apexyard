#!/bin/bash
# Review fixes for the protected-target gate (me2resh/apexyard#1806, PR review):
# redirect operators of three characters, case variants of every protected
# path, read-only xargs and find shapes, and the ConfigChange hook with no root.
# Each block case has a paired allow case.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/_test-protected-state.sh"
GATE="$ROOT/block-protected-target-writes.sh"
mkdir -p "$TMP/temp" "$TMP/live/.claude/worktrees/wt/.claude/hooks" "$TMP/live/.git"
touch "$TMP/live/.claude/worktrees/wt/.claude/hooks/x.sh" "$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude/session-env" "$HOME/.claude/shell-snapshots"
mkdir -p "$TMP/live/.claude/worktrees/wt/.git"
run_bash() {
  jq -cn --arg cwd "${CASE_CWD:-$TMP/live}" --arg cmd "$1" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}' | /bin/bash "$GATE"
}
run_edit() {
  jq -cn --arg cwd "$TMP/live" --arg file "$2" --arg tool "$1" '{tool_name:$tool,cwd:$cwd,tool_input:{file_path:$file}}' | /bin/bash "$GATE"
}
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
mixed() { printf '%s' "$1" | awk '{o="";for(i=1;i<=length($0);i++){c=substr($0,i,1);o=o ((i%2)?toupper(c):c)}print o}'; }

# 1. Redirect operators of three characters, at top level and in a nested shell.
for op in '>!' '>>!' '>>|' '&>>' '&>!' '&>|' '&>>!' '&>>|' '>>&' '>&!' '>&|' '>>&!' '>>&|'; do
  check 2 "redirect $op settings" run_bash "echo x $op .claude/settings.json"
  check 2 "redirect $op hook script" run_bash "echo x $op .claude/hooks/x.sh"
  check 2 "redirect $op absolute hook script" run_bash "echo x $op $TMP/live/.claude/hooks/x.sh"
  check 2 "redirect $op nested bash" run_bash "bash -c 'echo x $op .claude/hooks/x.sh'"
  check 2 "redirect $op nested zsh" run_bash "zsh -c 'echo x $op .claude/settings.json'"
  check 2 "redirect $op in a subshell" run_bash "(echo x $op .claude/hooks/x.sh)"
  check 0 "redirect $op scratch file" run_bash "echo x $op $TMP/temp/out.txt"
  check 0 "redirect $op nested scratch file" run_bash "bash -c 'echo x $op $TMP/temp/out.txt'"
  check 0 "redirect $op scratch file in the live root" run_bash "echo x $op out.txt"
done
# 1b. The bash reading of a "!" operator. Bash takes the "!" as the first
# character of the target word, or as a file named "!" when a space follows.
# Zsh takes it as the clobber suffix (section 1). The gate judges both.
mkdir -p "$TMP/live/!"
for op in '>!' '>>!' '&>!' '&>>!' '>&!' '>>&!' '1>!' '2>>!'; do
  check 2 "bash reading $op hook script" run_bash "echo x $op/../.claude/hooks/x.sh"
  check 2 "bash reading $op settings" run_bash "echo x $op/../.claude/settings.json"
  check 2 "bash reading $op nested bash" run_bash "bash -c 'echo x $op/../.claude/hooks/x.sh'"
  check 2 "bash reading $op nested sh" run_bash "sh -c 'echo x $op/../.claude/hooks/x.sh'"
  check 2 "zsh reading $op nested zsh" run_bash "zsh -c 'echo x $op .claude/hooks/x.sh'"
  check 0 "bash reading $op scratch file" run_bash "echo x $op/../out.txt"
  check 0 "bash reading $op nested bash scratch file" run_bash "bash -c 'echo x $op/../out.txt'"
  check 0 "bash reading $op nested sh scratch file" run_bash "sh -c 'echo x $op/../out.txt'"
done
check 2 'bash reading, upper case' run_bash 'echo x >!/../.CLAUDE/HOOKS/x.sh'
check 0 'quoted bang is part of the word' run_bash 'echo x >"!"/../out.txt'
CASE_CWD="$TMP/live/.claude/hooks"
check 2 'spaced form writes a file named ! in the hooks folder' run_bash "echo x >! $TMP/temp/out.txt"
check 2 'bang operator at the end writes a file named ! in the hooks folder' run_bash 'echo x >!'
check 2 'nested bash spaced form in the hooks folder' run_bash "bash -c 'echo x >! $TMP/temp/out.txt'"
CASE_CWD="$TMP/temp"
check 0 'spaced form from a scratch folder' run_bash "echo x >! $TMP/temp/out.txt"
check 0 'bang operator at the end from a scratch folder' run_bash 'echo x >!'
check 0 'plain redirect from a scratch folder' run_bash "echo x > $TMP/temp/out.txt"
CASE_CWD="$TMP/live"
check 0 'two-char append still allowed for scratch' run_bash "echo x >> $TMP/temp/out.txt"
check 2 'two-char append still blocks a hook' run_bash 'echo x >> .claude/hooks/x.sh'
check 0 'fd duplication is not a file target' run_bash 'echo x 2>&1'
check 2 'fd-numbered clobber form' run_bash 'echo x 2>! .claude/settings.json'
check 0 'fd-numbered clobber form to a scratch file' run_bash "echo x 2>! $TMP/temp/out.txt"
check 0 'fd duplication before a pipe' run_bash 'echo x 2>&1| cat'

# 2. Case variants of every protected path.
paths=(
  "$TMP/live/.claude/settings.json" "$TMP/live/.claude/settings.local.json" "$TMP/live/.claude/hooks/x.sh"
  "$HOME/.claude/settings.json" "$HOME/.claude/session-env/x" "$HOME/.claude/shell-snapshots/x"
  "$APEXYARD_OPS_PIN_DIR/ops-root-d17" "$APEXYARD_OPS_PIN_DIR/gate-session-d17/snapshot.json"
)
for path in "${paths[@]}"; do
  for form in "$(upper "$path")" "$(mixed "$path")"; do
    check 2 "edit case variant $form" run_edit Write "$form"
    check 2 "redirect case variant $form" run_bash "echo x > $form"
    check 2 "cp case variant $form" run_bash "cp /tmp/x $form"
    check 2 "tee case variant $form" run_bash "echo x | tee $form"
    check 2 "sed -i case variant $form" run_bash "sed -i s/a/b/ $form"
    check 2 "chmod case variant $form" run_bash "chmod -x $form"
    check 2 "rm case variant $form" run_bash "rm -f $form"
  done
done
check 2 'recursive removal of the hooks directory, upper case' run_bash "rm -rf $(upper "$TMP/live/.claude/hooks")"
check 2 'recursive removal of the hooks directory, relative upper case' run_bash 'rm -rf .CLAUDE/HOOKS'
check 2 'move of the hooks directory, mixed case' run_bash "mv $(mixed "$TMP/live/.claude/hooks") /tmp/h"
check 2 'interpreter write with an upper-case token' run_bash "python3 -c \"open('.CLAUDE/HOOKS/x.sh','w').write('x')\""
check 2 'harness writer name, upper case' run_bash 'bash .claude/hooks/PIN-OPS-ROOT.SH'
check 2 'harness writer name, mixed case' run_bash 'bash .claude/hooks/Dispatch-Session-Start.sh'
check 2 'sandbox pin tree that is a case variant of the live pin tree' run_bash "APEXYARD_OPS_PIN_DIR=$(upper "$APEXYARD_OPS_PIN_DIR") bash .claude/hooks/pin-ops-root.sh"
check 0 'harness writer with a real sandbox' run_bash "APEXYARD_OPS_PIN_DIR=$TMP/temp/sb bash .claude/hooks/pin-ops-root.sh"
check 0 'edit of an unrelated path, upper case' run_edit Write "$(upper "$TMP/temp/x.sh")"
check 0 'edit of an unrelated path, mixed case' run_edit Write "$(mixed "$TMP/temp/x.sh")"
check 0 'redirect to an unrelated path, upper case' run_bash "echo x > $(upper "$TMP/temp/x.txt")"
check 0 'cp to an unrelated path, mixed case' run_bash "cp /tmp/x $(mixed "$TMP/temp/x.txt")"
check 0 'edit of a worktree hook script, upper case' run_edit Write "$(upper "$TMP/live/.claude/worktrees/wt/.claude/hooks/x.sh")"

# Option and verb tests stay case-sensitive. Only protected-form tests ignore case.
check 2 'tar -c is not tar -C' run_bash 'tar -c -f .claude/settings.json .'
check 0 'tar -c into a scratch archive' run_bash "tar -c -f $TMP/temp/x.tar ."
check 2 'git -c is not git -C' run_bash 'git -c core.x=y checkout -- .claude/hooks/x.sh'
check 0 'git -c with a read-only verb' run_bash 'git -c core.x=y status'

# 2b. The -f flag takes no value for rm, cp, mv and chmod. The operand after it
# is still judged. tar keeps its archive value.
check 2 'rm -f hook script' run_bash 'rm -f .claude/hooks/x.sh'
check 2 'rm -f settings file' run_bash 'rm -f .claude/settings.json'
check 2 'cp -f onto a hook script' run_bash 'cp -f /tmp/x .claude/hooks/x.sh'
check 2 'mv -f a hook script away' run_bash 'mv -f .claude/hooks/x.sh /tmp/x.sh'
check 2 'chmod -f on a hook script' run_bash 'chmod -f -x .claude/hooks/x.sh'
check 0 'rm -f scratch file' run_bash "rm -f $TMP/temp/x.txt"
check 0 'cp -f onto scratch file' run_bash "cp -f /tmp/x $TMP/temp/x.txt"
check 0 'tar -f archive into scratch' run_bash "tar -cf $TMP/temp/x.tar -C $TMP/temp ."

# 3. Read-only xargs and find shapes. A worktree under .claude/worktrees is not
# protected state. The live root keeps its protection.
CASE_CWD="$TMP/live/.claude/worktrees/wt"
check 0 'worktree: xargs grep' run_bash 'git ls-files | xargs grep -n foo'
check 0 'worktree: find -exec grep' run_bash "find . -name '*.md' -exec grep -l foo {} +"
check 0 'worktree: find piped to xargs wc' run_bash "find . -type f -name '*.sh' | xargs wc -l"
check 0 'worktree: find -exec shellcheck' run_bash "find . -name '*.sh' -exec shellcheck {} +"
check 2 'worktree: cd to the live hooks, then xargs rm' run_bash 'cd ../../hooks && printf x | xargs rm'
check 2 'worktree: write to the live hook script by path' run_bash "echo x > $TMP/live/.claude/hooks/x.sh"
check 2 'worktree: find the live hooks, then rm' run_bash "find $TMP/live/.claude/hooks -exec rm {} +"
CASE_CWD="$TMP/live"
check 0 'live root: find -exec grep' run_bash "find . -name '*.md' -exec grep -l foo {} +"
check 0 'live root: find -exec shellcheck' run_bash "find . -name '*.sh' -exec shellcheck {} +"
check 0 'live root: find -exec wc' run_bash "find docs -name '*.md' -exec wc -l {} \\;"
check 0 'live root: find -exec grep after another primary' run_bash "find . -type f -exec cat {} + -exec grep -l foo {} +"
check 2 'live root: find -exec rm on the root' run_bash "find . -name '*.md' -exec rm {} +"
check 2 'live root: find -exec rm on the claude folder' run_bash "find .claude -exec rm {} \\;"
check 2 'live root: find -exec of an unknown verb on the root' run_bash "find . -exec sh -c 'x' {} +"
check 2 'live root: find -execdir chmod' run_bash "find .claude/hooks -execdir chmod -x {} +"
check 2 'live root: a read-only exec followed by rm' run_bash "find . -exec grep -l foo {} + -exec rm {} +"
CASE_CWD="$TMP/live/.claude"
check 2 'claude folder: xargs rm' run_bash 'ls | xargs rm'
CASE_CWD="$TMP/live"

# 4. ConfigChange with no pin and no project directory (bash 3.2 unbound array).
cc_no_roots() {
  jq -cn --arg f "$HOME/.claude/settings.json" '{session_id:"nopin",source:"user_settings",file_path:$f}' \
    | env -u CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID=nopin /bin/bash "$ROOT/block-hook-disabling-config-change.sh"
}
printf '{"permissions":{"allow":["Read"]}}\n' > "$HOME/.claude/settings.json"
check 0 'ConfigChange with no roots: permission change' cc_no_roots
printf '{"disableAllHooks":true}\n' > "$HOME/.claude/settings.json"
check 2 'ConfigChange with no roots: disableAllHooks' cc_no_roots
printf '{}\n' > "$HOME/.claude/settings.json"

# 5. Pin tree narrowing and find -fls (#1858).
mkdir -p "$APEXYARD_OPS_PIN_DIR/private/briefs" "$APEXYARD_OPS_PIN_DIR/private/probes"
check 0 'private briefs write passes' run_bash "echo x > $APEXYARD_OPS_PIN_DIR/private/briefs/b.md"
check 0 'private probes write passes' run_bash "echo x > $APEXYARD_OPS_PIN_DIR/private/probes/p.txt"
check 0 'private briefs write by home path passes' run_bash 'echo x > $HOME/.claude/apexyard/private/briefs/b.md'
check 2 'pin file write blocks' run_bash "echo x > $APEXYARD_OPS_PIN_DIR/ops-root-zz"
check 2 'gate state write blocks' run_bash "echo x > $APEXYARD_OPS_PIN_DIR/gate-session-zz/snapshot.json"
check 2 'gate state write by home path blocks' run_bash 'echo x > $HOME/.claude/apexyard/gate-session-zz/snapshot.json'
check 2 'resolve cache write blocks' run_bash "echo x > $APEXYARD_OPS_PIN_DIR/resolve-cache-zz"
check 2 'projctx write blocks' run_bash "echo x > $APEXYARD_OPS_PIN_DIR/projctx/a"
check 2 'find -fls into a protected file blocks' run_bash "find . -fls .claude/hooks/x.sh"
check 0 'find -fls into a scratch file passes' run_bash "find . -fls $TMP/temp/ls.txt"

# 6. The ConfigChange live-file test ignores letter case (#1858).
if [ -e "$TMP/live/.CLAUDE/settings.json" ]; then
  printf '{"hooks":{"PreToolUse":[]}}\n' > "$TMP/live/.claude/settings.json"
  mkdir -p "$TMP/live/.claude/session"
  : > "$TMP/live/.claude/session/config-change-blocks.jsonl"
  jq -cn --arg f "$TMP/live/.CLAUDE/SETTINGS.JSON" '{session_id:"d17",source:"project_settings",file_path:$f}' | /bin/bash "$ROOT/block-hook-disabling-config-change.sh" >/dev/null 2>&1 || :
  # Only the live branch reads the tracked baseline. The not-live branch logs allow or "committed copy".
  check 0 'case variant of a live settings file is judged live' grep -q 'tracked settings baseline' "$TMP/live/.claude/session/config-change-blocks.jsonl"
  printf '{}\n' > "$TMP/live/.claude/settings.json"
fi
finish
