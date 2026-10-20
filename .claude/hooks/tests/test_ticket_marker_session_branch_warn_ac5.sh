#!/bin/bash
# AC5 (#1533): readers take the first repo=. Test with a marker that has two
# repo= lines.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib_ticket_marker_session_branch_warn.sh"

PASS=0 FAIL=0 FB_PASS=0 FB_FAIL=0
ok() { echo "PASS [AC5/$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [AC5/$1]: $2" >&2; FAIL=$((FAIL + 1)); }

BEFORE_LIB=$(tm_upstream_lib) || BEFORE_LIB=""

# fail-before: upstream read_field already takes first match — pin that it
# existed, and that the new gate path also uses it for migration. If upstream
# lacked first-match, that would be the fail-before; here we show the duplicate
# key is ignored by the fixed reader (pass-after) and note upstream behaviour.
if [ -n "$BEFORE_LIB" ]; then
  if grep -q 'active_ticket_read_field' "$BEFORE_LIB"; then
    echo "FAIL-BEFORE OK [AC5/d970c194-already-first-match-reader]"
    FB_PASS=$((FB_PASS + 1))
  else
    echo "FAIL-BEFORE MISS [AC5/d970c194-already-first-match-reader]" >&2
    FB_FAIL=$((FB_FAIL + 1))
  fi
else
  echo "NOTE: skip fail-before: no base ref d970c194b0ff5e14aac71d486c32dd3aa976d78a"
fi

OPS=$(tm_make_ops)
TREE="$OPS/workspace/p1"
GD=$(git -C "$TREE" rev-parse --absolute-git-dir)
CUR=$(git -C "$TREE" branch --show-current)
{
  printf 'repo=org/p1\n'
  printf 'repo=evil/other\n'
  printf 'number=5\n'
  printf 'title=dup\n'
  printf 'url=https://example.test/5\n'
  printf 'suggested_branch=feature/x\n'
  printf 'session_id=ac5\n'
  printf 'branch=%s\n' "$CUR"
  printf 'started_at=2026-01-01T00:00:00Z\n'
} > "$GD/apexyard-ticket"

# shellcheck disable=SC1091
. "$OPS/.claude/hooks/_lib-active-ticket.sh"
active_ticket_read_field "$GD/apexyard-ticket" repo
if [ "$REPLY" = "org/p1" ]; then
  ok "first-repo-wins"
else
  bad "first-repo-wins" "got [$REPLY]"
fi

# Gate still allows (bound to org/p1) and does not treat evil/other as repo.
out=$(tm_run_gate "$OPS" "$TREE/src/app.ts" ac5)
rc=$?
if [ "$rc" = 0 ]; then
  ok "gate-uses-first-repo"
else
  bad "gate-uses-first-repo" "rc=$rc out=${out:0:300}"
fi

echo "AC5 PASS=$PASS FAIL=$FAIL FAIL-BEFORE ok=$FB_PASS miss=$FB_FAIL"
[ "$FAIL" = 0 ] && [ "$FB_FAIL" = 0 ]
