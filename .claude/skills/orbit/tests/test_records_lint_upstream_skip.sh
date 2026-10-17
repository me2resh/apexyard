#!/usr/bin/env bash
# Check upstream record exclusion. Use no network access.
set -euo pipefail
# shellcheck source=./_lib-fixtures.sh
. "$(dirname "$0")/_lib-fixtures.sh"
real_root="$(cd "$(dirname "$0")/../../../.." && pwd)"
sb=$(make_sandbox)
trap 'rm -rf "$sb"' EXIT
fixtures_install_mock_orbit "$sb"
fixtures_install_leak_scrub_sandbox "$sb" >/dev/null
cp "$real_root/.claude/skills/orbit/lib/records-lint.sh" "$sb/.claude/skills/orbit/lib/"
cp "$real_root/.claude/skills/orbit/lib/slice-pr-lint.sh" "$sb/.claude/skills/orbit/lib/"
cp "$real_root/.claude/hooks/_lib-orbit-records.sh" "$sb/.claude/hooks/"
export ORBIT_BIN="$sb/bin/orbit"
unset APEXYARD_OPS_ROOT APEXYARD_PORTFOLIO_ROOT CLAUDE_CODE_SESSION_ID
export APEXYARD_OPS_PIN_DIR="$sb/pin"
g() { git -C "$sb" -c user.name=test -c user.email=test@example.com "$@"; }
g init -q
g checkout -qb fork
g commit -qm base --allow-empty
g branch base
g checkout -qb upstream
mkdir -p "$sb/docs/orbit/snapshots"
record=docs/orbit/snapshots/snapshot-demo.json
long26=$(printf 'word %.0s' {1..26})
long30=$(printf 'changed %.0s' {1..30})
jq -n --arg text "$long26" '{id:"snapshot-demo",description:$text}' > "$sb/$record"
g add "$record"
g commit -qm upstream
g checkout -q fork
g checkout upstream -- docs/orbit
g commit -qm import
passed=0
failed=0
expect() {
  local name="$1" want="$2" match="$3" out rc=0
  shift 3
  out=$(bash "$sb/.claude/skills/orbit/lib/records-lint.sh" \
    --orbit-root "$sb/docs/orbit" --base base "$@" 2>&1) || rc=$?
  if [ "$rc" -eq "$want" ] && [[ "$out" == *"$match"* ]]; then
    echo "PASS: $name"
    passed=$((passed + 1))
  else
    echo "FAIL: $name: expected $want and $match; got $rc: $out"
    failed=$((failed + 1))
  fi
}
expect 'Default checks imported text' 12 '[sentence]'
expect 'Skip identical upstream record' 0 'skipped 1 upstream record(s)' --upstream upstream
expect 'All mode skips upstream records' 0 'skipped 1 upstream record(s)' --all --upstream upstream
# Skip imported plans and snapshots before the initiative checks.
g checkout -q upstream
mkdir -p "$sb/docs/orbit/plans"
echo '{"id":"plan-demo"}' > "$sb/docs/orbit/plans/plan-demo.r1.json"
g add docs/orbit/plans
g commit -qm plan
g checkout -q fork
g checkout upstream -- docs/orbit/plans
g commit -qm import-plan
g checkout -qb orbit/demo-cycle
expect 'Initiative skips imported records' 0 'skipped 2 upstream record(s)' --upstream upstream
g checkout -q fork
jq --arg text "$long30" '.description=$text' "$sb/$record" > "$sb/changed.json"
mv "$sb/changed.json" "$sb/$record"
g add "$record"
g commit -qm changed
expect 'Changed upstream record fails' 12 '[sentence]' --upstream upstream
g checkout upstream -- "$record"
g add "$record"
g commit -qm restore
jq -n --arg text "$long30" '{description:$text}' > "$sb/docs/orbit/snapshots/new.json"
g add docs/orbit/snapshots/new.json
g commit -qm new
expect 'New fork record fails' 12 '[sentence]' --upstream upstream
expect 'Invalid upstream ref fails closed' 20 'Cannot resolve the upstream ref' --upstream missing-ref
printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
