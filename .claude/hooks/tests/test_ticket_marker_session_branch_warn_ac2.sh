#!/bin/bash
# AC2 (#1533): the warning appears once per session. Two edits in a row
# produce one warning.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib_ticket_marker_session_branch_warn.sh"

PASS=0 FAIL=0 FB_PASS=0 FB_FAIL=0
ok() { echo "PASS [AC2/$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [AC2/$1]: $2" >&2; FAIL=$((FAIL + 1)); }

BEFORE_LIB=$(tm_upstream_lib) || BEFORE_LIB=""
if [ -n "$BEFORE_LIB" ]; then
  if ! grep -q 'ticket-marker-warn' "$BEFORE_LIB"; then
    echo "FAIL-BEFORE OK [AC2/no-warn-state-on-d970c194]"
    FB_PASS=$((FB_PASS + 1))
  else
    echo "SKIP fail-before: pinned lib already has ticket-marker-warn"
  fi
else
  echo "NOTE: skip fail-before: no base ref d970c194b0ff5e14aac71d486c32dd3aa976d78a"
fi

OPS=$(tm_make_ops)
TREE="$OPS/workspace/p1"
CUR=$(git -C "$TREE" branch --show-current)
tm_write_marker "$TREE" org/p1 42 'Foreign' other-sess "$CUR"

out1=$(tm_run_gate "$OPS" "$TREE/src/app.ts" sess-A)
rc1=$?
c1=$(printf '%s' "$out1" | grep -c 'WARN: ticket marker' || true)
out2=$(tm_run_gate "$OPS" "$TREE/src/app.ts" sess-A)
rc2=$?
c2=$(printf '%s' "$out2" | grep -c 'WARN: ticket marker' || true)

if [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$c1" = 1 ] && [ "$c2" = 0 ]; then
  ok "once-per-session"
else
  bad "once-per-session" "rc1=$rc1 c1=$c1 rc2=$rc2 c2=$c2 out1=${out1:0:200}"
fi

# A second session still warns once for itself.
out3=$(tm_run_gate "$OPS" "$TREE/src/app.ts" sess-B)
c3=$(printf '%s' "$out3" | grep -c 'WARN: ticket marker' || true)
if [ "$c3" = 1 ]; then
  ok "other-session-still-warns"
else
  bad "other-session-still-warns" "c3=$c3 out=${out3:0:200}"
fi

echo "AC2 PASS=$PASS FAIL=$FAIL FAIL-BEFORE ok=$FB_PASS miss=$FB_FAIL"
[ "$FAIL" = 0 ] && [ "$FB_FAIL" = 0 ]
