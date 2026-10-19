#!/bin/bash
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
# Capture the platform patch implementation without writing outside the fixture.
# shellcheck source=/dev/null
. "$(dirname "$0")/_test-protected-state.sh"
case "$(uname -s)" in
  Darwin) ;;
  *)
    capture="$ROOT/tests/fixtures/protected-target-writes/macos-patch-p0.txt"
    grep -q '^absolute: exit=0 target=new$' "$capture" || exit 1
    grep -q '^dotdot: exit=0 target=new$' "$capture" || exit 1
    echo 'PASS: recorded macOS patch capture fixture'
    exit 0
    ;;
esac
capture="$ROOT/tests/fixtures/protected-target-writes/macos-patch-p0.txt"
mkdir -p "$TMP/capture/work" "$TMP/capture/target"
printf 'old\n' > "$TMP/capture/target/x"
for form in absolute dotdot; do
  if [ "$form" = absolute ]; then target="$TMP/capture/target/x"; else target='../target/x'; fi
  printf '%s\n' "--- $target" "+++ $target" '@@ -1 +1 @@' '-old' '+new' > "$TMP/capture/input.patch"
  rc=0
  (cd "$TMP/capture/work" && /usr/bin/patch -f -p0 < "$TMP/capture/input.patch") > "$TMP/capture/output" 2>&1 || rc=$?
  line="$form: exit=$rc target=$(cat "$TMP/capture/target/x")"
  printf '%s\n' "$line"
  cat "$TMP/capture/output"
  # The header rule in block-protected-target-writes.sh depends on this
  # behaviour. A change in Apple patch must update the fixture and the rule.
  check 0 "$form matches the recorded capture" grep -qxF "$line" "$capture"
  printf 'old\n' > "$TMP/capture/target/x"
done
finish
