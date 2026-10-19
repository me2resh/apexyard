#!/bin/bash
# Rex findings on PR #1794 / #1533: claim keyed on marker identity, unknown
# current branch must not warn, old-layout foreign overwrite must cancel.
# Fail-before runs the same probes against the pre-fix ancestor (121136b3).
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib_ticket_marker_session_branch_warn.sh"

PASS=0 FAIL=0 FB_PASS=0 FB_FAIL=0
ok() { echo "PASS [rex/$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [rex/$1]: $2" >&2; FAIL=$((FAIL + 1)); }
fb_ok() { echo "FAIL-BEFORE OK [rex/$1]"; FB_PASS=$((FB_PASS + 1)); }
fb_miss() { echo "FAIL-BEFORE MISS [rex/$1]: $2" >&2; FB_FAIL=$((FB_FAIL + 1)); }

# ---------------------------------------------------------------------------
# Finding 1 (AC1): second foreign marker at the same path must warn again.
# Probe 3: A owns #10 → B takes #11 → A edits (warn) → A takes #10 → B takes
# #12 → A edits (must warn). Pre-fix claim is path-only, so step 4 is silent.
# ---------------------------------------------------------------------------
run_finding1() {
  local ops tree pend out w
  ops=$(tm_make_ops)
  tree="$ops/workspace/p1"
  take() {
    pend="$ops/.claude/session/start-ticket-$1.pending"
    printf 'repo=org/p1\nnumber=%s\ntitle=t\nurl=u\nsuggested_branch=b\n' "$2" > "$pend"
    (cd "$ops" && APEXYARD_START_TICKET_TAKEOVER=1 CLAUDE_CODE_SESSION_ID="$1" \
      bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' \
      _ "$tree" "$pend") >/dev/null 2>&1
  }
  take s-a 10
  take s-b 11
  out=$(tm_run_gate "$ops" "$tree/src/app.ts" s-a)
  w=$(printf '%s' "$out" | grep -c 'WARN: ticket marker' || true)
  [ "$w" = 1 ] || { printf 'step2_warn=%s\n' "$w"; return 1; }
  take s-a 10
  take s-b 12
  out=$(tm_run_gate "$ops" "$tree/src/app.ts" s-a)
  w=$(printf '%s' "$out" | grep -c 'WARN: ticket marker' || true)
  printf '%s\n' "$w"
  [ "$w" = 1 ]
}

# ---------------------------------------------------------------------------
# Finding 2: unknown current branch must not report "another branch".
# Matching marker + migration path under a not-yet-existing directory.
# ---------------------------------------------------------------------------
run_finding2_migration_match_silent() {
  local ops tree cur out w mig
  ops=$(tm_make_ops)
  tree="$ops/workspace/p1"
  cur=$(git -C "$tree" branch --show-current)
  tm_write_marker "$tree" org/p1 42 'T' s-me "$cur"
  mkdir -p "$tree/migrations"
  # Path only — do not create migrations/2026_x (dirname does not exist).
  mig="$tree/migrations/2026_x/migration.sql"
  out=$(tm_run_migration_gate "$ops" "$mig" s-me)
  w=$(printf '%s' "$out" | grep -c 'WARN: ticket marker' || true)
  printf '%s\n' "$w"
  [ "$w" = 0 ]
}

# Legacy-only tree: matching session + branch, AT_TREE empty → no branch warn.
run_finding2_legacy_match_silent() {
  local ops tree2 cur out w
  ops=$(tm_make_ops)
  tree2="$ops/workspace/p2"
  mkdir -p "$tree2/src"
  git init -q "$tree2"
  git -C "$tree2" config user.email t@e
  git -C "$tree2" config user.name t
  printf 'x\n' > "$tree2/src/a.ts"
  git -C "$tree2" add src/a.ts
  git -C "$tree2" commit -q -m i
  cur=$(git -C "$tree2" branch --show-current)
  pend="$ops/.claude/session/start-ticket-s-a.pending"
  printf 'repo=org/p2\nnumber=20\ntitle=A2\nurl=u\nsuggested_branch=b\n' > "$pend"
  (cd "$ops" && CLAUDE_CODE_SESSION_ID=s-a \
    bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' \
    _ "$tree2" "$pend") >/dev/null 2>&1
  out=$(tm_run_gate "$ops" "$tree2/src/a.ts" s-a)
  w=$(printf '%s' "$out" | grep -c 'belongs to another' || true)
  printf '%s\n' "$w"
  [ "$w" = 0 ]
}

# ---------------------------------------------------------------------------
# Finding 3 (AC3): headless foreign overwrite of old-layout current-ticket
# must cancel and leave the file byte-for-byte unchanged.
# ---------------------------------------------------------------------------
run_finding3() {
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
  pend="$ops/.claude/session/start-ticket-s-a.pending"
  printf 'repo=org/p2\nnumber=20\ntitle=A2\nurl=u\nsuggested_branch=b\n' > "$pend"
  (cd "$ops" && CLAUDE_CODE_SESSION_ID=s-a \
    bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' \
    _ "$tree2" "$pend") >/dev/null 2>&1
  [ -f "$ops/.claude/session/current-ticket" ] || return 1
  cp "$ops/.claude/session/current-ticket" "$ops/ct.before"
  before=$(cksum < "$ops/ct.before")
  pend="$ops/.claude/session/start-ticket-s-b.pending"
  printf 'repo=org/p2\nnumber=21\ntitle=B2\nurl=u\nsuggested_branch=b\n' > "$pend"
  out=$(cd "$ops" && env -u APEXYARD_START_TICKET_TAKEOVER CLAUDE_CODE_SESSION_ID=s-b \
    bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' \
    _ "$tree2" "$pend" 2>&1)
  rc=$?
  after=$(cksum < "$ops/.claude/session/current-ticket")
  if [ "$rc" != 0 ] && [ "$before" = "$after" ] \
    && cmp -s "$ops/ct.before" "$ops/.claude/session/current-ticket" \
    && printf '%s' "$out" | grep -q 'ticket marker not overwritten'; then
    printf 'ok\n'
    return 0
  fi
  printf 'rc=%s before=%s after=%s out=%s\n' "$rc" "$before" "$after" "${out:0:200}"
  return 1
}

# ---------------------------------------------------------------------------
# Migration-gate warning: foreign session on an existing migration path warns.
# ---------------------------------------------------------------------------
run_migration_foreign_warn() {
  local ops tree cur out w mig
  ops=$(tm_make_ops)
  tree="$ops/workspace/p1"
  cur=$(git -C "$tree" branch --show-current)
  tm_write_marker "$tree" org/p1 42 'T' s-other other-branch
  mkdir -p "$tree/migrations"
  # Literal relative name under the tree; printf writes the fixture file.
  printf 'x\n' > "$tree/migrations/001.sql"
  mig="$tree/migrations/001.sql"
  out=$(tm_run_migration_gate "$ops" "$mig" s-me)
  w=$(printf '%s' "$out" | grep -c 'WARN: ticket marker' || true)
  printf '%s\n' "$w"
  [ "$w" = 1 ]
}

# --- fail-before against pre-fix ancestor (121136b3 / APEXYARD_REX_BEFORE_*) -
# Run in the current shell so FAIL-BEFORE counters stick.
FB_OPS=$(tm_make_ops)
if tm_install_rex_before_hooks "$FB_OPS"; then
  # Finding 1: second foreign takeover is silent (path-only claim).
  ops="$FB_OPS"
  tree="$ops/workspace/p1"
  take() {
    pend="$ops/.claude/session/start-ticket-$1.pending"
    printf 'repo=org/p1\nnumber=%s\ntitle=t\nurl=u\nsuggested_branch=b\n' "$2" > "$pend"
    (cd "$ops" && APEXYARD_START_TICKET_TAKEOVER=1 CLAUDE_CODE_SESSION_ID="$1" \
      bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' \
      _ "$tree" "$pend") >/dev/null 2>&1
  }
  take s-a 10
  take s-b 11
  out=$(tm_run_gate "$ops" "$tree/src/app.ts" s-a)
  take s-a 10
  take s-b 12
  out=$(tm_run_gate "$ops" "$tree/src/app.ts" s-a)
  w=$(printf '%s' "$out" | grep -c 'WARN: ticket marker' || true)
  if [ "$w" = 0 ]; then
    fb_ok "finding1-second-foreign-silent-on-121136b"
  else
    fb_miss "finding1-second-foreign-silent-on-121136b" "expected silent second warn, got w=$w"
  fi
  unset -f take

  # Finding 2: matching marker + new migration dir warns branch.
  ops=$(tm_make_ops)
  if tm_install_rex_before_hooks "$ops"; then
    tree="$ops/workspace/p1"
    cur=$(git -C "$tree" branch --show-current)
    tm_write_marker "$tree" org/p1 42 'T' s-me "$cur"
    mkdir -p "$tree/migrations"
    mig="$tree/migrations/2026_x/migration.sql"
    out=$(tm_run_migration_gate "$ops" "$mig" s-me)
    if printf '%s' "$out" | grep -q 'belongs to another'; then
      fb_ok "finding2-unknown-branch-false-warn-on-121136b"
    else
      fb_miss "finding2-unknown-branch-false-warn-on-121136b" "expected false branch warn, out=${out:0:200}"
    fi
  else
    fb_miss "finding2-unknown-branch-false-warn-on-121136b" "cannot install before hooks"
  fi

  # Finding 3: old-layout current-ticket is overwritten headless.
  ops=$(tm_make_ops)
  if tm_install_rex_before_hooks "$ops"; then
    tree2="$ops/workspace/p2"
    mkdir -p "$tree2/src"
    git init -q "$tree2"
    git -C "$tree2" config user.email t@e
    git -C "$tree2" config user.name t
    printf 'x\n' > "$tree2/src/a.ts"
    git -C "$tree2" add src/a.ts
    git -C "$tree2" commit -q -m i
    pend="$ops/.claude/session/start-ticket-s-a.pending"
    printf 'repo=org/p2\nnumber=20\ntitle=A2\nurl=u\nsuggested_branch=b\n' > "$pend"
    (cd "$ops" && CLAUDE_CODE_SESSION_ID=s-a \
      bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' \
      _ "$tree2" "$pend") >/dev/null 2>&1
    cp "$ops/.claude/session/current-ticket" "$ops/ct.before"
    before=$(cksum < "$ops/ct.before")
    pend="$ops/.claude/session/start-ticket-s-b.pending"
    printf 'repo=org/p2\nnumber=21\ntitle=B2\nurl=u\nsuggested_branch=b\n' > "$pend"
    (cd "$ops" && env -u APEXYARD_START_TICKET_TAKEOVER CLAUDE_CODE_SESSION_ID=s-b \
      bash -c '. .claude/hooks/_lib-active-ticket.sh && active_ticket_write_from_file "$1" "$2"' \
      _ "$tree2" "$pend") >/dev/null 2>&1 || true
    after=$(cksum < "$ops/.claude/session/current-ticket")
    if [ "$before" != "$after" ]; then
      fb_ok "finding3-legacy-overwrite-on-121136b"
    else
      fb_miss "finding3-legacy-overwrite-on-121136b" "marker unchanged on pre-fix lib"
    fi
  else
    fb_miss "finding3-legacy-overwrite-on-121136b" "cannot install before hooks"
  fi
else
  echo "NOTE: skip fail-before (cannot load pre-fix hooks from ancestor)"
fi

# --- pass-after (current hooks) --------------------------------------------
if run_finding1 >/dev/null; then
  ok "finding1-second-foreign-warns"
else
  bad "finding1-second-foreign-warns" "second foreign marker produced no warning"
fi

if run_finding2_migration_match_silent >/dev/null; then
  ok "finding2-migration-new-dir-silent"
else
  bad "finding2-migration-new-dir-silent" "matching marker warned on unknown branch"
fi

if run_finding2_legacy_match_silent >/dev/null; then
  ok "finding2-legacy-match-silent"
else
  bad "finding2-legacy-match-silent" "matching legacy marker warned on empty AT_TREE"
fi

if run_finding3 >/dev/null; then
  ok "finding3-legacy-headless-cancel"
else
  bad "finding3-legacy-headless-cancel" "old-layout marker was overwritten"
fi

if run_migration_foreign_warn >/dev/null; then
  ok "migration-gate-foreign-warn"
else
  bad "migration-gate-foreign-warn" "foreign marker produced no migration-gate warning"
fi

echo "rex PASS=$PASS FAIL=$FAIL FAIL-BEFORE ok=$FB_PASS miss=$FB_FAIL"
[ "$FAIL" = 0 ] && [ "$FB_FAIL" = 0 ]
