#!/bin/bash
# SessionStart: write the settings baseline once, before settings housekeeping.
set -euo pipefail
HOOK_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-protected-state.sh"
INPUT=$(cat)
command -v jq >/dev/null || exit 2
kind=$(jq -r '.source // empty' <<<"$INPUT") || exit 2
case "$kind" in startup|resume|fork) ;; *) exit 0 ;; esac
pt_init "$INPUT" || pt_block 'cannot read the session baseline or pin.'
if [ "$PT_HAS_SNAPSHOT" = 1 ]; then
  if [ "$kind" = resume ]; then
    changed=0
    for source_name in user_settings project_settings local_settings; do
      path=$(jq -er --arg s "$source_name" '.settings[$s].path' "$PT_SNAPSHOT") || exit 2
      current=$(pt_record "$path") || exit 2
      saved=$(jq -cS --arg s "$source_name" '.settings[$s]' "$PT_SNAPSHOT")
      [ "$(jq -cS . <<<"$current")" = "$saved" ] || changed=1
    done
    if [ "$changed" = 1 ] || [ -s "$PT_OPS/.claude/session/config-change-blocks.jsonl" ]; then
      echo 'WARN: settings differ from the session snapshot, or ConfigChange blocks were logged. Restart to load the settings on disk.'
      # Rotate the log so a later resume does not repeat the warning.
      if [ -s "$PT_OPS/.claude/session/config-change-blocks.jsonl" ]; then
        mv -f "$PT_OPS/.claude/session/config-change-blocks.jsonl" "$PT_OPS/.claude/session/config-change-blocks.jsonl.old" 2>/dev/null || :
      fi
    fi
  fi
  exit 0
fi
[ -n "$PT_PROJECT" ] || PT_PROJECT=$(pt_physical "${CLAUDE_PROJECT_DIR:-$PWD}")
user=$(pt_record "$PT_USER/settings.json")
project=$(pt_record "$PT_PROJECT/.claude/settings.json")
local_record=$(pt_record "$PT_PROJECT/.claude/settings.local.json")
gates=$(pt_settings "$PT_OPS/.claude/project-config.json")
mkdir -p "$PT_SESSION"
# Publish a complete file atomically. A racing SessionStart cannot replace it.
tmp=$(mktemp "$PT_SESSION/.snapshot.XXXXXX")
trap 'rm -f "$tmp"' EXIT
jq -n --arg ops "$PT_OPS" --arg project "$PT_PROJECT" --argjson user "$user" \
  --argjson settings "$project" --argjson local "$local_record" --argjson gates "$gates" \
  '{ops_root:$ops,project_dir:$project,settings:{user_settings:$user,project_settings:$settings,local_settings:$local},gate_config:$gates}' > "$tmp"
ln "$tmp" "$PT_SNAPSHOT" 2>/dev/null || { [ -f "$PT_SNAPSHOT" ] || exit 2; }
