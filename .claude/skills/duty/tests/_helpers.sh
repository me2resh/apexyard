#!/usr/bin/env bash
export DUTY="${DUTY_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/duty.sh}"
PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; }

expect_eq() {
  if [ "$1" = "$2" ]; then ok; else bad "$3 (expected [$2], got [$1])"; fi
}

expect_contains() {
  case "$1" in *"$2"*) ok ;; *) bad "$3 (missing [$2] in [$1])" ;; esac
}

finish() {
  printf '%s: PASS=%d FAIL=%d\n' "$1" "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
