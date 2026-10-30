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
check 0 'marker repo' grep -qx 'repo=me2resh/apexyard' .git/apexyard-ticket
check 0 'branch suggestion' grep -qx 'suggested_branch=fix/GH-1928-headless-start' .git/apexyard-ticket
check 0 'no pending file' test ! -e .claude/session/start-ticket-headless-1928.pending
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
