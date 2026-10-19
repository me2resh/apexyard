#!/bin/bash
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/_test-protected-state.sh"
rm "$APEXYARD_OPS_PIN_DIR/ops-root-d17"
pin() { (cd "$1" && printf '{"source":"%s"}\n' "$2" | /bin/bash "$ROOT/pin-ops-root.sh"); }
check 0 startup pin "$TMP/live" startup
check 0 'pin exists' test -f "$APEXYARD_OPS_PIN_DIR/ops-root-d17"
initial=$(cat "$APEXYARD_OPS_PIN_DIR/ops-root-d17")
touch "$TMP/scratch/.apexyard-fork"
for kind in compact clear resume fork startup; do
  check 0 "$kind other cwd" pin "$TMP/scratch" "$kind"
  check 0 'unchanged pin' test "$initial" = "$(cat "$APEXYARD_OPS_PIN_DIR/ops-root-d17")"
done
printf '{"source":"startup","session_id":"d17"}\n' | /bin/bash "$ROOT/write-session-snapshot.sh" || exit 1
printf '%s\n' "$TMP/scratch" > "$APEXYARD_OPS_PIN_DIR/ops-root-d17"
check_mismatch() { printf '{"session_id":"d17","tool_name":"Edit","tool_input":{"file_path":"/tmp/x"}}' | /bin/bash "$ROOT/block-protected-target-writes.sh"; }
check 2 'snapshot pin mismatch' check_mismatch
touch "$APEXYARD_OPS_PIN_DIR/ops-root-old" "$APEXYARD_OPS_PIN_DIR/ops-root-new"
touch -t 202001010000 "$APEXYARD_OPS_PIN_DIR/ops-root-old"
check 0 cleanup pin "$TMP/live" startup
check 1 'old pin removed' test -e "$APEXYARD_OPS_PIN_DIR/ops-root-old"
check 0 'new pin retained' test -e "$APEXYARD_OPS_PIN_DIR/ops-root-new"
mkdir -p "$TMP/outside"
touch "$TMP/outside/ops-root-old"
touch -t 202001010000 "$TMP/outside/ops-root-old"
ln -s "$TMP/outside/ops-root-old" "$APEXYARD_OPS_PIN_DIR/ops-root-link"
ln -s "$TMP/outside" "$APEXYARD_OPS_PIN_DIR/outside-dir"
check 0 'cleanup with links' pin "$TMP/live" startup
check 0 'file link is not followed' test -L "$APEXYARD_OPS_PIN_DIR/ops-root-link"
check 0 'outside target remains' test -e "$TMP/outside/ops-root-old"
check_bash_mismatch() { printf '{"session_id":"d17","tool_name":"Bash","tool_input":{"command":"echo ok"}}' | /bin/bash "$ROOT/block-protected-target-writes.sh"; }
check 2 'Bash snapshot pin mismatch' check_bash_mismatch
export CLAUDE_CODE_SESSION_ID=no-source
check 0 'empty source is a no-op' pin "$TMP/live" ''
check 1 'empty source creates no pin' test -e "$APEXYARD_OPS_PIN_DIR/ops-root-no-source"
finish
