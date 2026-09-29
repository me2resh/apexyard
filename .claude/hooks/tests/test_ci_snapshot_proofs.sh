#!/bin/bash
# CI must make the reviewed command-scrub snapshots available and require them.
set -u

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
WORKFLOW=${WORKFLOW_OVERRIDE:-$ROOT/.github/workflows/tests.yml}
MUST_BLOCK=${MUST_BLOCK_TEST_OVERRIDE:-$ROOT/.claude/hooks/tests/test_command_scrub_must_block.sh}
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

check_text() {
  local file="$1" pattern="$2" label="$3"
  if grep -Fq "$pattern" "$file" 2>/dev/null; then
    echo "PASS: $label"
    pass=$((pass + 1))
  else
    echo "FAIL: $label" >&2
    fail=$((fail + 1))
  fi
}

check_text "$WORKFLOW" 'refs/pull/1466/head' 'CI fetches the reviewed PR snapshot ref'
check_text "$WORKFLOW" 'APEXYARD_SNAPSHOT_REPO=' 'CI passes its temporary snapshot repository'
check_text "$WORKFLOW" 'REQUIRE_SNAPSHOTS=1' 'CI requires every snapshot'
for sha in 39c5b95 d5e7ce4 1fea730; do
  check_text "$MUST_BLOCK" "archive_snapshot $sha" "$sha is archived for fail-before proofs"
done

# Use an empty repository so the strict check must fail for all three SHAs.
# All git operations in this test target its own temporary repository.
git -C "$TMP" init -q --bare
if grep -Fq 'SNAPSHOT_PREFLIGHT_ONLY' "$MUST_BLOCK" 2>/dev/null; then
  if APEXYARD_SNAPSHOT_REPO="$TMP" REQUIRE_SNAPSHOTS=1 \
      SNAPSHOT_PREFLIGHT_ONLY=1 /bin/bash "$MUST_BLOCK" \
      >"$TMP/preflight.out" 2>&1; then
    echo 'FAIL: strict preflight accepted missing snapshots' >&2
    fail=$((fail + 1))
  elif grep -Fq 'Snapshot preflight: 3 failed' "$TMP/preflight.out"; then
    echo 'PASS: strict preflight rejects all missing snapshots'
    pass=$((pass + 1))
  else
    echo 'FAIL: strict preflight did not report all three missing snapshots' >&2
    fail=$((fail + 1))
  fi
else
  echo 'FAIL: strict snapshot preflight is unavailable' >&2
  fail=$((fail + 1))
fi

printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
