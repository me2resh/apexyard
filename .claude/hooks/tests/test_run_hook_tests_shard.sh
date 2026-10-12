#!/usr/bin/env bash
# Runner discovery and round-robin shard coverage (me2resh/apexyard#1612).
set -euo pipefail
# Isolate from live session pins and caches.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset HOOK_TEST_SHARD HOOK_TEST_SHARDS
pass=0
check() {
  if "$@"; then
    pass=$((pass+1))
  else
    echo "FAIL: $*" >&2
    exit 1
  fi
}
mkdir -p "$TMP/tree/bin" "$TMP/tree/.claude/hooks/tests" \
  "$TMP/tree/.claude/agents/tests" "$TMP/tree/.claude/skills/example/tests"
cp "$ROOT/bin/run-hook-tests.sh" "$TMP/tree/bin/"
for name in z a m b c d e f g h j; do
  printf 'exit 0\n' > "$TMP/tree/.claude/hooks/tests/test_$name.sh"
done
printf 'exit 0\n' > "$TMP/tree/.claude/skills/example/tests/example.test.sh"
RUNNER="$TMP/tree/bin/run-hook-tests.sh"
list() {
  "$BASH" "$1" "${@:2}" --list | sed '/^(/d'
}
list "$RUNNER" > "$TMP/all"
find "$TMP/tree/.claude" -type f -name '*.sh' | sed "s|$TMP/tree/||" | LC_ALL=C sort > "$TMP/expected"
check cmp "$TMP/all" "$TMP/expected"
for n in 1 2 3 4 5; do
  : > "$TMP/union"
  for ((i=1; i<=n; i++)); do
    list "$RUNNER" --shard "$i/$n" > "$TMP/shard"
    awk -v i="$i" -v n="$n" '(NR-1)%n == i-1' "$TMP/all" > "$TMP/expected"
    check cmp "$TMP/shard" "$TMP/expected"
    cat "$TMP/shard" >> "$TMP/union"
  done
  LC_ALL=C sort "$TMP/union" > "$TMP/sorted"
  check cmp "$TMP/all" "$TMP/sorted"
  LC_ALL=C sort "$TMP/union" | uniq -d > "$TMP/duplicates"
  check test ! -s "$TMP/duplicates"
done
for value in 0/4 1/0 5/4 -1/4 1/-4 x/4 1/x 1.5/4 1/2/3 /4 1/ 0/0; do
  rc=0
  "$BASH" "$RUNNER" --shard "$value" --list > "$TMP/error" 2>&1 || rc=$?
  check test "$rc" -eq 2
  check grep -q 'Invalid shard' "$TMP/error"
done
rc=0
HOOK_TEST_SHARD=1 "$BASH" "$RUNNER" --list > "$TMP/error" 2>&1 || rc=$?
check test "$rc" -eq 2
rc=0
HOOK_TEST_SHARD='' HOOK_TEST_SHARDS='' "$BASH" "$RUNNER" --list > "$TMP/error" 2>&1 || rc=$?
check test "$rc" -eq 2
HOOK_TEST_SHARD=2 HOOK_TEST_SHARDS=4 list "$RUNNER" > "$TMP/env"
list "$RUNNER" --shard 2/4 > "$TMP/cli"
check cmp "$TMP/env" "$TMP/cli"
list "$RUNNER" --shard 02/04 > "$TMP/zeros"
check cmp "$TMP/zeros" "$TMP/cli"
HOOK_TEST_SHARD=x HOOK_TEST_SHARDS=x list "$RUNNER" --shard 2/4 > "$TMP/override"
check cmp "$TMP/override" "$TMP/cli"
list "$ROOT/bin/run-hook-tests.sh" > "$TMP/real"
: > "$TMP/union"
for i in 1 2 3 4; do
  list "$ROOT/bin/run-hook-tests.sh" --shard "$i/4" >> "$TMP/union"
done
LC_ALL=C sort "$TMP/union" > "$TMP/sorted"
check cmp "$TMP/real" "$TMP/sorted"
# Exercise execution, summary, diagnostics, and concurrent runner isolation.
"$BASH" "$RUNNER" > "$TMP/run"
check grep -q 'PASS=12  FAIL=0 .*TOTAL=12' "$TMP/run"
check grep -q '^hook tests: shard 1/1, 12 tests' "$TMP/run"
check grep -q '^Wall-clock: [0-9][0-9]* seconds' "$TMP/run"
"$BASH" "$RUNNER" --shard 1/4 > "$TMP/run1" &
pid1=$!
"$BASH" "$RUNNER" --shard 2/4 > "$TMP/run2" &
pid2=$!
check wait "$pid1"
check wait "$pid2"
check grep -q 'PASS=3  FAIL=0 .*TOTAL=3' "$TMP/run1"
check grep -q 'PASS=3  FAIL=0 .*TOTAL=3' "$TMP/run2"
printf 'echo SKIP synthetic skipped case\n' > "$TMP/tree/.claude/hooks/tests/test_a.sh"
rc=0
"$BASH" "$RUNNER" > "$TMP/run" 2>&1 || rc=$?
check test "$rc" -eq 1
check grep -q 'suite reported a skipped case' "$TMP/run"
printf 'echo synthetic failure; exit 7\n' > "$TMP/tree/.claude/hooks/tests/test_a.sh"
rc=0
"$BASH" "$RUNNER" > "$TMP/run" 2>&1 || rc=$?
check test "$rc" -eq 1
check grep -q 'synthetic failure' "$TMP/run"
# Weighted shards cover every test once for each supported shard count.
WEIGHTS="$TMP/weights"
printf '# Measured weights\n\n100 .claude/hooks/tests/test_a.sh\n90 .claude/hooks/tests/test_b.sh\n10 .claude/hooks/tests/test_c.sh\n999 .claude/hooks/tests/test_absent.sh\n' > "$WEIGHTS"
for n in 1 2 3 4 5 6 7 8; do
  : > "$TMP/union"
  for ((i=1; i<=n; i++)); do
    HOOK_TEST_WEIGHTS_FILE="$WEIGHTS" list "$RUNNER" --shard "$i/$n" >> "$TMP/union"
  done
  LC_ALL=C sort "$TMP/union" > "$TMP/sorted"
  check cmp "$TMP/all" "$TMP/sorted"
  LC_ALL=C sort "$TMP/union" | uniq -d > "$TMP/duplicates"
  check test ! -s "$TMP/duplicates"
done
HOOK_TEST_WEIGHTS_FILE="$WEIGHTS" list "$RUNNER" --shard 1/1 > "$TMP/one"
check cmp "$TMP/all" "$TMP/one"
: > "$WEIGHTS"
HOOK_TEST_WEIGHTS_FILE="$WEIGHTS" list "$RUNNER" --shard 1/2 > "$TMP/empty"
list "$RUNNER" --shard 1/2 > "$TMP/round-robin"
check cmp "$TMP/empty" "$TMP/round-robin"
# Five tests: a goes to shard 1, b and c to shard 2, d to shard 1,
# and e to shard 2. Missing entries have weight 10.
mkdir -p "$TMP/five/bin" "$TMP/five/.claude/hooks/tests"
cp "$ROOT/bin/run-hook-tests.sh" "$TMP/five/bin/"
for name in a b c d e; do
  printf 'exit 0\n' > "$TMP/five/.claude/hooks/tests/test_$name.sh"
done
printf '# Comments and blank lines are ignored\n\n100 .claude/hooks/tests/test_a.sh\n90 .claude/hooks/tests/test_b.sh\n10 .claude/hooks/tests/test_c.sh\n999 .claude/hooks/tests/test_absent.sh\n' > "$WEIGHTS"
HOOK_TEST_WEIGHTS_FILE="$WEIGHTS" list "$TMP/five/bin/run-hook-tests.sh" --shard 1/2 > "$TMP/weighted1"
printf '.claude/hooks/tests/test_a.sh\n.claude/hooks/tests/test_d.sh\n' > "$TMP/expected"
check cmp "$TMP/weighted1" "$TMP/expected"
HOOK_TEST_WEIGHTS_FILE="$WEIGHTS" list "$TMP/five/bin/run-hook-tests.sh" --shard 2/2 > "$TMP/weighted2"
printf '.claude/hooks/tests/test_b.sh\n.claude/hooks/tests/test_c.sh\n.claude/hooks/tests/test_e.sh\n' > "$TMP/expected"
check cmp "$TMP/weighted2" "$TMP/expected"
printf '10 .claude/hooks/tests/test_d.sh\n10 .claude/hooks/tests/test_e.sh\n' >> "$WEIGHTS"
HOOK_TEST_WEIGHTS_FILE="$WEIGHTS" list "$TMP/five/bin/run-hook-tests.sh" --shard 1/2 > "$TMP/explicit"
check cmp "$TMP/weighted1" "$TMP/explicit"
printf '# No weights\n\n' > "$WEIGHTS"
HOOK_TEST_WEIGHTS_FILE="$WEIGHTS" list "$RUNNER" --shard 1/2 > "$TMP/comments"
check cmp "$TMP/comments" "$TMP/round-robin"
printf 'PASS=%s FAIL=0\n' "$pass"
