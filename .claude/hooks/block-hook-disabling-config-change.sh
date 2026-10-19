#!/bin/bash
# ConfigChange control. Log changes; never restore files from the baseline.
set -euo pipefail
HOOK_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-protected-state.sh"
INPUT=$(cat)
pt_init "$INPUT" || pt_block 'cannot read the session baseline or pin.'
source_name=$(jq -r '.source // empty' <<<"$INPUT")
path=$(jq -r '.file_path // empty' <<<"$INPUT")
log_change() {
  local decision="$1" reason="$2" log_root
  # A session after /clear has no pin (capture P12b). Log under the project
  # directory then, so a block in that session still leaves evidence.
  log_root=${PT_OPS:-${PT_PROJECT:-}}
  [ -n "$log_root" ] || return 0
  mkdir -p "$log_root/.claude/session"
  jq -cn --arg source "$source_name" --arg path "$path" --arg decision "$decision" --arg reason "$reason" \
    '{source:$source,file_path:$path,decision:$decision,reason:$reason}' >> "$log_root/.claude/session/config-change-blocks.jsonl"
}
block_change() { log_change block "$*"; pt_block "$*"; }
if [ -z "$path" ]; then
  case "$source_name" in
    user_settings) path="$PT_USER/settings.json" ;;
    project_settings) [ -n "$PT_PROJECT" ] || block_change 'unknown project settings source.'; path="$PT_PROJECT/.claude/settings.json" ;;
    local_settings) [ -n "$PT_PROJECT" ] || block_change 'unknown local settings source.'; path="$PT_PROJECT/.claude/settings.local.json" ;;
    *) block_change 'unknown settings source.' ;;
  esac
fi
path=$(pt_physical "$path") || block_change 'cannot resolve settings file.'
is_live=0
for root in "${PT_ROOTS[@]}"; do
  case "$path" in "$root/.claude/settings.json"|"$root/.claude/settings.local.json") is_live=1 ;; esac
done
case "$path" in "$PT_USER/settings.json"|"$PT_HOME_CONFIG/settings.json") is_live=1 ;; esac
[ "$is_live" = 1 ] || { log_change allow 'settings file is not live.'; exit 0; }
current=$(pt_record "$path") || block_change 'settings JSON is invalid.'
[ "$(jq -r '.disableAllHooks' <<<"$current")" != true ] || block_change 'disableAllHooks must remain false.'
if [ "$PT_HAS_SNAPSHOT" = 1 ]; then
  saved=$(jq -ce --arg s "$source_name" '.settings[$s] | select(.hooks!=null and .env!=null)' "$PT_SNAPSHOT") || block_change 'missing settings snapshot record.'
  for key in hooks env; do
    [ "$(jq -r --arg k "$key" '.[$k]' <<<"$current")" = "$(jq -r --arg k "$key" '.[$k]' <<<"$saved")" ] || block_change "$key changed during the session."
  done
else
  if [ "$source_name" = project_settings ]; then
    baseline=$(git -C "${PT_PROJECT:-$PT_OPS}" show HEAD:.claude/settings.json) || block_change 'cannot read tracked settings baseline.'
    for key in hooks env; do
      old=$(printf '%s' "$baseline" | pt_hash ".$key") || block_change 'invalid tracked settings baseline.'
      [ "$old" = "$(jq -r --arg k "$key" '.[$k]' <<<"$current")" ] || block_change "$key differs from tracked settings."
    done
  else
    data=$(pt_settings "$path") || block_change 'invalid settings.'
    jq -e '((.hooks // {} | length)==0) and ((.env // {} | length)==0)' >/dev/null <<<"$data" || block_change 'hooks or env is non-empty without a snapshot.'
  fi
fi
exit 0
