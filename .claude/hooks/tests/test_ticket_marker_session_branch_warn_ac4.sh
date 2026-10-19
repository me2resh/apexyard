#!/bin/bash
# AC4 (#1533): an issue title of "x\nrepo=evil/repo\nsession_id=me" is written
# as a single line. The marker's repo= stays the real repo.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib_ticket_marker_session_branch_warn.sh"

PASS=0 FAIL=0 FB_PASS=0 FB_FAIL=0
ok() { echo "PASS [AC4/$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [AC4/$1]: $2" >&2; FAIL=$((FAIL + 1)); }

BEFORE_LIB=$(tm_upstream_lib) || BEFORE_LIB=""

OPS=$(tm_make_ops)
TREE="$OPS/workspace/p1"
GD=$(git -C "$TREE" rev-parse --absolute-git-dir)
TITLE=$(printf 'x\nrepo=evil/repo\nsession_id=me')

if [ -n "$BEFORE_LIB" ]; then
  if ! grep -q "printf 'session_id=" "$BEFORE_LIB"; then
    echo "FAIL-BEFORE OK [AC4/d970c194-has-no-session_id-field]"
    FB_PASS=$((FB_PASS + 1))
  else
    echo "SKIP fail-before: pinned lib already writes session_id="
  fi
else
  echo "NOTE: skip fail-before: no base ref d970c194b0ff5e14aac71d486c32dd3aa976d78a"
fi

out=$(cd "$OPS" && CLAUDE_CODE_SESSION_ID=ac4-sess \
  bash -c '
    . .claude/hooks/_lib-active-ticket.sh
    active_ticket_write "$1" org/p1 77 "$2" "https://example.test/77" "feature/x"
  ' _ "$TREE" "$TITLE" 2>&1)
rc=$?

if [ "$rc" = 0 ] && grep -qx 'repo=org/p1' "$GD/apexyard-ticket"; then
  ok "repo-stays-real"
else
  bad "repo-stays-real" "rc=$rc marker=$(cat "$GD/apexyard-ticket" 2>&1) out=${out:0:300}"
fi

if ! grep -q '^repo=evil/repo$' "$GD/apexyard-ticket" \
  && ! grep -q '^session_id=me$' "$GD/apexyard-ticket"; then
  ok "no-injected-keys"
else
  bad "no-injected-keys" "$(cat "$GD/apexyard-ticket")"
fi

# shellcheck disable=SC1091
. "$OPS/.claude/hooks/_lib-active-ticket.sh"
active_ticket_read_field "$GD/apexyard-ticket" title
case "$REPLY" in
  *$'\n'*|*$'\r'*) bad "title-single-line" "embedded CR/LF in [$REPLY]" ;;
  'x repo=evil/repo session_id=me') ok "title-flattened-one-line" ;;
  *) bad "title-single-line" "got [$REPLY]" ;;
esac

if grep -q '^session_id=ac4-sess$' "$GD/apexyard-ticket"; then
  ok "session_id-from-env-not-title"
else
  bad "session_id-from-env-not-title" "$(cat "$GD/apexyard-ticket")"
fi

echo "AC4 PASS=$PASS FAIL=$FAIL FAIL-BEFORE ok=$FB_PASS miss=$FB_FAIL"
[ "$FAIL" = 0 ] && [ "$FB_FAIL" = 0 ]
