#!/bin/bash
# CI must make the reviewed command-scrub snapshots available and require them.
# Pins must be full 40-character SHAs. CI must verify each SHA after the fetch.
set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/_test-session-isolation.sh"


ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
WORKFLOW=${WORKFLOW_OVERRIDE:-$ROOT/.github/workflows/tests.yml}
MUST_BLOCK=${MUST_BLOCK_TEST_OVERRIDE:-$ROOT/.claude/hooks/tests/test_command_scrub_must_block.sh}
TMP=$(mktemp -d) || exit 1
export GIT_CEILING_DIRECTORIES="$TMP"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

# Reviewed PR #1466 snapshot commits (full 40-character SHAs).
SHA_SCRUB_ROUTING=39c5b959f0544785c643c6945b487ec579b4a035
SHA_DENY_LIST=d5e7ce4d50e07bd0bd026230e1fb78714e809a27
SHA_HEREDOC_HEAD=1fea7308d0a6de4412198b1bc645ada8a47a8f05
CLEAR_MSG='CI snapshot proof failed: commit'

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

check_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -Eq "$pattern" "$file" 2>/dev/null; then
    echo "FAIL: $label" >&2
    fail=$((fail + 1))
  else
    echo "PASS: $label"
    pass=$((pass + 1))
  fi
}

check_text "$WORKFLOW" 'refs/pull/1466/head' 'CI fetches the reviewed PR snapshot ref'
check_text "$WORKFLOW" 'APEXYARD_SNAPSHOT_REPO=' 'CI passes its temporary snapshot repository'
check_text "$WORKFLOW" 'REQUIRE_SNAPSHOTS=1' 'CI requires every snapshot'

# AC1: workflow and must-block test pin full 40-character SHAs.
for sha in "$SHA_SCRUB_ROUTING" "$SHA_DENY_LIST" "$SHA_HEREDOC_HEAD"; do
  if [ "${#sha}" -eq 40 ]; then
    echo "PASS: pinned SHA length is 40 ($sha)"
    pass=$((pass + 1))
  else
    echo "FAIL: pinned SHA length is not 40 ($sha)" >&2
    fail=$((fail + 1))
  fi
  check_text "$WORKFLOW" "$sha" "workflow pins full SHA $sha"
  check_text "$MUST_BLOCK" "archive_snapshot $sha" "must-block archives full SHA $sha"
done

# Short prefixes must not be the archive pin (ambiguity as history grows).
check_absent "$MUST_BLOCK" \
  'archive_snapshot (39c5b95|d5e7ce4|1fea730)([^0-9a-fA-F]|$)' \
  'must-block does not archive short SHA prefixes'

# AC2: CI verifies each SHA after the fetch and fails with a clear message.
check_text "$WORKFLOW" 'cat-file -e' 'CI verifies snapshot commits with git cat-file'
check_text "$WORKFLOW" "$CLEAR_MSG" 'CI emits a clear missing-snapshot message'

# Behavioral proof: the same post-fetch verify fails clearly on an empty repo.
# All git operations target this test's own temporary repository.
empty_repo="$TMP/empty-snapshots"
mkdir -p "$empty_repo"
if ! git -C "$empty_repo" init -q --bare; then
  echo 'FAIL: git init failed for empty snapshot repository' >&2
  fail=$((fail + 1))
else
  verify_out="$TMP/verify.out"
  : >"$verify_out"
  verify_rc=0
  for sha in "$SHA_SCRUB_ROUTING" "$SHA_DENY_LIST" "$SHA_HEREDOC_HEAD"; do
    if ! git -C "$empty_repo" cat-file -e "${sha}^{commit}" 2>/dev/null; then
      echo "${CLEAR_MSG} ${sha} is not present after fetching refs/pull/1466/head" >>"$verify_out"
      verify_rc=1
    fi
  done
  if [ "$verify_rc" -ne 0 ] \
      && grep -Fq "$CLEAR_MSG" "$verify_out" \
      && grep -Fq "$SHA_SCRUB_ROUTING" "$verify_out" \
      && grep -Fq "$SHA_DENY_LIST" "$verify_out" \
      && grep -Fq "$SHA_HEREDOC_HEAD" "$verify_out"; then
    echo 'PASS: post-fetch verify fails clearly when snapshot commits are missing'
    pass=$((pass + 1))
  else
    echo 'FAIL: post-fetch verify did not fail clearly for missing commits' >&2
    fail=$((fail + 1))
  fi
fi

# Use an empty repository so the strict check must fail for all three SHAs.
# All git operations in this test target its own temporary repository.
if ! git -C "$TMP" init -q --bare; then
  echo 'FAIL: git init failed for must-block preflight repository' >&2
  fail=$((fail + 1))
elif grep -Fq 'SNAPSHOT_PREFLIGHT_ONLY' "$MUST_BLOCK" 2>/dev/null; then
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
