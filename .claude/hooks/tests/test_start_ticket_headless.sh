#!/bin/bash
# Fixture-only declaration and raw dispatcher grammar tests. Bash 3.2.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export APEXYARD_OPS_DISABLE_PIN=1 CLAUDE_CODE_SESSION_ID=headless-1928
export APEXYARD_OPS_PIN_DIR="$TMP/pins"
mkdir -p "$TMP/ops/.claude/hooks" "$TMP/ops/bin" "$TMP/stubs"
cp "$ROOT"/.claude/hooks/_lib*.sh "$TMP/ops/.claude/hooks/"
cp "$ROOT/bin/apexyard-start-ticket" "$TMP/ops/bin/"
touch "$TMP/ops/.apexyard-fork"
printf 'projects: []\n' > "$TMP/ops/apexyard.projects.yaml"
cat > "$TMP/ops/.claude/hooks/_lib-tracker.sh" <<'STUB'
tracker_view() {
  [ "$1" = 1928 ] && [ "$2" = me2resh/apexyard ] || return 1
  printf '%s\n' '{"title":"[Fix] the headless start","url":"https://example.test/1928","state":"OPEN"}'
}
STUB
git -C "$TMP/ops" init -q
git -C "$TMP/ops" remote add origin https://github.com/me2resh/apexyard.git
cd -P "$TMP/ops" || exit 1
pass=0; fail=0
check() {
  local want=$1 name=$2 rc=0
  shift 2
  "$@" > "$TMP/out" 2>&1 || rc=$?
  if [ "$rc" = "$want" ]; then pass=$((pass+1)); else
    printf 'FAIL: %s (wanted %s got %s)\n' "$name" "$want" "$rc"
    cat "$TMP/out"; fail=$((fail+1))
  fi
}
check 0 'headless declaration' /bin/bash bin/apexyard-start-ticket me2resh/apexyard#1928
check 0 'progress note created' grep -qx 'Task: me2resh/apexyard#1928' .git/apexyard-progress.md
check 0 'marker repo' grep -qx 'repo=me2resh/apexyard' .git/apexyard-ticket
check 0 'branch suggestion' grep -qx 'suggested_branch=fix/GH-1928-headless-start' .git/apexyard-ticket
check 0 'no pending file' test ! -e .claude/session/start-ticket-headless-1928.pending
# A locked note must not fail a start, with or without a command.
cp "$ROOT/.claude/project-config.defaults.json" .claude/
for baseline_command in 'exit 0' ''; do
  jq -n --arg cmd "$baseline_command" '{checks:{baseline_command:$cmd,baseline_mode:"warn"}}' > .claude/project-config.json
  mkdir .git/apexyard-progress.md.lock
  check 0 "locked note start: $baseline_command" /bin/bash bin/apexyard-start-ticket me2resh/apexyard#1928
  cp "$TMP/out" "$TMP/locked-output"
  check 0 'locked note warning count' test "$(grep -c WARN "$TMP/locked-output")" = 1
  check 0 'locked note warning reason' grep -q 'evidence not recorded' "$TMP/locked-output"
  check 0 'locked note marker written' grep -qx 'number=1928' .git/apexyard-ticket
  rmdir .git/apexyard-progress.md.lock
done
rm .claude/project-config.json
for ref in 'bad#1928' 'a/b/c#1928' '../b#1928' 'a/b#x' 'a/b#1;id'; do
  check 1 "bad input $ref" /bin/bash bin/apexyard-start-ticket "$ref"
done
check 1 'tracker failure' /bin/bash bin/apexyard-start-ticket me2resh/apexyard#999
check 0 'tracker failure leaves no pending' test ! -e .claude/session/start-ticket-headless-1928.pending
printf 'sentinel\n' > "$TMP/sentinel"
ln -s "$TMP/sentinel" .claude/session/start-ticket-headless-1928.pending
check 1 'pending symlink' /bin/bash bin/apexyard-start-ticket me2resh/apexyard#1928
check 0 'symlink target unchanged' grep -qx sentinel "$TMP/sentinel"
rm .claude/session/start-ticket-headless-1928.pending
mv .claude/session .claude/saved-session
ln -s saved-session .claude/session
check 1 'session symlink' /bin/bash bin/apexyard-start-ticket me2resh/apexyard#1928
rm .claude/session
mv .claude/saved-session .claude/session
# A stale tree marker must not mask a failed tree write, even if legacy succeeds.
sed 's/number=1928/number=1927/' .git/apexyard-ticket > "$TMP/stale"
cp "$TMP/stale" .git/apexyard-ticket
cp .claude/hooks/_lib-active-ticket.sh "$TMP/active-ticket.sh"
cat >> .claude/hooks/_lib-active-ticket.sh <<'STUB'
active_ticket_write() { return 1; }
active_ticket_write_legacy() { printf 'legacy succeeded\n' > .claude/session/legacy-result; }
STUB
check 1 'tree write failure despite legacy success' /bin/bash bin/apexyard-start-ticket me2resh/apexyard#1928
cp "$TMP/out" "$TMP/write-error"
check 0 'tree write failure diagnostic' grep -q 'working tree marker write failed' "$TMP/write-error"
check 0 'legacy write succeeded' grep -qx 'legacy succeeded' .claude/session/legacy-result
check 0 'old tree marker remains' grep -qx 'number=1927' .git/apexyard-ticket
check 0 'failed write leaves no pending' test ! -e .claude/session/start-ticket-headless-1928.pending
cp "$TMP/active-ticket.sh" .claude/hooks/_lib-active-ticket.sh
sed 's/"OPEN"/"Canceled"/' .claude/hooks/_lib-tracker.sh > "$TMP/canceled"
cp .claude/hooks/_lib-tracker.sh "$TMP/tracker.sh"
cp "$TMP/canceled" .claude/hooks/_lib-tracker.sh
check 1 'Canceled issue refused' /bin/bash bin/apexyard-start-ticket me2resh/apexyard#1928
cp "$TMP/out" "$TMP/canceled-error"
check 0 'Canceled diagnostic' grep -q 'issue is closed' "$TMP/canceled-error"
check 0 'Canceled leaves marker unchanged' grep -qx 'number=1927' .git/apexyard-ticket
cp "$TMP/tracker.sh" .claude/hooks/_lib-tracker.sh
# Use the real dispatcher and its hooks, with the fixture as effective cwd.
# It must check the helper belonging to its own hook tree.
cp "$ROOT"/.claude/hooks/*.sh .claude/hooks/
cp "$ROOT/.claude/project-config.defaults.json" .claude/
run_dispatch() {
  jq -cn --arg cwd "$PWD" --arg cmd "$1" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}' |
    /bin/bash .claude/hooks/dispatch-bash.sh
}
check 0 'exact relative helper' run_dispatch 'bin/apexyard-start-ticket me2resh/apexyard#1928'
check 0 'exact absolute helper' run_dispatch "$PWD/bin/apexyard-start-ticket me2resh/apexyard#1928"
# Check literal cd grammar directly and through the dispatcher.
. .claude/hooks/_lib-start-ticket-command.sh
mkdir -p "$TMP/real" "$TMP/space dir" "$TMP/\$literal"
mkdir -p "$TMP/d{1..1}" "$TMP/d{a,b}" "$TMP/d!" '=literal'
ln -s "$TMP/real" "$TMP/link"
helper="$PWD/bin/apexyard-start-ticket o/r#1"
check 0 'absolute cd matcher' start_ticket_command_allowed "cd $TMP/real && $helper" "$TMP/real" "$PWD"
check 0 'absolute cd dispatcher' run_dispatch "cd $TMP/real && $helper"
check 1 'relative helper outside root' start_ticket_command_allowed 'bin/apexyard-start-ticket o/r#1' "$TMP/real" "$PWD"
for cmd in \
  "cd real && $helper" \
  "cd $TMP/space dir && $helper" \
  "cd $TMP/\$literal && $helper" \
  "cd $TMP/d{1..1} && $helper" \
  "cd $TMP/d{a,b} && $helper" \
  "cd $TMP/d! && $helper" \
  "cd =literal && $helper" \
  "cd $TMP/link && $helper" \
  "cd $TMP/link/ && $helper" \
  "cd $TMP/missing && $helper" \
  "cd -P $TMP/real && $helper" \
  "cd -L $TMP/real && $helper" \
  "cd -- $TMP/real && $helper" \
  "pushd $TMP/real && $helper" \
  "cd $TMP/real; $helper" \
  "cd $TMP/real && bin/apexyard-start-ticket o/r#1" \
  "cd $TMP/real && cd $TMP/real && $helper" \
  "cd $TMP/real && $helper && echo x" \
  "cd  $TMP/real && $helper" \
  "cd $TMP/real  && $helper" \
  "cd $TMP/real &&  $helper"; do
  check 1 "cd matcher refuses $cmd" start_ticket_command_allowed "$cmd" "$PWD" "$PWD"
  check 2 "cd dispatcher refuses $cmd" run_dispatch "$cmd"
done
# Test the protected-target hook directly for mentions. PR validation belongs
# to separate suites and requires tracker fixtures. No command is executed.
run_protected() {
  jq -cn --arg cwd "$PWD" --arg cmd "$1" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}' |
    /bin/bash .claude/hooks/block-protected-target-writes.sh
}
for cmd in \
  'git commit -m "fix: document apexyard-start-ticket"' \
  'gh pr create --title "fix(#1928): apexyard-start-ticket" --body "Refs #1928"' \
  'gh pr create --title "fix(#1928): headless helper" --body "Use apexyard-start-ticket. Refs #1928"' \
  'grep apexyard-start-ticket README.md' \
  'echo apexyard-start-ticket'; do
  check 0 "ordinary mention $cmd" run_protected "$cmd"
done
# Literal command text tests the parser without expanding fixture variables.
# shellcheck disable=SC2016
for cmd in \
  'bin/APEXYARD-START-TICKET me2resh/apexyard#1928' \
  './bin/apexyard-start-ticket me2resh/apexyard#1928' \
  '/tmp/apexyard-start-ticket me2resh/apexyard#1928' \
  'bash bin/apexyard-start-ticket me2resh/apexyard#1928' \
  'env bin/apexyard-start-ticket me2resh/apexyard#1928' \
  'bin/apexyard-start-ticket $ticket' \
  'eval "bin/apexyard-start-ticket me2resh/apexyard#1928"' \
  'echo x | bin/apexyard-start-ticket me2resh/apexyard#1928' \
  'bin/apexyard-start-ticket me2resh/apexyard#1928 extra' \
  'bin/apexyard-start-ticket me2resh/apexyard#1928 > /tmp/out' \
  'h=bin/apexyard-start-ticket; $h me2resh/apexyard#1928'; do
  check 2 "imitation $cmd" run_dispatch "$cmd"
done
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
