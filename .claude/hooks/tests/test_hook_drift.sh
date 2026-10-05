#!/bin/bash
# Tests for _lib-hook-drift.sh (me2resh/apexyard#1449).
#
# The helper is advisory, so the cases that matter most are the silent ones: a
# false "your hook is stale" note is the noise this feature exists to avoid.
#
# Case 4 is the one that killed the first design. Releases reach `main` as
# squash commits, so no `dev` commit is an ancestor of a release tag. A fork
# synced to the latest release therefore "lacks" every `dev` commit that ever
# touched a file, even when the content is byte-identical — measured at 57
# files under .claude/hooks/ against v5.7.0. Comparing blobs instead of
# ancestry is what makes that case silent.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-hook-drift.sh"
if [ ! -f "$LIB_SRC" ]; then
  echo "FAIL: lib not found at $LIB_SRC" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$LIB_SRC"

PASS=0
FAIL=0

ok()  { echo "PASS [$1]"; PASS=$((PASS+1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL+1)); }

assert_silent() {
  local label="$1" out="$2"
  if [ -z "$out" ]; then ok "$label"; else bad "$label" "expected no output, got: $out"; fi
}

assert_mentions() {
  local label="$1" out="$2" needle="$3"
  case "$out" in
    *"$needle"*) ok "$label" ;;
    *) bad "$label" "expected output mentioning '$needle', got: ${out:-<empty>}" ;;
  esac
}

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

g() { git -C "$1" "${@:2}" >/dev/null 2>&1; }
commit_in() { g "$1" add -A; g "$1" -c user.email=t@t -c user.name=t commit -m "$2"; }

# --- upstream with a dev line, and a fork cloned from it -----------------
UP="$TMP/upstream"
mkdir -p "$UP/.claude/hooks"
g "$UP" init -q
printf 'v1\n' > "$UP/.claude/hooks/sample-gate.sh"
commit_in "$UP" "add gate"
g "$UP" branch -M dev

FORK="$TMP/fork"
git clone -q "$UP" "$FORK" 2>/dev/null
g "$FORK" remote add upstream "$UP"
g "$FORK" fetch upstream

# 1. Fork is current: silent.
assert_silent "current fork is silent" "$(hook_drift_notice "$FORK/.claude/hooks/sample-gate.sh")"

# 2. Adopter customised the hook locally: silent. The fork's blob is not a
#    version upstream ever shipped, so it is customised rather than behind.
printf 'v1-local-tweak\n' > "$FORK/.claude/hooks/sample-gate.sh"
commit_in "$FORK" "local customisation"
assert_silent "local customisation is silent" "$(hook_drift_notice "$FORK/.claude/hooks/sample-gate.sh")"

# 3. Upstream changed the file and the fork carries an older shipped version:
#    the notice fires.
g "$FORK" checkout -- .
g "$FORK" reset --hard HEAD~1
printf 'v2\n' > "$UP/.claude/hooks/sample-gate.sh"
commit_in "$UP" "fix the gate"
g "$FORK" fetch upstream
out=$(hook_drift_notice "$FORK/.claude/hooks/sample-gate.sh")
assert_mentions "upstream-ahead fires"  "$out" "has changed since your version"
assert_mentions "names the file"        "$out" ".claude/hooks/sample-gate.sh"
assert_mentions "points at /update"     "$out" "/update"
if printf '%s' "$out" | grep -qE '[0-9]+ commit'; then
  bad "no commit count in the message" "message still reports a commit count: $out"
else
  ok "no commit count in the message"
fi

# 4. THE REGRESSION CASE: squash-release topology. `main` carries one squash
#    commit whose content matches the latest `dev`, but which is not a
#    descendant of the individual `dev` commits. A fork synced to that release
#    is byte-identical to upstream and must stay silent, even though every
#    `dev` commit touching the file is "missing" from its ancestry.
SQUP="$TMP/squp"
mkdir -p "$SQUP/.claude/hooks"
g "$SQUP" init -q
printf 'r1\n' > "$SQUP/.claude/hooks/sample-gate.sh"
commit_in "$SQUP" "initial"
g "$SQUP" branch -M dev
# Three dev commits move the file forward.
for v in r2 r3 r4; do
  printf '%s\n' "$v" > "$SQUP/.claude/hooks/sample-gate.sh"
  commit_in "$SQUP" "dev: $v"
done
# A release lands on `main` as a SINGLE squash commit off the root, carrying
# dev's final content but none of dev's history.
g "$SQUP" checkout -q --orphan main
printf 'r4\n' > "$SQUP/.claude/hooks/sample-gate.sh"
commit_in "$SQUP" "release: v1.0.0"
g "$SQUP" tag v1.0.0

SQFORK="$TMP/sqfork"
git clone -q --branch main "$SQUP" "$SQFORK" 2>/dev/null
g "$SQFORK" remote add upstream "$SQUP"
g "$SQFORK" fetch upstream
# Sanity: ancestry says the fork lacks every dev commit for this file...
missing=$(git -C "$SQFORK" rev-list --count HEAD..upstream/dev -- .claude/hooks/sample-gate.sh 2>/dev/null)
if [ "${missing:-0}" -gt 0 ]; then
  ok "fixture reproduces the ancestry gap (count=$missing)"
else
  bad "fixture reproduces the ancestry gap" "expected a non-zero ancestry count, got ${missing:-0}"
fi
# ...but the content is identical, so the helper must say nothing.
assert_silent "squash-release fork is silent" "$(hook_drift_notice "$SQFORK/.claude/hooks/sample-gate.sh")"

# 5. No upstream remote: silent.
SOLO="$TMP/solo"
mkdir -p "$SOLO/.claude/hooks"
g "$SOLO" init -q
printf 'v1\n' > "$SOLO/.claude/hooks/sample-gate.sh"
commit_in "$SOLO" "init"
assert_silent "no upstream remote is silent" "$(hook_drift_notice "$SOLO/.claude/hooks/sample-gate.sh")"

# 6. Not a git repo at all: silent.
mkdir -p "$TMP/plain/.claude/hooks"
printf 'v1\n' > "$TMP/plain/.claude/hooks/sample-gate.sh"
assert_silent "non-repo is silent" "$(hook_drift_notice "$TMP/plain/.claude/hooks/sample-gate.sh" 2>/dev/null)"

# 7. Empty / missing argument: silent, no error.
assert_silent "empty argument is silent" "$(hook_drift_notice "" 2>/dev/null)"
assert_silent "missing file is silent"   "$(hook_drift_notice "$FORK/.claude/hooks/nope.sh" 2>/dev/null)"

# 8. A file that exists locally but not in upstream's tree (an adopter's own
#    extra hook): silent, because there is no upstream copy to compare with.
printf 'local only\n' > "$FORK/.claude/hooks/adopter-only.sh"
commit_in "$FORK" "adopter-only hook"
assert_silent "file absent upstream is silent" "$(hook_drift_notice "$FORK/.claude/hooks/adopter-only.sh")"

# --- gate + sourced libs (Rex B-1 / motivating case) -----------------------
# A mini gate that sources `_lib-active-ticket.sh` via `$ACTIVE_TICKET_LIB`,
# the same shape `require-active-ticket.sh` uses. Lib names must come from
# the gate's source lines, not a hardcoded list.
GUP="$TMP/gateup"
mkdir -p "$GUP/.claude/hooks"
g "$GUP" init -q
cat > "$GUP/.claude/hooks/sample-gate.sh" <<'GATE'
#!/bin/bash
ACTIVE_TICKET_LIB="$(dirname "$0")/_lib-active-ticket.sh"
. "$ACTIVE_TICKET_LIB"
GATE
printf 'lib-v1\n' > "$GUP/.claude/hooks/_lib-active-ticket.sh"
printf 'gate-v1\n' >> "$GUP/.claude/hooks/sample-gate.sh"
commit_in "$GUP" "add gate+lib"
g "$GUP" branch -M main

GFORK="$TMP/gatefork"
git clone -q "$GUP" "$GFORK" 2>/dev/null
g "$GFORK" remote add upstream "$GUP"
g "$GFORK" fetch upstream

# 9. Only the sourced lib is stale: one note, names the lib (not a silent miss).
printf 'lib-v2\n' > "$GUP/.claude/hooks/_lib-active-ticket.sh"
commit_in "$GUP" "fix the lib only"
g "$GFORK" fetch upstream
out=$(hook_drift_notice_for_gate "$GFORK/.claude/hooks/sample-gate.sh")
assert_mentions "lib-only stale names the lib" "$out" ".claude/hooks/_lib-active-ticket.sh"
assert_mentions "lib-only stale says changed"  "$out" "has changed since your version"
case "$out" in
  *".claude/hooks/sample-gate.sh"*)
    bad "lib-only does not name the current gate" "gate was named though only the lib changed: $out"
    ;;
  *)
    ok "lib-only does not name the current gate"
    ;;
esac
note_count=$(printf '%s' "$out" | grep -c '^Note:' || true)
if [ "$note_count" -eq 1 ]; then
  ok "lib-only is one note"
else
  bad "lib-only is one note" "expected 1 Note: line, got $note_count"
fi

# 10. Gate and a sourced lib are both stale: one note, both files listed.
printf 'gate-v2\n' >> "$GUP/.claude/hooks/sample-gate.sh"
printf 'lib-v3\n' > "$GUP/.claude/hooks/_lib-active-ticket.sh"
commit_in "$GUP" "fix gate and lib"
g "$GFORK" fetch upstream
out=$(hook_drift_notice_for_gate "$GFORK/.claude/hooks/sample-gate.sh")
assert_mentions "both-stale names the gate" "$out" ".claude/hooks/sample-gate.sh"
assert_mentions "both-stale names the lib"  "$out" ".claude/hooks/_lib-active-ticket.sh"
note_count=$(printf '%s' "$out" | grep -c '^Note:' || true)
if [ "$note_count" -eq 1 ]; then
  ok "both-stale is one note"
else
  bad "both-stale is one note" "expected 1 Note: line, got $note_count"
fi
case "$out" in
  *"those files have changed"*) ok "both-stale uses plural wording" ;;
  *) bad "both-stale uses plural wording" "got: $out" ;;
esac

# 11. Gate and sourced lib both current: no note.
g "$GFORK" reset --hard upstream/main
assert_silent "gate+lib current is silent" "$(hook_drift_notice_for_gate "$GFORK/.claude/hooks/sample-gate.sh")"

echo
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
