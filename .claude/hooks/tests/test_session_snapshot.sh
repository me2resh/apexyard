#!/bin/bash
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/_test-protected-state.sh"
start() { printf '{"source":"%s","session_id":"%s"}\n' "$1" "$CLAUDE_CODE_SESSION_ID" | /bin/bash "$ROOT/write-session-snapshot.sh"; }
for kind in startup resume fork; do
  export CLAUDE_CODE_SESSION_ID="d17-$kind"
  cp "$APEXYARD_OPS_PIN_DIR/ops-root-d17" "$APEXYARD_OPS_PIN_DIR/ops-root-$CLAUDE_CODE_SESSION_ID"
  check 0 "$kind snapshot" start "$kind"
  snapshot="$APEXYARD_OPS_PIN_DIR/gate-session-$CLAUDE_CODE_SESSION_ID/snapshot.json"
  check 0 'snapshot exists' test -f "$snapshot"
  before=$(shasum "$snapshot")
  for repeat in startup resume fork compact clear; do
    check 0 "repeat $repeat" start "$repeat"
    check 0 'write once' test "$before" = "$(shasum "$snapshot")"
  done
  check 0 'pin recorded' test "$(jq -r .ops_root "$snapshot")" = "$TMP/live"
  check 0 'absent local recorded' jq -e '.settings.local_settings.hooks!=null and .settings.local_settings.env!=null' "$snapshot"
done
for kind in compact clear; do
  export CLAUDE_CODE_SESSION_ID="none-$kind"
  check 0 "$kind no snapshot" start "$kind"
  check 1 'no snapshot exists' test -e "$APEXYARD_OPS_PIN_DIR/gate-session-$CLAUDE_CODE_SESSION_ID/snapshot.json"
done
export CLAUDE_CODE_SESSION_ID=d17-startup
printf '{"hooks":{"x":[]}}\n' > "$TMP/live/.claude/settings.json"
check 0 'resume warns' start resume
cp "$TMP/out" "$TMP/warning"
check 0 'warning is plain text' grep -q '^WARN:' "$TMP/warning"
printf '{}\n' > "$TMP/live/.claude/settings.json"
mkdir -p "$TMP/live/.claude/session"
printf '{}\n' > "$TMP/live/.claude/session/config-change-blocks.jsonl"
check 0 'resume with block log' start resume
cp "$TMP/out" "$TMP/log-warning"
check 0 'block log alone warns' grep -q '^WARN:' "$TMP/log-warning"
# A file with no hooks key records an explicit value, not a missing record.
check 0 'no hooks key recorded' jq -e '(.settings.project_settings.hooks|type=="string" and length==64) and (.settings.project_settings.env|type=="string")' "$APEXYARD_OPS_PIN_DIR/gate-session-d17-startup/snapshot.json"
# write-rule-excludes.sh runs after the snapshot step in the same start. Its
# ConfigChange must find the record and pass. A hooks change must still block.
export CLAUDE_CODE_SESSION_ID=excludes
cp "$APEXYARD_OPS_PIN_DIR/ops-root-d17" "$APEXYARD_OPS_PIN_DIR/ops-root-excludes"
rm -f "$TMP/live/.claude/settings.local.json"
check 0 'excludes session snapshot' start startup
printf '{"claudeMdExcludes":["%s/live/.claude/rules/**"]}\n' "$TMP" > "$TMP/live/.claude/settings.local.json"
config_change() { printf '{"session_id":"excludes","source":"local_settings"}' | /bin/bash "$ROOT/block-hook-disabling-config-change.sh"; }
check 0 'rule excludes change after the snapshot passes' config_change
printf '{"claudeMdExcludes":[],"hooks":{"PreToolUse":[]}}\n' > "$TMP/live/.claude/settings.local.json"
check 2 'hooks change after the snapshot blocks' config_change
# Resume warning and log rotation (#1858): the warning shows once.
export CLAUDE_CODE_SESSION_ID=d17-rotate
cp "$APEXYARD_OPS_PIN_DIR/ops-root-d17" "$APEXYARD_OPS_PIN_DIR/ops-root-$CLAUDE_CODE_SESSION_ID"
check 0 'rotate session snapshot' start startup
mkdir -p "$TMP/live/.claude/session"
printf '{"decision":"block"}\n' > "$TMP/live/.claude/session/config-change-blocks.jsonl"
out1=$(start resume 2>&1)
out2=$(start resume 2>&1)
check 0 'resume warns for an old block' test "${out1#*WARN}" != "$out1"
check 0 'second resume shows no warning' test "${out2#*WARN}" = "$out2"
check 0 'old block log is kept as .old' test -s "$TMP/live/.claude/session/config-change-blocks.jsonl.old"
rm -f "$TMP/live/.claude/settings.local.json"
export CLAUDE_CODE_SESSION_ID=no-source
check 0 'empty source is a no-op' start ''
check 1 'empty source creates no snapshot' test -e "$APEXYARD_OPS_PIN_DIR/gate-session-no-source/snapshot.json"
finish
