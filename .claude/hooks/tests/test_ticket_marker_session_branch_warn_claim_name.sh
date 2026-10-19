#!/bin/bash
# #1808: warn-claim file is named by a pure-bash hash of the marker
# identity, so a long marker path still warns once per session.
# Fail-before pins commit 5734e29 (A4/A2 head that still used the raw name).
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib_ticket_marker_session_branch_warn.sh"

PASS=0 FAIL=0 FB_PASS=0 FB_FAIL=0
ok() { echo "PASS [claim/$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [claim/$1]: $2" >&2; FAIL=$((FAIL + 1)); }
fb_ok() { echo "FAIL-BEFORE OK [claim/$1]"; FB_PASS=$((FB_PASS + 1)); }
fb_miss() { echo "FAIL-BEFORE MISS [claim/$1]: $2" >&2; FB_FAIL=$((FB_FAIL + 1)); }

# Install _lib-active-ticket.sh from the pinned pre-fix commit into <ops>.
# Override with APEXYARD_CLAIM_BEFORE_SHA or APEXYARD_CLAIM_BEFORE_DIR.
tm_install_claim_before_lib() {
  local ops="$1" root sha dir
  root=$(tm_src_root)
  dir="${APEXYARD_CLAIM_BEFORE_DIR:-}"
  sha="${APEXYARD_CLAIM_BEFORE_SHA:-5734e29bd51c369951763aafbc81c7dd3c97c7ab}"
  if [ -n "$dir" ] && [ -f "$dir/_lib-active-ticket.sh" ]; then
    cp "$dir/_lib-active-ticket.sh" "$ops/.claude/hooks/"
    return 0
  fi
  if git -C "$root" show "$sha:.claude/hooks/_lib-active-ticket.sh" \
    > "$ops/.claude/hooks/_lib-active-ticket.sh" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Build a marker whose absolute path is longer than 200 characters under
# <home>. Prints the marker path. Returns 1 when the path is still short.
tm_long_marker() {
  local home="$1" sid="${2:-other-0000-1111-2222-333333333333}"
  local seg d m
  seg=$(printf 'd%.0s' $(seq 1 60))
  d="$home"
  while [ "${#d}" -lt 220 ]; do
    d="$d/$seg"
  done
  mkdir -p "$d" || return 1
  m="$d/apexyard-ticket"
  {
    printf 'repo=me2resh/apexyard\n'
    printf 'number=1533\n'
    printf 'session_id=%s\n' "$sid"
    printf 'branch=x\n'
    printf 'started_at=2026-01-01T00:00:00Z\n'
  } > "$m"
  if [ "${#m}" -le 200 ]; then
    printf 'short path len=%s\n' "${#m}" >&2
    return 1
  fi
  printf '%s\n' "$m"
}

# Count WARN lines from two back-to-back mismatch calls on <marker>.
# $1=ops-home $2=marker $3=session_id. Prints the warn count.
tm_warn_twice() {
  local home="$1" marker="$2" sid="$3" c=0 c1_out c2_out
  # shellcheck disable=SC1091
  . "$home/.claude/hooks/_lib-active-ticket.sh"
  c1_out=$(CLAUDE_CODE_SESSION_ID="$sid" \
    active_ticket_warn_if_mismatch "$marker" "" "$home" 2>&1)
  printf '%s' "$c1_out" | grep -q '^WARN: ticket marker' && c=$((c + 1))
  c2_out=$(CLAUDE_CODE_SESSION_ID="$sid" \
    active_ticket_warn_if_mismatch "$marker" "" "$home" 2>&1)
  printf '%s' "$c2_out" | grep -q '^WARN: ticket marker' && c=$((c + 1))
  printf '%s\n' "$c"
}

# --- fail-before against 5734e29 ----------------------------------------
FB_OPS=$(tm_make_ops)
if tm_install_claim_before_lib "$FB_OPS"; then
  mkdir -p "$FB_OPS/.claude/session"
  FB_MARKER=$(tm_long_marker "$FB_OPS") || {
    fb_miss "long-path-warns-every-edit-on-5734e29" "could not build long marker"
    FB_MARKER=""
  }
  if [ -n "$FB_MARKER" ]; then
    w=$(tm_warn_twice "$FB_OPS" "$FB_MARKER" \
      7fef1a01-205b-4cc5-9aac-9a28f79d0941)
    if [ "$w" = 2 ]; then
      fb_ok "long-path-warns-every-edit-on-5734e29"
    else
      fb_miss "long-path-warns-every-edit-on-5734e29" \
        "expected 2 warnings on pre-fix lib, got w=$w path_len=${#FB_MARKER}"
    fi
  fi
else
  echo "NOTE: skip fail-before (cannot load pre-fix hooks from ancestor)"
fi

# --- pass-after: long path warns once -----------------------------------
OPS=$(tm_make_ops)
mkdir -p "$OPS/.claude/session"
MARKER=$(tm_long_marker "$OPS") || {
  bad "long-path-warns-once" "could not build long marker"
  MARKER=""
}
if [ -n "$MARKER" ]; then
  w=$(tm_warn_twice "$OPS" "$MARKER" 7fef1a01-205b-4cc5-9aac-9a28f79d0941)
  if [ "$w" = 1 ]; then
    ok "long-path-warns-once"
  else
    bad "long-path-warns-once" "expected 1 warning, got w=$w path_len=${#MARKER}"
  fi
fi

# --- pass-after: two identities → two claim files -----------------------
OPS2=$(tm_make_ops)
mkdir -p "$OPS2/.claude/session"
# shellcheck disable=SC1091
. "$OPS2/.claude/hooks/_lib-active-ticket.sh"
M1="$OPS2/.claude/session/m1-ticket"
M2="$OPS2/.claude/session/m2-ticket"
printf 'repo=org/p1\nnumber=10\nsession_id=s-a\nbranch=x\nstarted_at=2026-01-01T00:00:00Z\n' > "$M1"
printf 'repo=org/p1\nnumber=11\nsession_id=s-b\nbranch=x\nstarted_at=2026-01-01T00:00:00Z\n' > "$M2"
CLAUDE_CODE_SESSION_ID=sess-me active_ticket_warn_if_mismatch "$M1" "" "$OPS2" 2>/dev/null || true
CLAUDE_CODE_SESSION_ID=sess-me active_ticket_warn_if_mismatch "$M2" "" "$OPS2" 2>/dev/null || true
if CLAUDE_CODE_SESSION_ID=sess-me active_ticket_mismatch_warn_dir "$OPS2"; then
  WARN_DIR="$REPLY"
  n=$(find "$WARN_DIR" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" = 2 ]; then
    ok "two-identities-two-claims"
  else
    bad "two-identities-two-claims" "expected 2 claim files, got n=$n dir=$WARN_DIR"
  fi
else
  bad "two-identities-two-claims" "no warn dir for sess-me"
fi

echo "claim PASS=$PASS FAIL=$FAIL FAIL-BEFORE ok=$FB_PASS miss=$FB_FAIL"
[ "$FAIL" = 0 ] && [ "$FB_FAIL" = 0 ]
