#!/usr/bin/env bash
set -eu
# shellcheck source=./_lib-fixtures.sh
. "$(dirname "$0")/_lib-fixtures.sh"
sb=$(make_sandbox)
trap 'rm -rf "$sb"' EXIT
orbit_root=$(fixtures_write_orbit_root "$sb")
helper="$(cd "$(dirname "$0")/.." && pwd)/lib/warn-uncovered-outcomes.sh"
slice="$orbit_root/slices/slice-demo-o1.json"
check() {
  local output count
  output=$(bash "$helper" --orbit-root "$orbit_root" 2>&1)
  count=$(printf '%s\n' "$output" | grep -c '^WARNING: ORBIT outcome o1-demo' || true)
  [ "$count" -eq "$1" ] || { echo "FAIL: Expected $1 warnings: $output"; exit 1; }
}
check 0
jq '.outcomeId="o2-demo" | .contributesTo=["ac2-1"]' "$slice" > "$sb/slice.json"
cp "$sb/slice.json" "$slice"
check 1
jq '.outcomeIds=["o2-demo","o1-demo"]' "$sb/slice.json" > "$slice"
check 0
jq '.basedOn.planRevision=2' "$slice" > "$sb/stale.json"
mv "$sb/stale.json" "$slice"
check 1
echo 'PASS: outcomeIds current-revision coverage'
