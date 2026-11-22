#!/bin/bash
# agy hook wiring is a protected target in the live fork root (AgDR-0314).
#
# .agents/hooks.json, the agy plugin files, harness-adapters/agy/, and
# bin/sync-agy-adapter.sh can each switch the gates off under agy, or run
# another hook beside them. block-protected-target-writes.sh must deny Write,
# Edit, MultiEdit and Bash changes to them in the live root, as for
# .claude/hooks/. An isolated worktree stays editable. The generator, run
# through Bash, still passes, because the gate judges the command text, not
# the script's own writes.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d)
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
L="$TMP/live"
S="$TMP/scratch"
W="$L/.claude/worktrees/wt"
export HOME="$TMP/home" CLAUDE_PROJECT_DIR="$L" CLAUDE_CODE_SESSION_ID=agywiring
export APEXYARD_OPS_PIN_DIR="$HOME/.claude/apexyard"
mkdir -p "$HOME/.claude" "$APEXYARD_OPS_PIN_DIR" "$L/.claude/hooks" "$L/.git" "$S/.git" "$W"
touch "$L/.apexyard-fork"
printf '%s\n' "$L" > "$APEXYARD_OPS_PIN_DIR/ops-root-agywiring"
printf '{}\n' > "$L/.claude/settings.json"

PASS=0 FAIL=0
check() {
  local want="$1" label="$2" rc=0
  shift 2
  "$@" > "$TMP/out" 2> "$TMP/err" || rc=$?
  if [ "$rc" = "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    printf 'FAIL %s expected=%s actual=%s\n' "$label" "$want" "$rc"
    head -c 300 "$TMP/err"
  fi
}
run_edit() { # <tool> <file>
  jq -cn --arg cwd "$L" --arg file "$2" --arg tool "$1" \
    '{tool_name:$tool,cwd:$cwd,tool_input:{file_path:$file}}' | /bin/bash "$ROOT/block-protected-target-writes.sh"
}
run_bash() { # <cwd> <command>
  jq -cn --arg cwd "$1" --arg cmd "$2" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}' \
    | /bin/bash "$ROOT/block-protected-target-writes.sh"
}

WIRING=(
  .agents/hooks.json
  # agy auto-discovers plugins here, and runs each plugin's own hooks.json.
  .agents/plugins/sibling/hooks.json
  .agents/plugins.json
  harness-adapters/agy/agy-hook.sh
  # The generator. The gate passes its plain run.
  bin/sync-agy-adapter.sh
)

for rel in "${WIRING[@]}"; do
  for tool in Write Edit MultiEdit; do
    check 2 "live $tool $rel" run_edit "$tool" "$L/$rel"
    check 0 "scratch $tool $rel" run_edit "$tool" "$S/$rel"
    check 0 "worktree $tool $rel" run_edit "$tool" "$W/$rel"
  done
  check 2 "live Bash rm $rel" run_bash "$L" "rm -f $rel"
  check 0 "scratch Bash rm $rel" run_bash "$S" "rm -f $rel"
  check 0 "worktree Bash rm $rel" run_bash "$W" "rm -f $rel"
done

# Other Bash forms and parent folders in the live root.
check 2 "live redirect into .agents/hooks.json" run_bash "$L" 'echo {} > .agents/hooks.json'
check 2 "live mv of .agents/hooks.json" run_bash "$L" 'mv .agents/hooks.json /tmp/x'
check 2 "live rm -rf .agents (holds hooks.json)" run_bash "$L" 'rm -rf .agents'
check 2 "live rm -rf .agents/plugins" run_bash "$L" 'rm -rf .agents/plugins'
check 2 "live rm -rf harness-adapters/agy" run_bash "$L" 'rm -rf harness-adapters/agy'
check 2 "live rm -rf harness-adapters (holds the wrapper)" run_bash "$L" 'rm -rf harness-adapters'
check 2 "live git rm -r harness-adapters/agy" run_bash "$L" 'git rm -r harness-adapters/agy'
check 2 "live redirect into the generator" run_bash "$L" 'echo "exit 0" > bin/sync-agy-adapter.sh'
check 2 "absolute rm of the live wrapper from another folder" run_bash "$S" "rm -f $L/harness-adapters/agy/agy-hook.sh"

# agy reads nested .agents/ hook config too, so the same files are protected
# at any depth in the live root. A worktree is its own root.
NESTED=(
  docs/.agents/hooks.json
  docs/.agents/plugins.json
  docs/.agents/plugins/x/hooks.json
  docs/.AGENTS/Hooks.JSON
  workspace/proj/.agents/hooks.json
  # Deeper inside a linked worktree, a nested form is protected too.
  .claude/worktrees/wt/docs/.agents/hooks.json
  .claude/worktrees/wt/docs/.agents/plugins.json
)
for rel in "${NESTED[@]}"; do
  for tool in Write Edit MultiEdit; do
    check 2 "live nested $tool $rel" run_edit "$tool" "$L/$rel"
  done
  check 2 "live nested Bash redirect into $rel" run_bash "$L" "echo {} > $rel"
  check 2 "live nested Bash rm $rel" run_bash "$L" "rm -f $rel"
done
# A linked worktree's own root wiring stays editable, as its .claude/hooks/ is.
for rel in docs/agents/hooks.json docs/.agents/skills/x.md .claude/worktrees/wt/.agents/hooks.json .claude/worktrees/wt/.agents/plugins/x/hooks.json; do
  for tool in Write Edit; do
    check 0 "live nested control $tool $rel" run_edit "$tool" "$L/$rel"
  done
  check 0 "live nested control Bash redirect into $rel" run_bash "$L" "echo {} > $rel"
done

# A recursive copy or a link onto a nested .agents folder can bring a hook
# config with it.
check 2 "live cp -R onto docs/.agents" run_bash "$L" 'cp -R x docs/.agents'
check 2 "live ln -s onto docs/.agents" run_bash "$L" 'ln -s x docs/.agents'
check 2 "live cp -R onto docs/.AGENTS (case variant)" run_bash "$L" 'cp -R x docs/.AGENTS'
check 2 "live cp -R onto docs/.agents/plugins" run_bash "$L" 'cp -R x docs/.agents/plugins'
check 2 "live cp -R onto a worktree's docs/.agents" run_bash "$L" 'cp -R x .claude/worktrees/wt/docs/.agents'
check 2 "live rm -rf docs/.agents" run_bash "$L" 'rm -rf docs/.agents'
check 2 "live mv onto docs/.agents/plugins" run_bash "$L" 'mv x docs/.agents/plugins'
check 0 "live cp -R onto docs/agents stays allowed" run_bash "$L" 'cp -R x docs/agents'
check 0 "live mv onto docs/agents stays allowed" run_bash "$L" 'mv x docs/agents'
check 0 "live cp -R onto a worktree's own .agents stays allowed" run_bash "$L" 'cp -R x .claude/worktrees/wt/.agents'
check 0 "live mv onto a worktree's own .agents stays allowed" run_bash "$L" 'mv x .claude/worktrees/wt/.agents'

# A move onto a target that is not an existing directory renames the source
# to it, so a folder moved onto a new .agents can bring a hook config.
mkdir -p "$L/docs"
if [ -e "$L/.agents" ]; then FAIL=$((FAIL+1)); echo "FAIL precondition: the live fork has no root .agents"; else PASS=$((PASS+1)); fi
check 2 "live mv onto a new docs/.agents" run_bash "$L" 'mv x docs/.agents'
check 2 "live git mv onto a new docs/.agents" run_bash "$L" 'git mv x docs/.agents'
check 2 "live mv onto a worktree's new docs/.agents" run_bash "$L" 'mv x .claude/worktrees/wt/docs/.agents'
check 2 "live mv onto a new root .agents" run_bash "$L" 'mv x .agents'
# The hook's own working directory can differ from the command's directory.
# A folder there must not make a new target look like an existing folder.
in_dir() { local d="$1"; shift; ( cd "$d" && "$@" ); }
mkdir -p "$TMP/hookcwd/.agents" "$TMP/hookcwd/docs/.agents"
check 2 "live mv onto a new root .agents, with .agents in the hook's directory" in_dir "$TMP/hookcwd" run_bash "$L" 'mv x .agents'
check 2 "live mv onto a new docs/.agents, with docs/.agents in the hook's directory" in_dir "$TMP/hookcwd" run_bash "$L" 'mv x docs/.agents'
rm -rf "$TMP/hookcwd"
check 0 "live mv to a new plain name stays allowed" run_bash "$L" 'mv x newname'
check 0 "live mv inside docs stays allowed" run_bash "$L/docs" 'mv a b'
check 0 "live mv into an existing docs/ stays allowed" run_bash "$L" 'mv x docs/'
check 0 "live git mv a b stays allowed" run_bash "$L" 'git mv a b'
# Into an existing folder, a moved, linked or recursively copied source
# lands at docs/<its name>. A source named .agents from outside the fork
# creates a nested config folder there.
check 2 "live mv of an outside .agents into an existing docs/" run_bash "$L" "mv $S/.agents docs/"
check 2 "live mv -t docs of an outside .agents" run_bash "$L" "mv -t docs $S/.agents"
check 2 "live cp -R of an outside .agents into an existing docs/" run_bash "$L" "cp -R $S/.agents docs/"
check 2 "live ln -s of an outside .agents into an existing docs/" run_bash "$L" "ln -s $S/.agents docs/"
check 0 "live mv of an outside folder into an existing docs/ stays allowed" run_bash "$L" "mv $S/notes docs/"
check 0 "live cp -R of an outside folder into an existing docs/ stays allowed" run_bash "$L" "cp -R $S/build docs/"
check 0 "live ln -s of an outside file into an existing docs/ stays allowed" run_bash "$L" "ln -s $S/tool docs/"
check 0 "live plain cp of a file named .agents into an existing docs/ stays allowed" run_bash "$L" "cp $S/.agents docs/"
# A copy or link into a folder that holds agy wiring passes, as before the
# wiring. Its new entry is judged on its own. A contents copy, which lands
# directly in the folder, is judged against the folder itself.
mkdir -p "$L/bin" "$L/harness-adapters" "$L/.agents"
check 0 "live ln -s into an existing bin/ stays allowed" run_bash "$L" "ln -s $S/tool bin/"
check 0 "live ln -s into an existing bin stays allowed" run_bash "$L" "ln -s $S/tool bin"
check 0 "live cp -R into an existing bin/ stays allowed" run_bash "$L" "cp -R $S/build bin/"
check 0 "live rsync -a into an existing bin/ stays allowed" run_bash "$L" "rsync -a $S/build bin/"
check 0 "live cp -R into an existing harness-adapters/ stays allowed" run_bash "$L" "cp -R $S/build harness-adapters/"
check 0 "live ln -s into an existing root .agents/ stays allowed" run_bash "$L" "ln -s $S/skills .agents/"
check 2 "live rsync -a of folder contents into bin/" run_bash "$L" "rsync -a $S/build/ bin/"
check 2 "live cp -R of folder contents into bin/" run_bash "$L" "cp -R $S/build/. bin/"
check 2 "live ditto into bin" run_bash "$L" "ditto $S/build bin"
check 2 "live cp -R of a plugins folder into the root .agents/" run_bash "$L" "cp -R $S/plugins .agents/"
check 2 "live cp -R into .claude/ is still blocked" run_bash "$L" "cp -R $S/build .claude/"
# A source that can land at another name judges the folder in full.
check 2 "live cp -R of a glob into harness-adapters/" run_bash "$L" "cp -R $S/* harness-adapters/"
check 2 "live rsync -a of a glob into bin/" run_bash "$L" "rsync -a $S/* bin/"
check 2 "live ln -s of a glob into bin/" run_bash "$L" "ln -s $S/* bin/"
check 2 "live mv of a glob into the root .agents/" run_bash "$L" "mv $S/* .agents/"
check 2 "live plain cp of a glob into the root .agents/" run_bash "$L" "cp $S/* .agents/"
check 2 "live cp -R of a brace into bin/" run_bash "$L" "cp -R $S/{a,b} bin/"
check 2 "live cp -R of a variable into bin/" run_bash "$L" 'cp -R $X bin/'
check 2 "live cp -RT onto the root .agents" run_bash "$L" "cp -RT $S/build .agents"
check 2 "live mv -T onto the root .agents" run_bash "$L" "mv -T $S/build .agents"
check 2 "live cp --parents of a nested config into docs/" run_bash "$L" "cp --parents $S/x/.agents/hooks.json docs/"
check 2 "live rsync -aR of a nested .agents into docs/" run_bash "$L" "rsync -aR $S/./x/.agents docs/"
check 2 "live cp --parents of a hooks.json into the root .agents/" run_bash "$L" "cp --parents hooks.json .agents/"
check 2 "live cp -R -t an unresolved .claude folder" run_bash "$L" 'cp -R -t $X/.claude build'
# A short-flag group can hold -R or -T in any place.
check 2 "live cp -TR onto the root .agents" run_bash "$L" "cp -TR $S/build .agents"
check 2 "live mv -Tf onto the root .agents" run_bash "$L" "mv -Tf $S/build .agents"
check 2 "live rsync -R of a nested config into docs/" run_bash "$L" "rsync -R $S/./x/.agents/hooks.json docs/"
check 2 "live rsync -Ra of a nested config into docs/" run_bash "$L" "rsync -Ra $S/./x/.agents/hooks.json docs/"
# GNU tools take an unambiguous prefix of a long option.
check 2 "live cp --par of a nested config into docs/" run_bash "$L" "cp --par $S/x/.agents/hooks.json docs/"
check 2 "live mv --no-t onto the root .agents" run_bash "$L" "mv --no-t $S/build .agents"
check 2 "live rsync -a --rel of a nested .agents into docs/" run_bash "$L" "rsync -a --rel $S/./x/.agents docs/"
check 2 "live cp -R --targ= of a plugins folder" run_bash "$L" "cp -R --targ=.agents $S/plugins"
check 2 "live cp -R --targ of a plugins folder" run_bash "$L" "cp -R --targ .agents $S/plugins"
check 2 "live cp -R --t= of a plugins folder" run_bash "$L" "cp -R --t=.agents $S/plugins"
check 2 "live cp -R --t of a plugins folder" run_bash "$L" "cp -R --t .agents $S/plugins"
check 2 "live cp --pa of a nested config into docs/" run_bash "$L" "cp --pa $S/x/.agents/hooks.json docs/"
check 2 "live install --n onto the root .agents" run_bash "$L" "install --n $S/x .agents"
# In a short-flag group, -t takes the rest of the group or the next word.
check 2 "live cp -Rt .agents of a plugins folder" run_bash "$L" "cp -Rt .agents $S/plugins"
check 2 "live cp -Rt.agents of a plugins folder" run_bash "$L" "cp -Rt.agents $S/plugins"
check 2 "live cp -t.agents of a hooks.json" run_bash "$L" "cp -t.agents $S/hooks.json"
check 0 "live cp -Rt docs stays allowed" run_bash "$L" "cp -Rt docs $S/build"
check 0 "live cp -vt docs stays allowed" run_bash "$L" "cp -vt docs $S/a.txt"
# A move with a dot glob can bring an .agents or .claude folder.
check 2 "live mv of a dot glob into the fork root" run_bash "$L" "mv $S/.* ."
check 0 "live mv of a variable into the fork root stays allowed" run_bash "$L" 'mv "$f" .'
check 0 "live rsync -a --recursive into bin/ stays allowed" run_bash "$L" "rsync -a --recursive $S/build bin/"
check 0 "live rsync -a --partial into bin/ stays allowed" run_bash "$L" "rsync -a --partial $S/build bin/"
check 0 "live rsync -a --no-times into bin/ stays allowed" run_bash "$L" "rsync -a --no-times $S/build bin/"
# An unresolved operand that names the agy wiring blocks, as one that names
# the settings files does.
check 2 "unresolved write to .agents/hooks.json" run_bash "$L" 'cp x $D/.agents/hooks.json'
check 2 "unresolved write under .agents/plugins" run_bash "$L" 'cp x $D/.agents/plugins/p/hooks.json'
check 2 "unresolved write to the wrapper" run_bash "$L" 'cp x $D/harness-adapters/agy/agy-hook.sh'
check 2 "unresolved write to the generator" run_bash "$L" 'cp x $D/bin/sync-agy-adapter.sh'
check 2 "unresolved removal of an .agents folder" run_bash "$L" 'rm -rf $D/.agents'
check 2 "unresolved removal of harness-adapters" run_bash "$L" 'rm -rf $D/harness-adapters'
check 2 "unresolved write to .agents//hooks.json" run_bash "$L" 'cp x $D/.agents//hooks.json'
check 2 "unresolved write to .agents/./hooks.json" run_bash "$L" 'cp x $D/.agents/./hooks.json'
check 2 "unresolved removal of an .agents/ folder" run_bash "$L" 'rm -rf $D/.agents/'
check 2 "unresolved removal of a .claude/. folder" run_bash "$L" 'rm -rf $D/.claude/.'
check 0 "unresolved removal of a bin folder stays allowed" run_bash "$L" 'rm -rf $BUILD/bin'
check 0 "unresolved copy into .agents/skills stays allowed" run_bash "$L" 'cp -R x $D/.agents/skills'
check 0 "unresolved write to a plain file stays allowed" run_bash "$L" 'cp x $D/docs/notes.txt'
# A plain copy or move replaces direct children of the folder only.
check 0 "live cp of a glob into the fork root stays allowed" run_bash "$L" "cp $S/*.json ."
check 0 "live cp of a variable into the fork root stays allowed" run_bash "$L" 'cp $X .'
check 0 "live mv of a glob into the fork root stays allowed" run_bash "$L" "mv $S/* ."
check 0 "live mv of a glob into docs/ stays allowed" run_bash "$L" "mv $S/*.md docs/"
check 0 "live cp -t of an unresolved folder with a glob stays allowed" run_bash "$L" 'cp -t $OUT x/*'
check 2 "live cp of a glob into bin/" run_bash "$L" "cp $S/* bin/"
check 2 "live cp of a variable into bin/" run_bash "$L" 'cp $X bin/'
check 2 "live cp of a glob into .claude/" run_bash "$L" "cp $S/* .claude/"
check 0 "live cp of a glob into docs/ stays allowed" run_bash "$L" "cp $S/*.txt docs/"
check 0 "live cp -R of a glob into docs/ stays allowed" run_bash "$L" "cp -R $S/* docs/"
rmdir "$L/bin" "$L/harness-adapters" "$L/.agents"
# For truncate, -s still takes a value, so the next word is the target.
check 2 "live truncate -s 0 of the settings file" run_bash "$L" 'truncate -s 0 .claude/settings.json'
check 0 "live truncate -s 0 of a plain file stays allowed" run_bash "$L" 'truncate -s 0 docs/notes.txt'
rmdir "$L/docs"
check 0 "live rm -rf docs with no nested config stays allowed" run_bash "$L" 'rm -rf docs'
check 0 "live mkdir docs/.agents stays allowed" run_bash "$L" 'mkdir -p docs/.agents'

# Neighbours that are not agy gate wiring stay editable.
check 0 "live .agents/skills stays editable" run_bash "$L" 'rm -rf .agents/skills'
check 0 "live Write to another bin script stays allowed" run_edit Write "$L/bin/other-tool.sh"

# A person runs the generators through Bash. The gate judges only the
# command text, so the scripts' own writes are not judged.
check 0 "live bash bin/sync-agy-adapter.sh" run_bash "$L" 'bash bin/sync-agy-adapter.sh'
check 0 "live bash bin/sync-codex-adapter.sh --clean" run_bash "$L" 'bash bin/sync-codex-adapter.sh --clean'

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
