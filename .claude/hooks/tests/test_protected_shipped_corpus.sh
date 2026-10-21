#!/bin/bash
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
# Extract the current shipped blocks, so closing-rule compatibility stays in CI.
# shellcheck source=/dev/null
. "$(dirname "$0")/_test-protected-state.sh"
# shellcheck source=/dev/null
. "$ROOT/_lib-detect-bash-write.sh"
REPO=$(cd "$ROOT/../.." && pwd -P)
awk '
/^```bash[[:space:]]*$/ {active=1; body="";next}
/^```/ {if(active){printf "%s%c",body,0;active=0}next}
active {body=body $0 "\n"}
' "$REPO"/.claude/skills/*/SKILL.md "$REPO"/.claude/agents/*.md > "$TMP/blocks"
count=0
pids=()
while IFS= read -r -d '' block; do
  case "$block" in *.claude/hooks*|*.claude/settings*|*ops-root-*|*gate-session-*|*APEXYARD_OPS_PIN_DIR*|*CLAUDE_CONFIG_DIR*) ;; *) continue ;; esac
  # Substitute documentation placeholders before the write classification.
  block=$(printf '%s' "$block" | sed -E \
    -e "s@<(marker_home|ops-root|ops_root)>@$TMP/live@g" \
    -e "s@<(path|scratch|worktree)>@$TMP/scratch@g" \
    -e 's@<repo>@example/fixture@g' \
    -e 's@<(pr|ticket|issue|number)>@1@g' \
    -e 's@<(ref|sha)>@HEAD@g')
  bash_command_appears_to_write "$block" || continue
  count=$((count+1))
  jq -cn --arg cwd "$TMP/live" --arg cmd "$block" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}' > "$TMP/payload-$count"
  # Each block has separate files. Four workers keep the CI timeout bounded.
  (
    rc=0
    /bin/bash "$ROOT/block-protected-target-writes.sh" < "$TMP/payload-$count" > "$TMP/out-$count" 2> "$TMP/err-$count" || rc=$?
    printf '%s\n' "$rc" > "$TMP/rc-$count"
  ) &
  pids[${#pids[@]}]=$!
  if [ "${#pids[@]}" = 4 ]; then
    for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid"; done
    pids=()
  fi
done < "$TMP/blocks"
for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid"; done
for ((i=1;i<=count;i++)); do
  if [ "$(cat "$TMP/rc-$i")" = 0 ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf 'FAIL shipped block %s\n' "$i"; cat "$TMP/err-$i"
  fi
done
printf 'Corpus: %s blocks\n' "$count"
[ "$count" -gt 0 ] || exit 1
finish
