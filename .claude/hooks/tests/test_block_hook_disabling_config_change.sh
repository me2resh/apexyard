#!/bin/bash
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/_test-protected-state.sh"
printf '{"source":"startup","session_id":"d17"}\n' | /bin/bash "$ROOT/write-session-snapshot.sh" || exit 1
config() {
  jq -cn --arg source "$1" --arg file "${2:-}" '{session_id:"d17",source:$source,file_path:(if $file=="" then null else $file end)}' | /bin/bash "$ROOT/block-hook-disabling-config-change.sh"
}
for data in '{"disableAllHooks":true}' '{"hooks":{"PreToolUse":[]}}' 'invalid'; do
  printf '%s\n' "$data" > "$TMP/live/.claude/settings.json"
  check 2 "$data" config project_settings
done
for key in APEXYARD_ALLOW_X APEXYARD_OPS_PIN_DIR PATH BASH_ENV CLAUDE_ENV_FILE 'BASH_FUNC_x%%'; do
  jq -n --arg key "$key" '{env:{($key):"evil"}}' > "$TMP/live/.claude/settings.json"
  check 2 "env $key" config project_settings
done
printf '{"claudeMdExcludes":["x"]}\n' > "$TMP/live/.claude/settings.json"
check 0 'rule excludes' config project_settings
printf '{"permissions":{"allow":["Read"]}}\n' > "$TMP/live/.claude/settings.local.json"
check 0 'permission create absent file' config local_settings
check 2 'unknown source' config unknown
printf '{"permissions":{"allow":["Read"]}}\n' > "$TMP/scratch/.claude/settings.json"
check 0 'non-live permission change allowed' config project_settings "$TMP/scratch/.claude/settings.json"
check 0 'block log records each block' test "$(jq -s '[.[]|select(.decision=="block")]|length' "$TMP/live/.claude/session/config-change-blocks.jsonl")" = 10
check 0 'non-live change is logged as allow' test "$(jq -s '[.[]|select(.decision=="allow")]|length' "$TMP/live/.claude/session/config-change-blocks.jsonl")" = 1
# User settings resolve from the source when file_path is absent.
printf '{"permissions":{"allow":["Read"]}}\n' > "$HOME/.claude/settings.json"
check 0 'user settings permission change' config user_settings
printf '{"env":{"PATH":"evil"}}\n' > "$HOME/.claude/settings.json"
check 2 'user settings env change' config user_settings
printf '{"disableAllHooks":true}\n' > "$HOME/.claude/settings.json"
check 2 'user settings disableAllHooks' config user_settings
rm -f "$HOME/.claude/settings.json"
# A settings file that is not live: the baseline is its committed copy.
WT="$TMP/worktree"
mkdir -p "$WT/.claude"
git init -q "$WT" || exit 1
printf '{"hooks":{"PreToolUse":[]},"permissions":{"allow":[]}}\n' > "$WT/.claude/settings.json"
git -C "$WT" add .claude/settings.json || exit 1
git -C "$WT" -c user.name=t -c user.email=t@example.invalid commit -q -m base || exit 1
printf '{"permissions":{"allow":["Read"]},"hooks":{"PreToolUse":[]}}\n' > "$WT/.claude/settings.json"
check 0 'non-live change that keeps the committed hooks' config project_settings "$WT/.claude/settings.json"
printf '{"hooks":{"PreToolUse":[]},"env":{"D17_PROBE":"1"}}\n' > "$WT/.claude/settings.json"
check 2 'non-live env change against the committed copy' config project_settings "$WT/.claude/settings.json"
printf '{"hooks":{}}\n' > "$WT/.claude/settings.json"
check 2 'non-live hooks change against the committed copy' config project_settings "$WT/.claude/settings.json"
printf '{"hooks":{"PreToolUse":[]},"disableAllHooks":true}\n' > "$WT/.claude/settings.json"
check 2 'non-live disableAllHooks' config project_settings "$WT/.claude/settings.json"
printf '{"hooks":{"x":[]}}\n' > "$TMP/scratch/.claude/settings.json"
check 2 'non-live hooks in a file that is not committed' config project_settings "$TMP/scratch/.claude/settings.json"
printf 'invalid\n' > "$TMP/scratch/.claude/settings.json"
check 2 'non-live invalid JSON' config project_settings "$TMP/scratch/.claude/settings.json"
printf '{}\n' > "$TMP/scratch/.claude/settings.json"
# Without a pin (a session after /clear), the block log goes to the project directory.
mkdir -p "$TMP/project/.claude"
nopin_config() { printf '{"session_id":"nopin","source":"project_settings"}' | CLAUDE_CODE_SESSION_ID=nopin CLAUDE_PROJECT_DIR="$TMP/project" /bin/bash "$ROOT/block-hook-disabling-config-change.sh"; }
printf '{"disableAllHooks":true}\n' > "$TMP/project/.claude/settings.json"
check 2 'no-pin block' nopin_config
check 0 'no-pin block is logged under the project directory' test "$(jq -s 'length' "$TMP/project/.claude/session/config-change-blocks.jsonl" 2>/dev/null)" = 1
# Paired case: with a pin, the block log stays under the pinned ops root.
before=$(jq -s 'length' "$TMP/live/.claude/session/config-change-blocks.jsonl")
printf '{"disableAllHooks":true}\n' > "$TMP/live/.claude/settings.json"
check 2 'pinned block' config project_settings
check 0 'pinned block is logged under the ops root' test "$(jq -s 'length' "$TMP/live/.claude/session/config-change-blocks.jsonl")" = "$((before+1))"
printf '{}\n' > "$TMP/live/.claude/settings.json"
# No-snapshot mode allows permissions, but never env or hook changes.
rm "$APEXYARD_OPS_PIN_DIR/gate-session-d17/snapshot.json"
check 0 'no snapshot permission' config local_settings
printf '{"env":{"PATH":"evil"}}\n' > "$TMP/live/.claude/settings.local.json"
check 2 'no snapshot env' config local_settings
mkdir -p "$TMP/bin"
printf '{}\n' > "$TMP/tracked-settings"
export D17_BASELINE="$TMP/tracked-settings"
cat > "$TMP/bin/git" <<'GIT'
#!/bin/bash
if [ "${3:-}" = show ] && [ "${4:-}" = HEAD:.claude/settings.json ]; then
  cat "$D17_BASELINE"
else
  exit 1
fi
GIT
chmod +x "$TMP/bin/git"
saved_path="$PATH"
export PATH="$TMP/bin:$PATH"
printf '{"permissions":{"allow":["Read"]}}\n' > "$TMP/live/.claude/settings.json"
check 0 'no snapshot project permissions match tracked hooks and env' config project_settings
printf '{"hooks":{"PreToolUse":[]}}\n' > "$TMP/live/.claude/settings.json"
check 2 'no snapshot project hooks differ from tracked baseline' config project_settings
export PATH="$saved_path"
# Reordered object keys must hash to the same baseline.
printf '{"hooks":{"b":[],"a":[]},"env":{"B":"2","A":"1"}}\n' > "$TMP/live/.claude/settings.json"
printf '{"source":"startup","session_id":"order"}\n' | CLAUDE_CODE_SESSION_ID=order /bin/bash "$ROOT/write-session-snapshot.sh" || exit 1
cp "$APEXYARD_OPS_PIN_DIR/gate-session-order/snapshot.json" "$APEXYARD_OPS_PIN_DIR/gate-session-d17/snapshot.json"
printf '{"env":{"A":"1","B":"2"},"hooks":{"a":[],"b":[]}}\n' > "$TMP/live/.claude/settings.json"
# The order fixture has no pin. Set the expected pin to the fixture root.
jq --arg ops "$TMP/live" '.ops_root=$ops' "$APEXYARD_OPS_PIN_DIR/gate-session-d17/snapshot.json" > "$TMP/snapshot"
mv "$TMP/snapshot" "$APEXYARD_OPS_PIN_DIR/gate-session-d17/snapshot.json"
check 0 'key order has no effect' config project_settings
jq 'del(.settings.project_settings)' "$APEXYARD_OPS_PIN_DIR/gate-session-d17/snapshot.json" > "$TMP/snapshot"
mv "$TMP/snapshot" "$APEXYARD_OPS_PIN_DIR/gate-session-d17/snapshot.json"
check 2 'missing snapshot source' config project_settings
finish
