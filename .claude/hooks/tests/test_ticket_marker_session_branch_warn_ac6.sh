#!/bin/bash
# AC6 (#1533): a title that starts with -- does not change the behaviour of
# any command.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib_ticket_marker_session_branch_warn.sh"

PASS=0 FAIL=0 FB_PASS=0 FB_FAIL=0
ok() { echo "PASS [AC6/$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [AC6/$1]: $2" >&2; FAIL=$((FAIL + 1)); }

BEFORE_LIB=$(tm_upstream_lib) || BEFORE_LIB=""
if [ -n "$BEFORE_LIB" ]; then
  # Pinned pre-#1794 lib already used printf '%s\n' for title — fail-before
  # pins that a leading -- title was already safe on the write path.
  if grep -q "printf 'title=%s\\\\n'" "$BEFORE_LIB"; then
    echo "FAIL-BEFORE OK [AC6/d970c194-printf-title]"
    FB_PASS=$((FB_PASS + 1))
  else
    echo "FAIL-BEFORE MISS [AC6/d970c194-printf-title]" >&2
    FB_FAIL=$((FB_FAIL + 1))
  fi
else
  echo "NOTE: skip fail-before: no base ref d970c194b0ff5e14aac71d486c32dd3aa976d78a"
fi

OPS=$(tm_make_ops)
TREE="$OPS/workspace/p1"
GD=$(git -C "$TREE" rev-parse --absolute-git-dir)
TITLE='--version looks like a flag'

out=$(cd "$OPS" && CLAUDE_CODE_SESSION_ID=ac6 \
  bash -c '
    . .claude/hooks/_lib-active-ticket.sh
    active_ticket_write "$1" org/p1 6 "$2" "https://example.test/6" "feature/x"
  ' _ "$TREE" "$TITLE" 2>&1)
rc=$?

if [ "$rc" = 0 ] && grep -qx "title=$TITLE" "$GD/apexyard-ticket"; then
  ok "leading-dashes-title-stored"
else
  bad "leading-dashes-title-stored" "rc=$rc out=${out:0:300} marker=$(cat "$GD/apexyard-ticket" 2>&1)"
fi

# shellcheck disable=SC1091
. "$OPS/.claude/hooks/_lib-active-ticket.sh"
active_ticket_read_field "$GD/apexyard-ticket" title
if [ "$REPLY" = "$TITLE" ]; then
  ok "leading-dashes-title-read"
else
  bad "leading-dashes-title-read" "got [$REPLY]"
fi

out=$(tm_run_gate "$OPS" "$TREE/src/app.ts" ac6)
rc=$?
if [ "$rc" = 0 ]; then
  ok "gate-unaffected-by-dash-title"
else
  bad "gate-unaffected-by-dash-title" "rc=$rc out=${out:0:300}"
fi

echo "AC6 PASS=$PASS FAIL=$FAIL FAIL-BEFORE ok=$FB_PASS miss=$FB_FAIL"
[ "$FAIL" = 0 ] && [ "$FB_FAIL" = 0 ]
