#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p "$TMP/.claude/hooks"
cp "$ROOT/.claude/hooks/_lib-gate-mode.sh" "$TMP/.claude/hooks/"
# Register a new gate in fixture CODE, never through config or an env variable.
sed 's/# Opted-in gate names go here. No production gate is opted in yet./fixture-new) return 0 ;;/' \
  "$ROOT/.claude/hooks/_lib-gate-mode.sh" > "$TMP/.claude/hooks/_lib-gate-mode.sh"
. "$TMP/.claude/hooks/_lib-gate-mode.sh"
config_get() { printf '%s\n' "$CONFIG_MODE"; }
for CONFIG_MODE in off observe enforce; do
  if gate_mode_resolve validate-commit-format observe > "$TMP/out" 2> "$TMP/err"; then fail 'existing gate accepted'; fi
  [ "$(cat "$TMP/out")" = enforce ] || fail 'existing gate weakened'
  rc=0; gate_would_block validate-commit-format observe missing "$TMP" 2>/dev/null || rc=$?
  [ "$rc" = 2 ] || fail 'existing gate allowed'
done
echo 'PASS: non-opted-in gates refuse all config modes'
CONFIG_MODE=observe
gate_would_block fixture-new enforce missing "$TMP"
gate_would_block fixture-new enforce missing "$TMP"
[ "$(wc -l < "$TMP/.claude/session/gate-observe.log" | tr -d ' ')" = 2 ] || fail 'observation count'
jq -e -s 'length == 2 and all(.[]; .gate == "fixture-new" and .event == "missing" and .mode == "observe" and (.timestamp | length > 0))' \
  "$TMP/.claude/session/gate-observe.log" >/dev/null || fail 'JSON log'
echo 'PASS: observe allows and appends JSON per event'
CONFIG_MODE=enforce
rc=0; gate_would_block fixture-new observe missing "$TMP" || rc=$?
[ "$rc" = 2 ] || fail 'enforce allowed'
CONFIG_MODE=off
gate_would_block fixture-new enforce missing "$TMP"
[ "$(gate_observe_summary "$TMP")" = 'Gate observe: 2 would-block events' ] || fail 'summary'
CONFIG_MODE=null
[ "$(gate_mode_resolve fixture-new)" = enforce ] || fail 'default enforce'
[ "$(gate_mode_resolve fixture-new observe)" = observe ] || fail 'default observe'
[ "$(gate_mode_resolve fixture-new off)" = enforce ] || fail 'off default'
for CONFIG_MODE in typo '' false; do
  [ "$(gate_mode_resolve fixture-new observe 2>/dev/null)" = enforce ] || fail 'invalid mode'
done
echo 'PASS: enforce blocks, off allows, defaults and invalid modes are safe'
# Exercise the real config reader, not only the mode branch stub.
git -C "$TMP" init -q
printf '{}\n' > "$TMP/.claude/project-config.defaults.json"
printf '{"gates":{"fixture-new":{"mode":"off"}}}\n' > "$TMP/.claude/project-config.json"
(cd "$TMP"; unset -f config_get; . "$ROOT/.claude/hooks/_lib-read-config.sh"; [ "$(gate_mode_resolve fixture-new)" = off ]) || fail 'config integration'
# The briefing must remain offline in this test.
APEXYARD_OPS_ROOT="$TMP" APEXYARD_CWD="$TMP" APEXYARD_GH=/nonexistent \
  bash "$ROOT/.claude/skills/status/briefing.sh" > "$TMP/briefing"
[ "$(wc -l < "$TMP/briefing" | tr -d ' ')" = 4 ] || fail 'briefing line count'
grep -q 'Gate observe: 2 would-block events' "$TMP/briefing" || fail 'briefing count'
. "$ROOT/.claude/hooks/_lib-detect-deprecated-config.sh"
[ -z "$(detect_deprecated_config_keys "$ROOT/.claude/project-config.defaults.json" "$TMP/.claude/project-config.json")" ] || fail 'gate config marked deprecated'
echo 'PASS: real config, supported override key, and status briefing integration'
run_hook() {
  local command="$1" want="$2" output
  output=$(jq -nc --arg c "$command" --arg d "$TMP" '{cwd:$d,tool_input:{command:$c}}' | \
    (cd "$TMP"; bash "$ROOT/.claude/hooks/validate-commit-format.sh") 2>&1) || fail "hook blocked: $output"
  case "$want" in
    missing) [[ "$output" == *'WARN: missing Verified:'* ]] || fail "missing warning: $output" ;;
    invalid) [[ "$output" == *'WARN: invalid Verified:'* ]] || fail "invalid warning: $output"
      [[ "$output" != *'WARN: missing Verified:'* ]] || fail 'invalid also missing' ;;
    valid) [[ "$output" != *'WARN:'* ]] || fail "unexpected warning: $output" ;;
  esac
}
run_hook "git commit -m 'feat: subject'" missing
for value in e2e tests ci-only none; do
  run_hook "git commit -m 'feat: subject' -m 'Verified: $value'" valid
  run_hook "git commit -m 'feat: subject

Verified: $value'" valid
  run_hook "git commit --message='feat: subject' --message='Verified: $value'" valid
  printf 'feat: subject\n\nVerified: %s\n' "$value" > "$TMP/message"
  run_hook "git commit -F '$TMP/message'" valid
done
for value in tests bogus missing; do
  message='feat: subject'
  want=valid
  case "$value" in
    missing) want=missing ;;
    bogus) want=invalid; message+=$'\n\nVerified: bogus' ;;
    *) message+=$'\n\nVerified: tests' ;;
  esac
  command='git commit -m "$(cat <<'"'EOF'"$'\n'"$message"$'\nEOF\n)"'
  run_hook "$command" "$want"
done
run_hook "git commit -am 'feat: subject' -m 'Verified: tests'" valid
run_hook "git commit -m 'feat: subject' -m 'Verified: bogus'" invalid
run_hook "git commit -m 'feat: subject' -m 'Verified:'" invalid
run_hook "git commit -m 'feat: subject' -m 'Verified: tests
Verified: none'" invalid
run_hook "git commit -m 'feat: subject' -m 'Verified: tests

Ordinary body prose.'" missing
# A config edit must not disable the existing subject gate.
printf '{"gates":{"validate-commit-format":{"mode":"off"}}}\n' > "$TMP/.claude/project-config.json"
rc=0
jq -nc --arg d "$TMP" '{cwd:$d,tool_input:{command:"git commit -m bad"}}' | \
  (cd "$TMP"; bash "$ROOT/.claude/hooks/validate-commit-format.sh") > "$TMP/out" 2>&1 || rc=$?
[ "$rc" = 2 ] || fail 'subject enforcement changed'
echo 'PASS: trailers warn only for missing or invalid values; subject still blocks'
# Use commit-tree to build isolated history without invoking operator hooks.
tree=$(git -C "$TMP" mktree </dev/null)
parent=''
for value in e2e tests ci-only none missing invalid; do
  message="feat: $value"
  case "$value" in missing) ;; invalid) message+=$'\n\nVerified: bogus' ;; *) message+=$'\n\nVerified: '"$value" ;; esac
  args=(); [ -z "$parent" ] || args=(-p "$parent")
  parent=$(printf '%s\n' "$message" | GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
    GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com \
    git -C "$TMP" commit-tree "$tree" ${args[@]+"${args[@]}"})
done
git -C "$TMP" update-ref HEAD "$parent"
(cd "$TMP"; bash "$ROOT/bin/verified-commits.sh" 6) > "$TMP/report"
for value in e2e tests ci-only none missing invalid; do
  grep -q "^$value:$" "$TMP/report" || fail "missing group $value"
  awk -v g="$value" '
    /^[a-z0-9-]+:$/ { group=$0; sub(/:$/, "", group); next }
    group == g && $0 ~ "feat: " g "$" { found=1 }
    END { exit !found }
  ' "$TMP/report" || fail "wrong group for $value"
done
echo 'PASS: recent commits report groups all six values'
