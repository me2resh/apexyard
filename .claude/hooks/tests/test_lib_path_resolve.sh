#!/bin/bash
# Direct regression tests for _resolve_real_path (#1202).

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib-path-resolve.sh
. "$SRC_ROOT/.claude/hooks/_lib-path-resolve.sh"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    echo "PASS [$label]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [$label]: want '$want', got '$got'" >&2
    FAIL=$((FAIL + 1))
  fi
}

missing="/__apexyard_1202_missing__/nested/file.sql"
resolved="$(_resolve_real_path "$missing")"
assert_eq "absent root has one leading slash" "$missing" "$resolved"

existing_base="$(mktemp -d)"
existing_tail="$existing_base/nested/file.sql"
resolved="$(_resolve_real_path "$existing_tail")"
existing_tail_canonical="$(cd "$existing_base" && pwd -P)/nested/file.sql"
assert_eq "absent tail remains under its existing ancestor" "$existing_tail_canonical" "$resolved"
rm -rf "$existing_base"

echo "===== test_lib_path_resolve.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
