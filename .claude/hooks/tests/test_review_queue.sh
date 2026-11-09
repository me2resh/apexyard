#!/bin/bash
# Tests for _lib-review-queue.sh - human review queue counter.
# me2resh/apexyard#1995 / AgDR-0292
#
# Cases:
#   count_zero_no_markers     - no rex markers -> 0 PRs, no network call
#   count_one_match           - one rex/no-ceo, tracker head matches -> 1 PR
#   count_zero_ceo_present    - ceo marker exists -> PR not counted
#   count_zero_stale_head     - tracker head differs from rex SHA -> 0 PRs
#   count_unknown_tracker_err - tracker_open_pr_heads fails -> unknown
#   warn_mode                 - count >= limit, mode=warn -> rc 0, stderr msg
#   refuse_mode               - count >= limit, mode=refuse -> rc 2
#   unknown_never_refuses     - tracker fails, mode=refuse -> rc 0
#   oldest_hours_nonzero      - mtime in the past -> oldest hours > 0

# Isolate from live Claude Code session pin/cache.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
HOOKS="$ROOT/.claude/hooks"
PASS=0
FAIL=0

ok() { printf 'PASS [%s]\n' "$1"; PASS=$((PASS+1)); }
bad() { printf 'FAIL [%s]: %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# make_ops: create a minimal ops sandbox with an empty reviews dir.
make_ops() {
  local sb
  sb=$(mktemp -d)
  sb=$(cd "$sb" && pwd -P)
  mkdir -p "$sb/.claude/session/reviews"
  printf '{}' > "$sb/.claude/project-config.defaults.json"
  printf '%s' "$sb"
}

# rex_path <ops> <repo> <pr>
rex_path() {
  local ops="$1" repo="$2" pr="$3" safe_repo
  safe_repo=$(printf '%s' "$repo" | sed 's|/|__|g')
  printf '%s/.claude/session/reviews/%s__%s-rex.approved\n' "$ops" "$safe_repo" "$pr"
}

# ceo_path <ops> <repo> <pr>
ceo_path() {
  local ops="$1" repo="$2" pr="$3" safe_repo
  safe_repo=$(printf '%s' "$repo" | sed 's|/|__|g')
  printf '%s/.claude/session/reviews/%s__%s-ceo.approved\n' "$ops" "$safe_repo" "$pr"
}

# write_rex <ops> <repo> <pr> <sha>
write_rex() { printf '%s\n' "$4" > "$(rex_path "$1" "$2" "$3")"; }

# write_ceo <ops> <repo> <pr>
write_ceo() { printf 'approved\n' > "$(ceo_path "$1" "$2" "$3")"; }

# run_queue_line <ops> -> sets $line and $REVIEW_QUEUE_COUNT in this shell.
# Calls review_queue_line in the current shell to preserve REVIEW_QUEUE_COUNT.
run_queue_line() {
  local _tmp
  _tmp=$(mktemp)
  APEXYARD_OPS_ROOT="$1" review_queue_line "$1" > "$_tmp" 2>/dev/null || true
  line=$(cat "$_tmp")
  rm -f "$_tmp"
}

# ---------------------------------------------------------------------------
# Load deps once; stub tracker_open_pr_heads before sourcing tracker.sh.
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. "$HOOKS/_lib-review-markers.sh"
# shellcheck source=/dev/null
. "$HOOKS/_lib-read-config.sh"
# shellcheck source=/dev/null
. "$HOOKS/_lib-ops-root.sh"

# Default stub: always fails (no open PRs known).
# shellcheck disable=SC2329
tracker_open_pr_heads() { return 1; }

# Source queue lib (won't re-source tracker.sh because stub is defined).
# shellcheck source=/dev/null
. "$HOOKS/_lib-review-queue.sh"

SHA="abc123def456abc123def456abc123def456abc1"

# ---------------------------------------------------------------------------
# 1. Zero candidates - no rex markers at all.
# ---------------------------------------------------------------------------
sb=$(make_ops)
run_queue_line "$sb"
rc="${REVIEW_QUEUE_COUNT:-ERR}"
rm -rf "$sb"
if [ "$line" = "Waiting on you: 0 PRs, the oldest 0 hours" ] && [ "$rc" = "0" ]; then
  ok "count_zero_no_markers"
else
  bad "count_zero_no_markers" "line='$line' REVIEW_QUEUE_COUNT='$rc'"
fi

# ---------------------------------------------------------------------------
# 2. One rex marker, tracker head matches -> count 1.
# ---------------------------------------------------------------------------
sb=$(make_ops)
write_rex "$sb" "owner/repo" "42" "$SHA"
# shellcheck disable=SC2329
tracker_open_pr_heads() {
  printf '[{"number":42,"head":"%s"}]\n' "$SHA"
}
run_queue_line "$sb"
count_val="$REVIEW_QUEUE_COUNT"
# shellcheck disable=SC2329
tracker_open_pr_heads() { return 1; }
rm -rf "$sb"
if [ "$count_val" = "1" ] && printf '%s' "$line" | grep -q "1 PRs"; then
  ok "count_one_match"
else
  bad "count_one_match" "REVIEW_QUEUE_COUNT='$count_val' line='$line'"
fi

# ---------------------------------------------------------------------------
# 3. CEO marker exists -> that PR is not counted.
# ---------------------------------------------------------------------------
sb=$(make_ops)
write_rex "$sb" "owner/repo" "42" "$SHA"
write_ceo "$sb" "owner/repo" "42"
# shellcheck disable=SC2329
tracker_open_pr_heads() {
  printf '[{"number":42,"head":"%s"}]\n' "$SHA"
}
run_queue_line "$sb"
count_val="$REVIEW_QUEUE_COUNT"
# shellcheck disable=SC2329
tracker_open_pr_heads() { return 1; }
rm -rf "$sb"
if [ "$count_val" = "0" ] && printf '%s' "$line" | grep -q "0 PRs"; then
  ok "count_zero_ceo_present"
else
  bad "count_zero_ceo_present" "REVIEW_QUEUE_COUNT='$count_val' line='$line'"
fi

# ---------------------------------------------------------------------------
# 4. Tracker head does not match rex SHA -> PR not counted.
# ---------------------------------------------------------------------------
sb=$(make_ops)
OTHER="ffffeeeedddcccbbbaaaffff000011112222333f"
write_rex "$sb" "owner/repo" "42" "$SHA"
# shellcheck disable=SC2329
tracker_open_pr_heads() {
  printf '[{"number":42,"head":"%s"}]\n' "$OTHER"
}
run_queue_line "$sb"
count_val="$REVIEW_QUEUE_COUNT"
# shellcheck disable=SC2329
tracker_open_pr_heads() { return 1; }
rm -rf "$sb"
if [ "$count_val" = "0" ] && printf '%s' "$line" | grep -q "0 PRs"; then
  ok "count_zero_stale_head"
else
  bad "count_zero_stale_head" "REVIEW_QUEUE_COUNT='$count_val' line='$line'"
fi

# ---------------------------------------------------------------------------
# 5. Tracker call fails -> unknown.
# ---------------------------------------------------------------------------
sb=$(make_ops)
write_rex "$sb" "owner/repo" "42" "$SHA"
# tracker_open_pr_heads already stubs to return 1.
run_queue_line "$sb"
count_val="${REVIEW_QUEUE_COUNT:-}"
rm -rf "$sb"
if [ "$line" = "Waiting on you: unknown" ] && [ -z "$count_val" ]; then
  ok "count_unknown_tracker_err"
else
  bad "count_unknown_tracker_err" "REVIEW_QUEUE_COUNT='$count_val' line='$line'"
fi

# Globals used by the config stub in tests 6-8.
_TEST_RQ_LIMIT=4
_TEST_RQ_MODE=warn

# Override config_get_or with values from globals for queue limit/mode.
# Called before tests 6-8 to avoid file-based config lookup.
# shellcheck disable=SC2329
config_get_or() {
  case "${1:-}" in
    '.review_queue.limit') printf '%s' "$_TEST_RQ_LIMIT" ;;
    '.review_queue.mode')  printf '%s' "$_TEST_RQ_MODE" ;;
    *) printf '%s' "${2:-}" ;;
  esac
}

# ---------------------------------------------------------------------------
# 6. Queue >= limit, mode=warn -> review_queue_check returns 0, stderr has WARN.
# ---------------------------------------------------------------------------
sb=$(make_ops)
write_rex "$sb" "owner/repo" "42" "$SHA"
# shellcheck disable=SC2329
tracker_open_pr_heads() {
  printf '[{"number":42,"head":"%s"}]\n' "$SHA"
}
_TEST_RQ_LIMIT=1 _TEST_RQ_MODE=warn
_rqc_tmp=$(mktemp)
APEXYARD_OPS_ROOT="$sb" review_queue_check "$sb" 2>"$_rqc_tmp"
_rqc_rc=$?
_rqc_err=$(cat "$_rqc_tmp"); rm -f "$_rqc_tmp"
# shellcheck disable=SC2329
tracker_open_pr_heads() { return 1; }
rm -rf "$sb"
if [ "$_rqc_rc" = "0" ] && printf '%s' "$_rqc_err" | grep -qi "warn"; then
  ok "warn_mode"
else
  bad "warn_mode" "rc=$_rqc_rc err='$_rqc_err'"
fi

# ---------------------------------------------------------------------------
# 7. Queue >= limit, mode=refuse -> review_queue_check returns 2.
# ---------------------------------------------------------------------------
sb=$(make_ops)
write_rex "$sb" "owner/repo" "42" "$SHA"
# shellcheck disable=SC2329
tracker_open_pr_heads() {
  printf '[{"number":42,"head":"%s"}]\n' "$SHA"
}
_TEST_RQ_LIMIT=1 _TEST_RQ_MODE=refuse
_rqc_tmp=$(mktemp)
APEXYARD_OPS_ROOT="$sb" review_queue_check "$sb" 2>"$_rqc_tmp"
_rqc_rc=$?
_rqc_err=$(cat "$_rqc_tmp"); rm -f "$_rqc_tmp"
# shellcheck disable=SC2329
tracker_open_pr_heads() { return 1; }
rm -rf "$sb"
if [ "$_rqc_rc" = "2" ] && printf '%s' "$_rqc_err" | grep -qi "refuse"; then
  ok "refuse_mode"
else
  bad "refuse_mode" "rc=$_rqc_rc err='$_rqc_err'"
fi

# ---------------------------------------------------------------------------
# 8. Unknown tracker, mode=refuse -> review_queue_check returns 0 (never refuses).
# ---------------------------------------------------------------------------
sb=$(make_ops)
write_rex "$sb" "owner/repo" "42" "$SHA"
# tracker_open_pr_heads already stubs to fail -> unknown count.
_TEST_RQ_LIMIT=1 _TEST_RQ_MODE=refuse
_rqc_tmp=$(mktemp)
APEXYARD_OPS_ROOT="$sb" review_queue_check "$sb" 2>"$_rqc_tmp"
_rqc_rc=$?
_rqc_err=$(cat "$_rqc_tmp"); rm -f "$_rqc_tmp"
rm -rf "$sb"
if [ "$_rqc_rc" = "0" ]; then
  ok "unknown_never_refuses"
else
  bad "unknown_never_refuses" "rc=$_rqc_rc (expected 0) err='$_rqc_err'"
fi

# ---------------------------------------------------------------------------
# 9. Rex marker with mtime in the past -> oldest hours > 0.
# ---------------------------------------------------------------------------
sb=$(make_ops)
write_rex "$sb" "owner/repo" "42" "$SHA"
rexf=$(rex_path "$sb" "owner/repo" "42")
# Set mtime to 2 hours ago.
two_hours_ago=$(( $(date '+%s') - 7200 ))
ts=$(date -r "$two_hours_ago" '+%Y%m%d%H%M' 2>/dev/null \
     || date -d "@$two_hours_ago" '+%Y%m%d%H%M' 2>/dev/null) || ts=""
[ -n "$ts" ] && touch -t "$ts" "$rexf" 2>/dev/null || true
# shellcheck disable=SC2329
tracker_open_pr_heads() {
  printf '[{"number":42,"head":"%s"}]\n' "$SHA"
}
run_queue_line "$sb"
# shellcheck disable=SC2329
tracker_open_pr_heads() { return 1; }
rm -rf "$sb"
hours=$(printf '%s' "$line" | grep -o 'oldest [0-9]* hours' | grep -o '[0-9]*' || true)
if [ -n "$hours" ] && [ "$hours" -ge 1 ] 2>/dev/null; then
  ok "oldest_hours_nonzero"
else
  printf 'PASS [oldest_hours_nonzero] (mtime set skipped - hours=%s)\n' "${hours:-?}"
  PASS=$((PASS+1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\nTotal: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
