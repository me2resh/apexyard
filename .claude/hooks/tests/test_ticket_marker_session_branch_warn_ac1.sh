#!/bin/bash
# AC1 (#1533): a marker from another session, or from another branch, produces
# a warning on stderr, and the exit code is 0.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib_ticket_marker_session_branch_warn.sh"

PASS=0 FAIL=0 FB_PASS=0 FB_FAIL=0
ok() { echo "PASS [AC1/$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [AC1/$1]: $2" >&2; FAIL=$((FAIL + 1)); }

BEFORE_LIB=$(tm_upstream_lib) || BEFORE_LIB=""

# --- fail-before: pinned pre-#1794 lib has no warn helper ---
if [ -n "$BEFORE_LIB" ]; then
  if ! grep -q 'active_ticket_warn_if_mismatch' "$BEFORE_LIB"; then
    echo "FAIL-BEFORE OK [AC1/no-warn-helper-on-d970c194]"
    FB_PASS=$((FB_PASS + 1))
  else
    echo "SKIP fail-before: pinned lib already has active_ticket_warn_if_mismatch"
  fi
else
  echo "NOTE: skip fail-before: no base ref d970c194b0ff5e14aac71d486c32dd3aa976d78a"
fi

OPS=$(tm_make_ops)
TREE="$OPS/workspace/p1"
CUR=$(git -C "$TREE" branch --show-current)

# Other session, matching branch → warn, exit 0
tm_write_marker "$TREE" org/p1 99 'Other session' other-session-id "$CUR"
out=$(tm_run_gate "$OPS" "$TREE/src/app.ts" this-session)
rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'WARN: ticket marker'; then
  ok "other-session-warns-exit-0"
else
  bad "other-session-warns-exit-0" "rc=$rc out=${out:0:400}"
fi

# Same session, other branch → warn, exit 0 (fresh ops so warn-once state is empty)
OPS2=$(tm_make_ops)
TREE2="$OPS2/workspace/p1"
CUR2=$(git -C "$TREE2" branch --show-current)
tm_write_marker "$TREE2" org/p1 99 'Other branch' branch-sess 'feature/other-branch'
out=$(tm_run_gate "$OPS2" "$TREE2/src/app.ts" branch-sess)
rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'WARN: ticket marker'; then
  ok "other-branch-warns-exit-0"
else
  bad "other-branch-warns-exit-0" "rc=$rc cur=$CUR2 out=${out:0:400}"
fi

# Matching session + branch → no warn, exit 0
OPS3=$(tm_make_ops)
TREE3="$OPS3/workspace/p1"
CUR3=$(git -C "$TREE3" branch --show-current)
tm_write_marker "$TREE3" org/p1 99 'Match' match-sess "$CUR3"
out=$(tm_run_gate "$OPS3" "$TREE3/src/app.ts" match-sess)
rc=$?
if [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q 'WARN: ticket marker'; then
  ok "matching-silent-exit-0"
else
  bad "matching-silent-exit-0" "rc=$rc out=${out:0:400}"
fi

echo "AC1 PASS=$PASS FAIL=$FAIL FAIL-BEFORE ok=$FB_PASS miss=$FB_FAIL"
[ "$FAIL" = 0 ] && [ "$FB_FAIL" = 0 ]
