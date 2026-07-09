#!/usr/bin/env bash
# test-snapshot-diff.sh — smoke tests for the /eval-agents contamination
# backstop (snapshot-diff.sh, #833).
# Run: .claude/skills/eval-agents/tests/test-snapshot-diff.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_DIFF="$SCRIPT_DIR/../lib/snapshot-diff.sh"

pass=0
fail=0

check() {
  local desc="$1" expect_rc="$2"; shift 2
  "$@" >/tmp/snapshot-diff-test.out 2>&1
  local rc=$?
  if [ "$rc" -eq "$expect_rc" ]; then
    echo "✓ $desc"
    pass=$((pass + 1))
  else
    echo "✗ $desc (expected exit $expect_rc, got $rc)"
    cat /tmp/snapshot-diff-test.out
    fail=$((fail + 1))
  fi
}

check_output_contains() {
  local desc="$1" needle="$2"
  if grep -qF "$needle" /tmp/snapshot-diff-test.out; then
    echo "✓ $desc"
    pass=$((pass + 1))
  else
    echo "✗ $desc (output did not contain: $needle)"
    cat /tmp/snapshot-diff-test.out
    fail=$((fail + 1))
  fi
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

TARGET="$WORKDIR/reviews"
SNAP="$WORKDIR/snap.manifest"

mkdir -p "$TARGET"
echo "existing content" > "$TARGET/keep.txt"

# 1. check with no prior snapshot is a usage error, not a false negative.
check "check without a prior snapshot fails cleanly" 2 bash "$SNAPSHOT_DIFF" check "$TARGET" "$SNAP"

# 2. snapshot succeeds and check right after reports no contamination.
check "snapshot succeeds" 0 bash "$SNAPSHOT_DIFF" snapshot "$TARGET" "$SNAP"
check "check immediately after snapshot is clean" 0 bash "$SNAPSHOT_DIFF" check "$TARGET" "$SNAP"

# 3. a new file (simulating a silent marker write) is flagged NEW.
echo "contamination" > "$TARGET/pr-99-rex.approved"
check "new file is flagged as contamination" 1 bash "$SNAPSHOT_DIFF" check "$TARGET" "$SNAP"
check_output_contains "new-file report names the path" "NEW:     pr-99-rex.approved"
rm -f "$TARGET/pr-99-rex.approved"

# 4. back to clean after the extra file is removed (re-snapshot first).
check "re-snapshot after cleanup" 0 bash "$SNAPSHOT_DIFF" snapshot "$TARGET" "$SNAP"
check "check is clean again" 0 bash "$SNAPSHOT_DIFF" check "$TARGET" "$SNAP"

# 5. a changed file (same path, different content) is flagged CHANGED, not NEW.
echo "mutated content" > "$TARGET/keep.txt"
check "changed file is flagged as contamination" 1 bash "$SNAPSHOT_DIFF" check "$TARGET" "$SNAP"
check_output_contains "changed-file report names the path" "CHANGED: keep.txt"

# 6. a deleted file is flagged DELETED.
check "re-snapshot before delete test" 0 bash "$SNAPSHOT_DIFF" snapshot "$TARGET" "$SNAP"
rm -f "$TARGET/keep.txt"
check "deleted file is flagged as contamination" 1 bash "$SNAPSHOT_DIFF" check "$TARGET" "$SNAP"
check_output_contains "deleted-file report names the path" "DELETED: keep.txt"

# 7. snapshotting a directory that doesn't exist yet is not itself an error
#    (a fresh session may have no .claude/session/reviews/ at all).
FRESH="$WORKDIR/does-not-exist-yet"
FRESH_SNAP="$WORKDIR/fresh.manifest"
check "snapshot of a missing dir creates it and succeeds" 0 bash "$SNAPSHOT_DIFF" snapshot "$FRESH" "$FRESH_SNAP"
check "check of an untouched fresh dir is clean" 0 bash "$SNAPSHOT_DIFF" check "$FRESH" "$FRESH_SNAP"

echo
echo "snapshot-diff test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
