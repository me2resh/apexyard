#!/bin/bash
# Hakim A2 / A4 on PR #1794 / #1533 (CEO 2026-10-19: fix both before merge).
# A4: valid linked worktree may start its own ticket despite shared
#     current-ticket; invalid-tree legacy cancel stays byte-identical.
# A2: audit line only after a successful write; control chars stripped.
# Fail-before runs the same probes against ea8d21a (pre-fix head).
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib_ticket_marker_session_branch_warn.sh"

PASS=0 FAIL=0 FB_PASS=0 FB_FAIL=0
ok() { echo "PASS [hakim/$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [hakim/$1]: $2" >&2; FAIL=$((FAIL + 1)); }
fb_ok() { echo "FAIL-BEFORE OK [hakim/$1]"; FB_PASS=$((FB_PASS + 1)); }
fb_miss() { echo "FAIL-BEFORE MISS [hakim/$1]: $2" >&2; FB_FAIL=$((FB_FAIL + 1)); }

# Install hooks from ea8d21a (the commit kept under this fix). Override with
# APEXYARD_HAKIM_BEFORE_SHA or APEXYARD_HAKIM_BEFORE_DIR.
tm_install_hakim_before_hooks() {
  local ops="$1" root sha dir
  root=$(tm_src_root)
  dir="${APEXYARD_HAKIM_BEFORE_DIR:-}"
  sha="${APEXYARD_HAKIM_BEFORE_SHA:-ea8d21a480ed0da32237076c85c59fb8141f0b67}"
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

# A4: headless start in a fresh valid linked worktree with another session's
# different current-ticket succeeds and writes the per-tree marker.
run_a4_valid_worktree() {
  local ops wt_parent wt pend out rc gd
  ops=$(tm_make_ops)
  wt_parent=$(mktemp -d)
  wt="$wt_parent/wt"
  git -C "$ops" worktree add -q "$wt" -b wt-a4 HEAD
  pend="$ops/.claude/session/start-ticket-sa.pending"
  printf 'repo=org/ops\nnumber=1\ntitle=A\nurl=u\nsuggested_branch=b\n' > "$pend"
  (cd "$ops" && CLAUDE_CODE_SESSION_ID=s-a \
    bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' \
    _ "$ops" "$pend") >/dev/null 2>&1
  [ -f "$ops/.claude/session/current-ticket" ] || { rm -rf "$wt_parent"; return 1; }
  pend="$ops/.claude/session/start-ticket-sb.pending"
  printf 'repo=org/ops\nnumber=2\ntitle=B\nurl=u\nsuggested_branch=b\n' > "$pend"
  out=$(cd "$ops" && env -u APEXYARD_START_TICKET_TAKEOVER CLAUDE_CODE_SESSION_ID=s-b \
    bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' \
    _ "$wt" "$pend" 2>&1)
  rc=$?
  gd=$(git -C "$wt" rev-parse --absolute-git-dir)
  if [ "$rc" = 0 ] && [ -f "$gd/apexyard-ticket" ] \
    && grep -qx 'number=2' "$gd/apexyard-ticket" \
    && grep -qx 'session_id=s-b' "$gd/apexyard-ticket" \
    && ! printf '%s' "$out" | grep -q 'ticket marker not overwritten' \
    && ! printf '%s' "$out" | grep -qi 'use a separate worktree'; then
    git -C "$ops" worktree remove -f "$wt" 2>/dev/null || true
    rm -rf "$wt_parent"
    return 0
  fi
  printf 'rc=%s out=%s marker=%s\n' "$rc" "${out:0:300}" "$(cat "$gd/apexyard-ticket" 2>/dev/null | tr '\n' ';')"
  git -C "$ops" worktree remove -f "$wt" 2>/dev/null || true
  rm -rf "$wt_parent"
  return 1
}

# Finding 3 / A4 keep: invalid-tree headless foreign overwrite of current-ticket
# still cancels with the file byte-for-byte unchanged.
run_a4_invalid_tree_cancel() {
  local ops tree2 pend before after out rc
  ops=$(tm_make_ops)
  tree2="$ops/workspace/p2"
  mkdir -p "$tree2/src"
  git init -q "$tree2"
  git -C "$tree2" config user.email t@e
  git -C "$tree2" config user.name t
  printf 'x\n' > "$tree2/src/a.ts"
  git -C "$tree2" add src/a.ts
  git -C "$tree2" commit -q -m i
  pend="$ops/.claude/session/start-ticket-sa.pending"
  printf 'repo=org/p2\nnumber=20\ntitle=A2\nurl=u\nsuggested_branch=b\n' > "$pend"
  (cd "$ops" && CLAUDE_CODE_SESSION_ID=s-a \
    bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' \
    _ "$tree2" "$pend") >/dev/null 2>&1
  [ -f "$ops/.claude/session/current-ticket" ] || return 1
  cp "$ops/.claude/session/current-ticket" "$ops/ct.before"
  before=$(cksum < "$ops/ct.before")
  pend="$ops/.claude/session/start-ticket-sb.pending"
  printf 'repo=org/p2\nnumber=21\ntitle=B2\nurl=u\nsuggested_branch=b\n' > "$pend"
  out=$(cd "$ops" && env -u APEXYARD_START_TICKET_TAKEOVER CLAUDE_CODE_SESSION_ID=s-b \
    bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' \
    _ "$tree2" "$pend" 2>&1)
  rc=$?
  after=$(cksum < "$ops/.claude/session/current-ticket")
  if [ "$rc" != 0 ] && [ "$before" = "$after" ] \
    && cmp -s "$ops/ct.before" "$ops/.claude/session/current-ticket" \
    && printf '%s' "$out" | grep -q 'ticket marker not overwritten' \
    && ! printf '%s' "$out" | grep -qi 'use a separate worktree'; then
    return 0
  fi
  printf 'rc=%s before=%s after=%s out=%s\n' "$rc" "$before" "$after" "${out:0:200}"
  return 1
}

# A2: refused take-over (foreign + no flag) prints no audit line.
run_a2_refused_no_audit() {
  local ops tree cur gd pend out rc
  ops=$(tm_make_ops)
  tree="$ops/workspace/p1"
  cur=$(git -C "$tree" branch --show-current)
  gd=$(git -C "$tree" rev-parse --absolute-git-dir)
  tm_write_marker "$tree" org/p1 10 'Original' session-old "$cur"
  pend="$ops/.claude/session/start-ticket-refuse.pending"
  printf 'repo=org/p1\nnumber=99\ntitle=Takeover\nurl=u\nsuggested_branch=b\n' > "$pend"
  out=$(cd "$ops" && env -u APEXYARD_START_TICKET_TAKEOVER CLAUDE_CODE_SESSION_ID=session-new \
    bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' \
    _ "$tree" "$pend" 2>&1)
  rc=$?
  if [ "$rc" != 0 ] && grep -qx 'number=10' "$gd/apexyard-ticket" \
    && ! printf '%s' "$out" | grep -q 'ticket marker taken over'; then
    return 0
  fi
  printf 'rc=%s out=%s\n' "$rc" "${out:0:300}"
  return 1
}

# A2: take-over with flag but write refused (bad number) prints no audit line.
run_a2_failed_write_no_audit() {
  local ops tree cur gd pend out rc
  ops=$(tm_make_ops)
  tree="$ops/workspace/p1"
  cur=$(git -C "$tree" branch --show-current)
  gd=$(git -C "$tree" rev-parse --absolute-git-dir)
  tm_write_marker "$tree" org/p1 10 'Original' session-old "$cur"
  cp "$gd/apexyard-ticket" "$ops/marker.before"
  pend="$ops/.claude/session/start-ticket-badnum.pending"
  # Space in number fails the writer slug check after the foreign guard.
  printf 'repo=org/p1\nnumber=9 9\ntitle=Bad\nurl=u\nsuggested_branch=b\n' > "$pend"
  out=$(cd "$ops" && APEXYARD_START_TICKET_TAKEOVER=1 CLAUDE_CODE_SESSION_ID=session-new \
    bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' \
    _ "$tree" "$pend" 2>&1)
  rc=$?
  if [ "$rc" != 0 ] && cmp -s "$ops/marker.before" "$gd/apexyard-ticket" \
    && ! printf '%s' "$out" | grep -q 'ticket marker taken over'; then
    return 0
  fi
  printf 'rc=%s out=%s\n' "$rc" "${out:0:400}"
  return 1
}

# A2: ESC in an old field is stripped from the audit line after a real take-over.
run_a2_esc_stripped() {
  local ops tree cur gd pend out rc esc
  ops=$(tm_make_ops)
  tree="$ops/workspace/p1"
  cur=$(git -C "$tree" branch --show-current)
  gd=$(git -C "$tree" rev-parse --absolute-git-dir)
  esc=$(printf 'sess\033old')
  tm_write_marker "$tree" org/p1 10 'Original' "$esc" "$cur"
  pend="$ops/.claude/session/start-ticket-esc.pending"
  printf 'repo=org/p1\nnumber=99\ntitle=Takeover\nurl=u\nsuggested_branch=b\n' > "$pend"
  out=$(cd "$ops" && APEXYARD_START_TICKET_TAKEOVER=1 CLAUDE_CODE_SESSION_ID=session-new \
    bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' \
    _ "$tree" "$pend" 2>&1)
  rc=$?
  if [ "$rc" = 0 ] && grep -qx 'number=99' "$gd/apexyard-ticket" \
    && printf '%s' "$out" | grep -Fq 'apexyard: ticket marker taken over: org/p1#10 (session sessold) -> org/p1#99 (session session-new)' \
    && ! printf '%s' "$out" | grep -Fq "$(printf '\033')"; then
    return 0
  fi
  printf 'rc=%s out=%s\n' "$rc" "${out:0:400}"
  return 1
}

# --- fail-before against ea8d21a -------------------------------------------
FB_OPS=$(tm_make_ops)
if tm_install_hakim_before_hooks "$FB_OPS"; then
  # A4 fail-before: valid worktree cancels on shared current-ticket.
  ops="$FB_OPS"
  wt_parent=$(mktemp -d)
  wt="$wt_parent/wt"
  git -C "$ops" worktree add -q "$wt" -b wt-fb HEAD
  pend="$ops/.claude/session/start-ticket-sa.pending"
  printf 'repo=org/ops\nnumber=1\ntitle=A\nurl=u\nsuggested_branch=b\n' > "$pend"
  (cd "$ops" && CLAUDE_CODE_SESSION_ID=s-a \
    bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' \
    _ "$ops" "$pend") >/dev/null 2>&1
  pend="$ops/.claude/session/start-ticket-sb.pending"
  printf 'repo=org/ops\nnumber=2\ntitle=B\nurl=u\nsuggested_branch=b\n' > "$pend"
  out=$(cd "$ops" && env -u APEXYARD_START_TICKET_TAKEOVER CLAUDE_CODE_SESSION_ID=s-b \
    bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' \
    _ "$wt" "$pend" 2>&1)
  rc=$?
  gd=$(git -C "$wt" rev-parse --absolute-git-dir)
  if [ "$rc" != 0 ] && [ ! -f "$gd/apexyard-ticket" ] \
    && printf '%s' "$out" | grep -q 'ticket marker not overwritten'; then
    fb_ok "a4-valid-worktree-cancels-on-ea8d21a"
  else
    fb_miss "a4-valid-worktree-cancels-on-ea8d21a" "rc=$rc out=${out:0:200}"
  fi
  git -C "$ops" worktree remove -f "$wt" 2>/dev/null || true
  rm -rf "$wt_parent"

  # A2 fail-before: failed write after take-over flag still prints audit.
  ops=$(tm_make_ops)
  if tm_install_hakim_before_hooks "$ops"; then
    tree="$ops/workspace/p1"
    cur=$(git -C "$tree" branch --show-current)
    gd=$(git -C "$tree" rev-parse --absolute-git-dir)
    tm_write_marker "$tree" org/p1 10 'Original' session-old "$cur"
    pend="$ops/.claude/session/start-ticket-badnum.pending"
    printf 'repo=org/p1\nnumber=9 9\ntitle=Bad\nurl=u\nsuggested_branch=b\n' > "$pend"
    out=$(cd "$ops" && APEXYARD_START_TICKET_TAKEOVER=1 CLAUDE_CODE_SESSION_ID=session-new \
      bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' \
      _ "$tree" "$pend" 2>&1) || true
    if printf '%s' "$out" | grep -q 'ticket marker taken over'; then
      fb_ok "a2-failed-write-still-audits-on-ea8d21a"
    else
      fb_miss "a2-failed-write-still-audits-on-ea8d21a" "out=${out:0:300}"
    fi
  else
    fb_miss "a2-failed-write-still-audits-on-ea8d21a" "cannot install before hooks"
  fi
else
  echo "NOTE: skip fail-before (cannot load pre-fix hooks from ancestor)"
fi

# --- pass-after ------------------------------------------------------------
if run_a4_valid_worktree >/dev/null; then
  ok "a4-valid-worktree-starts"
else
  bad "a4-valid-worktree-starts" "valid worktree could not start its own ticket"
fi

if run_a4_invalid_tree_cancel >/dev/null; then
  ok "a4-invalid-tree-cancel-unchanged"
else
  bad "a4-invalid-tree-cancel-unchanged" "legacy cancel regressed"
fi

if run_a2_refused_no_audit >/dev/null; then
  ok "a2-refused-no-audit"
else
  bad "a2-refused-no-audit" "refused take-over printed an audit line"
fi

if run_a2_failed_write_no_audit >/dev/null; then
  ok "a2-failed-write-no-audit"
else
  bad "a2-failed-write-no-audit" "failed write still printed take-over audit"
fi

if run_a2_esc_stripped >/dev/null; then
  ok "a2-esc-stripped"
else
  bad "a2-esc-stripped" "ESC not stripped from audit line"
fi

echo "hakim PASS=$PASS FAIL=$FAIL FAIL-BEFORE ok=$FB_PASS miss=$FB_FAIL"
[ "$FAIL" = 0 ] && [ "$FB_FAIL" = 0 ]
