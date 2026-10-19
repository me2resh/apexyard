#!/bin/bash
# AC3 (#1533): when the question cannot be answered, /start-ticket cancels and
# the existing marker is byte-for-byte unchanged.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib_ticket_marker_session_branch_warn.sh"

PASS=0 FAIL=0 FB_PASS=0 FB_FAIL=0
ok() { echo "PASS [AC3/$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [AC3/$1]: $2" >&2; FAIL=$((FAIL + 1)); }

SRC_ROOT=$(tm_src_root)
BEFORE_LIB=$(tm_upstream_lib) || BEFORE_LIB=""

OPS=$(tm_make_ops)
TREE="$OPS/workspace/p1"
CUR=$(git -C "$TREE" branch --show-current)
GD=$(git -C "$TREE" rev-parse --absolute-git-dir)
tm_write_marker "$TREE" org/p1 10 'Original' session-old "$CUR"
cp "$GD/apexyard-ticket" "$OPS/marker.before"
BEFORE=$(cksum < "$OPS/marker.before")

# fail-before: pinned pre-#1794 write_from_file overwrites without the guard
if [ -n "$BEFORE_LIB" ]; then
  if grep -q 'active_ticket_foreign_overwrite' "$BEFORE_LIB"; then
    echo "SKIP fail-before: pinned lib already has active_ticket_foreign_overwrite"
  else
    cp "$BEFORE_LIB" "$OPS/.claude/hooks/_lib-active-ticket.sh"
    PENDING="$OPS/.claude/session/start-ticket-headless.pending"
    printf 'repo=org/p1\nnumber=99\ntitle=Takeover\nurl=https://example.test/99\nsuggested_branch=feature/x\n' > "$PENDING"
    (cd "$OPS" && env -u APEXYARD_START_TICKET_TAKEOVER CLAUDE_CODE_SESSION_ID=session-new \
      bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' _ "$TREE" "$PENDING") >/dev/null 2>&1 || true
    AFTER_FB=$(cksum < "$GD/apexyard-ticket")
    if [ "$BEFORE" != "$AFTER_FB" ]; then
      echo "FAIL-BEFORE OK [AC3/d970c194-overwrites-without-guard]"
      FB_PASS=$((FB_PASS + 1))
    else
      echo "FAIL-BEFORE MISS [AC3/d970c194-overwrites-without-guard]: marker unchanged on pinned lib" >&2
      FB_FAIL=$((FB_FAIL + 1))
    fi
  fi
  # Restore fixed lib and original marker for the pass-after proof.
  cp "$SRC_ROOT/.claude/hooks/_lib-active-ticket.sh" "$OPS/.claude/hooks/_lib-active-ticket.sh"
  cp "$OPS/marker.before" "$GD/apexyard-ticket"
else
  echo "NOTE: skip fail-before: no base ref d970c194b0ff5e14aac71d486c32dd3aa976d78a"
fi

PENDING="$OPS/.claude/session/start-ticket-headless.pending"
printf 'repo=org/p1\nnumber=99\ntitle=Takeover\nurl=https://example.test/99\nsuggested_branch=feature/x\n' > "$PENDING"
out=$(cd "$OPS" && env -u APEXYARD_START_TICKET_TAKEOVER CLAUDE_CODE_SESSION_ID=session-new \
  bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' _ "$TREE" "$PENDING" 2>&1)
rc=$?
AFTER=$(cksum < "$GD/apexyard-ticket")
if [ "$rc" != 0 ] && [ "$BEFORE" = "$AFTER" ] \
  && cmp -s "$OPS/marker.before" "$GD/apexyard-ticket" \
  && printf '%s' "$out" | grep -q 'ticket marker not overwritten'; then
  ok "headless-cancel-byte-identical"
else
  bad "headless-cancel-byte-identical" "rc=$rc before=$BEFORE after=$AFTER out=${out:0:300}"
fi

# Take over still works when the flag is set; audit line names both tickets.
printf 'repo=org/p1\nnumber=99\ntitle=Takeover\nurl=https://example.test/99\nsuggested_branch=feature/x\n' > "$PENDING"
out=$(cd "$OPS" && APEXYARD_START_TICKET_TAKEOVER=1 CLAUDE_CODE_SESSION_ID=session-new \
  bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' _ "$TREE" "$PENDING" 2>&1)
rc=$?
audit_re='apexyard: ticket marker taken over: org/p1#10 (session session-old) -> org/p1#99 (session session-new)'
if [ "$rc" = 0 ] && grep -qx 'number=99' "$GD/apexyard-ticket" \
  && printf '%s' "$out" | grep -Fq "$audit_re"; then
  ok "takeover-flag-allows-overwrite"
else
  bad "takeover-flag-allows-overwrite" "rc=$rc out=${out:0:400}"
fi

# A normal same-session write does not print the take-over audit line.
cp "$OPS/marker.before" "$GD/apexyard-ticket"
# Rewrite marker as session-new holding #10, then same session starts #88.
tm_write_marker "$TREE" org/p1 10 'Original' session-new "$CUR"
PENDING="$OPS/.claude/session/start-ticket-same.pending"
printf 'repo=org/p1\nnumber=88\ntitle=SameSession\nurl=https://example.test/88\nsuggested_branch=feature/x\n' > "$PENDING"
out=$(cd "$OPS" && env -u APEXYARD_START_TICKET_TAKEOVER CLAUDE_CODE_SESSION_ID=session-new \
  bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' _ "$TREE" "$PENDING" 2>&1)
rc=$?
if [ "$rc" = 0 ] && grep -qx 'number=88' "$GD/apexyard-ticket" \
  && ! printf '%s' "$out" | grep -q 'ticket marker taken over'; then
  ok "normal-write-no-takeover-audit"
else
  bad "normal-write-no-takeover-audit" "rc=$rc out=${out:0:400}"
fi

# Note (AgDR-0257): Bash cannot tell an inline flag from an exported /
# inherited one, so there is no test that refuses an inherited flag.

echo "AC3 PASS=$PASS FAIL=$FAIL FAIL-BEFORE ok=$FB_PASS miss=$FB_FAIL"
[ "$FAIL" = 0 ] && [ "$FB_FAIL" = 0 ]
