#!/usr/bin/env bash
# Local regression coverage for GH-1708.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT="${APEXYARD_TEST_SRC_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
LIB="$ROOT/.claude/skills/scaffold/lib"
FIX="$ROOT/.claude/hooks/tests/fixtures/scaffold"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
check() {
  local name=$1
  shift
  if "$@"; then printf '  PASS: %s\n' "$name"; PASS=$((PASS+1));
  else printf '  FAIL: %s\n' "$name" >&2; FAIL=$((FAIL+1)); fi
}
ids() { bash "$LIB/next-questions.sh" "$@"; }
count_is() { local expected=$1; shift; [ "$(ids "$@" | wc -l | tr -d ' ')" = "$expected" ]; }
exit_is() { local expected=$1; shift; "$@" >"$TMP/output" 2>&1; [ "$?" -eq "$expected" ]; }
skips() { local id=$1; shift; local out; out=$(ids "$@") || return 1; ! printf '%s\n' "$out" | grep -qx "$id"; }
demo_exact() { [ "$(ids --scale demo)" = "$(printf 'q02\nq03\nq04\nq05')" ]; }
check 'demo exact order and four IDs' demo_exact
check 'small nine IDs' count_is 9 --scale small
check 'production web fourteen IDs' count_is 14 --scale production --shape 'web app'
check 'production non-web thirteen IDs' count_is 13 --scale production --shape 'API service'
check 'spec answer skipped' skips q04 --scale small --spec "$FIX/good.json"
check 'onboarding language skipped' skips q05 --scale demo --onboarding "$FIX/onboarding.fixture.yaml"
check 'PRD auth skipped' skips q06 --scale small --prd-answers "$FIX/prd.json"
check 'PRD data skipped' skips q07 --scale small --prd-answers "$FIX/prd.json"
check 'bad scale usage' exit_is 2 ids --scale huge
check 'missing option value' exit_is 2 ids --scale
check 'missing file' exit_is 2 ids --scale demo --spec "$TMP/missing"
check 'valid spec' exit_is 0 bash "$LIB/validate-spec.sh" "$FIX/good.json"
for mutation in reason source scale extra date calendar; do
  case "$mutation" in
    reason) filter='del(.answers.design.reason)' ;;
    source) filter='.answers.design.source="guess"' ;;
    scale) filter='.scale="huge"' ;;
    extra) filter='.extra=true' ;;
    date) filter='.createdAt="yesterday"' ;;
    calendar) filter='.createdAt="2026-02-30T12:00:00Z"' ;;

  esac
  jq "$filter" "$FIX/good.json" > "$TMP/bad.json"
  check "reject $mutation" exit_is 1 bash "$LIB/validate-spec.sh" "$TMP/bad.json"
done
check 'validator usage' exit_is 2 bash "$LIB/validate-spec.sh"
check 'bank reasons, options, tiers, and IDs' jq -e '
  length == 15 and
  ([.[].id] | unique | length) == 15 and
  all(.[]; (.reason | split(" ") | length) <= 25 and
    (.reason | length) > 0 and
    (.recommended as $r | .options | index($r)) != null and
    (.options | length) >= 2 and (.options | length) <= 4) and
  ([.[] | select(.tier == "demo")] | length) == 5 and
  ([.[] | select(.tier == "small")] | length) == 5 and
  ([.[] | select(.tier == "production")] | length) == 5
' "$ROOT/.claude/skills/scaffold/questions.json"
printf '%s passed; %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
