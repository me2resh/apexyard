#!/bin/bash
# AC7 (#1533): test_block_ambient_tracker_repo.sh and test_status_briefing.sh
# still pass with the new keys present. This file also plants a marker that
# holds session_id= and branch= and checks those suites' readers still see
# repo=/number=.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib_ticket_marker_session_branch_warn.sh"

PASS=0 FAIL=0 FB_PASS=0 FB_FAIL=0
ok() { echo "PASS [AC7/$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [AC7/$1]: $2" >&2; FAIL=$((FAIL + 1)); }

SRC_ROOT=$(tm_src_root)
BEFORE_LIB=$(tm_upstream_lib) || BEFORE_LIB=""
if [ -n "$BEFORE_LIB" ]; then
  if ! grep -q "printf 'branch=%s\\\\n'" "$BEFORE_LIB"; then
    echo "FAIL-BEFORE OK [AC7/d970c194-has-no-branch-field]"
    FB_PASS=$((FB_PASS + 1))
  else
    echo "SKIP fail-before: pinned lib already writes branch="
  fi
else
  echo "NOTE: skip fail-before: no base ref d970c194b0ff5e14aac71d486c32dd3aa976d78a"
fi

# Readers used by block-ambient and status briefing take the first key.
OPS=$(tm_make_ops)
TREE="$OPS/workspace/p1"
GD=$(git -C "$TREE" rev-parse --absolute-git-dir)
CUR=$(git -C "$TREE" branch --show-current)
{
  printf 'repo=org/p1\n'
  printf 'number=7\n'
  printf 'title=with-new-keys\n'
  printf 'url=https://example.test/7\n'
  printf 'suggested_branch=feature/x\n'
  printf 'session_id=ac7-sess\n'
  printf 'branch=%s\n' "$CUR"
  printf 'started_at=2026-01-01T00:00:00Z\n'
} > "$GD/apexyard-ticket"

# Mimic block-ambient's sed|head reader and status briefing's first-match loop.
repo=$(sed -n 's/^repo=//p' "$GD/apexyard-ticket" | head -1)
num=$(sed -n 's/^number=//p' "$GD/apexyard-ticket" | head -1)
if [ "$repo" = "org/p1" ] && [ "$num" = "7" ]; then
  ok "ambient-style-reader"
else
  bad "ambient-style-reader" "repo=$repo num=$num"
fi

# shellcheck disable=SC1091
. "$OPS/.claude/hooks/_lib-active-ticket.sh"
active_ticket_read_field "$GD/apexyard-ticket" repo
r1="$REPLY"
active_ticket_read_field "$GD/apexyard-ticket" session_id
s1="$REPLY"
if [ "$r1" = "org/p1" ] && [ "$s1" = "ac7-sess" ]; then
  ok "shared-reader-with-new-keys"
else
  bad "shared-reader-with-new-keys" "repo=$r1 sid=$s1"
fi

# Run the two named suites (they must stay green with the new writer fields
# present in the library under test).
bat_out=$(/bin/bash "$SRC_ROOT/.claude/hooks/tests/test_block_ambient_tracker_repo.sh" 2>&1)
bat_rc=$?
if [ "$bat_rc" = 0 ]; then
  ok "test_block_ambient_tracker_repo"
else
  bad "test_block_ambient_tracker_repo" "rc=$bat_rc tail=$(printf '%s' "$bat_out" | tail -5)"
fi

sb_out=$(/bin/bash "$SRC_ROOT/.claude/hooks/tests/test_status_briefing.sh" 2>&1)
sb_rc=$?
if [ "$sb_rc" = 0 ]; then
  ok "test_status_briefing"
else
  bad "test_status_briefing" "rc=$sb_rc tail=$(printf '%s' "$sb_out" | tail -5)"
fi

echo "AC7 PASS=$PASS FAIL=$FAIL FAIL-BEFORE ok=$FB_PASS miss=$FB_FAIL"
[ "$FAIL" = 0 ] && [ "$FB_FAIL" = 0 ]
