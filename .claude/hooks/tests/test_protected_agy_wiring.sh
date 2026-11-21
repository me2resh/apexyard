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
check 0 "live mv to a new plain name stays allowed" run_bash "$L" 'mv x newname'
check 0 "live mv inside docs stays allowed" run_bash "$L/docs" 'mv a b'
check 0 "live mv into an existing docs/ stays allowed" run_bash "$L" 'mv x docs/'
check 0 "live git mv a b stays allowed" run_bash "$L" 'git mv a b'
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
