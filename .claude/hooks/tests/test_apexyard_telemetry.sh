#!/usr/bin/env bash
# Test install events with local repositories and a curl stub.
# shellcheck disable=SC1091,SC2154
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_lib-apexyard-cli.sh"
export APEXYARD_TELEMETRY=1 APEXYARD_CURL="$sb/tools/curl" CURL_LOG="$sb/curl.log" CURL_BODY="$sb/body.json"
unset APEXYARD_TELEMETRY_URL
cat > "$APEXYARD_CURL" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
cat > "$CURL_BODY"
exit "${CURL_EXIT:-0}"
STUB
chmod +x "$APEXYARD_CURL"
run_init() {
  local label=$1
  shift
  FAKE_REMOTE="$sb/$label.git" /bin/bash "$CLI" init --org private-org --name private-repo \
    --dir "$sb/$label" "$@" > "$sb/$label.out" 2>&1
}
check 'default init succeeds' run_init default
check 'default dry run message' grep -q 'Install ping (dry run, nothing sent):' "$sb/default.out"
check 'default does not call curl' test ! -e "$CURL_LOG"
id=$(cat "$XDG_CONFIG_HOME/apexyard/install-id")
check 'id format' /bin/bash -c '[[ "$1" =~ ^[0-9a-f]{32}$ ]]' _ "$id"
mode=$(stat -c '%a' "$XDG_CONFIG_HOME/apexyard/install-id" 2>/dev/null || stat -f '%Lp' "$XDG_CONFIG_HOME/apexyard/install-id")
check 'id permissions' test "$mode" = 600
check 'first notice' grep -q 'ApexYard sends one anonymous' "$sb/default.out"
export APEXYARD_TELEMETRY_URL=http://test.invalid/x
check 'stub init succeeds' run_init sent --agent codex
check 'one request' test "$(wc -l < "$CURL_LOG" | tr -d ' ')" = 1
check 'curl options' grep -q -- '-fsS --max-time 3 -H Content-Type: application/json --data-binary @- -- http://test.invalid/x' "$CURL_LOG"
check 'exact fields' test "$(jq -c keys "$CURL_BODY")" = '["agent","cli_version","install_id","os"]'
check 'field values' jq -e --arg id "$id" --arg os "$(uname -s | tr '[:upper:]' '[:lower:]')" \
  '.install_id == $id and .cli_version == "0.1.0" and .os == $os and .agent == "codex"' "$CURL_BODY" > /dev/null
for secret in private-org private-repo "$sb" "$(id -un)"; do
  check 'no private value' /bin/bash -c '! grep -Fq -- "$1" "$2"' _ "$secret" "$CURL_BODY"
done
check 'stable id' test "$(cat "$XDG_CONFIG_HOME/apexyard/install-id")" = "$id"
check 'notice only once' /bin/bash -c '! grep -q "ApexYard sends one anonymous" "$1"' _ "$sb/sent.out"
rm -f "$CURL_LOG"
export XDG_CONFIG_HOME="$sb/disabled" APEXYARD_TELEMETRY=0
check 'disabled init succeeds' run_init disabled
check 'disabled no notice or ping' /bin/bash -c '! grep -Eq "ApexYard sends|Install ping" "$1"' _ "$sb/disabled.out"
check 'disabled no id' test ! -e "$XDG_CONFIG_HOME/apexyard/install-id"
check 'disabled no marker' test ! -e "$XDG_CONFIG_HOME/apexyard/telemetry-notice-shown"
check 'disabled no request' test ! -e "$CURL_LOG"
export APEXYARD_TELEMETRY=1 XDG_CONFIG_HOME="$sb/config"
if run_init invalid --agent invalid; then rc=0; else rc=$?; fi
check 'invalid agent rejected' test "$rc" = 2
check 'dry init succeeds' run_init dry --dry-run
check 'dry init no request' test ! -e "$CURL_LOG"
mkdir -p "$sb/default/.claude/skills/status" "$sb/default/.claude/skills/preflight"
printf 'exit 0\n' > "$sb/default/.claude/skills/status/briefing.sh"
printf 'exit 0\n' > "$sb/default/.claude/skills/preflight/preflight.sh"
export APEXYARD_AGENT_CMD="$sb/tools/absent-agent"
for cmd in update status doctor; do
  (cd "$sb/default" && /bin/bash "$CLI" "$cmd") > "$sb/$cmd.out" 2>&1
  check "$cmd succeeds" test "$?" = 0
  check "$cmd no request" test ! -e "$CURL_LOG"
done
export CURL_EXIT=1
check 'curl failure does not fail init' run_init failure --agent other
check 'failed curl called once' test "$(wc -l < "$CURL_LOG" | tr -d ' ')" = 1
# Test the notice on a command that does not send an event.
export XDG_CONFIG_HOME="$sb/help-config"
/bin/bash "$CLI" --help > "$sb/help.out" 2>&1
check 'help notice' grep -q 'ApexYard sends one anonymous' "$sb/help.out"
check 'help creates no id' test ! -e "$XDG_CONFIG_HOME/apexyard/install-id"
# Test all documented disable values directly.
# shellcheck source=bin/_lib-telemetry.sh
source "$(dirname "$CLI")/_lib-telemetry.sh"
for value in 0 false off; do
  export APEXYARD_TELEMETRY="$value" XDG_CONFIG_HOME="$sb/off-$value"
  telemetry_notice_once
  telemetry_send claude
  check "$value no config" test ! -e "$XDG_CONFIG_HOME"
done
finish
