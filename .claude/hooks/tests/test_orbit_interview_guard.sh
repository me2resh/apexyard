#!/usr/bin/env bash
# Interview evidence is required only for new or changed Plans (#1694).
set -eu
# shellcheck source=./_test-session-isolation.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
root=$(cd "$(dirname "$0")/../../.." && pwd)
sb=$(mktemp -d "${TMPDIR:-/tmp}/orbit-interview-test.XXXXXX")
trap 'rm -rf "$sb"' EXIT
mkdir -p "$sb/docs/orbit/plans" "$sb/bin"
printf '#!/bin/bash\nexit 0\n' > "$sb/bin/orbit"
chmod +x "$sb/bin/orbit"
export ORBIT_BIN="$sb/bin/orbit"
unset APEXYARD_OPS_ROOT APEXYARD_PORTFOLIO_ROOT
lint="$root/.claude/skills/orbit/lib/records-lint.sh"
orbit_root="$sb/docs/orbit"
plan="$orbit_root/plans/plan-demo.r1.json"
notes="$orbit_root/plans/plan-demo.notes.md"
g() { git -C "$sb" -c user.name=test -c user.email=test@example.com "$@"; }
g init -q
g -c core.hooksPath=/dev/null commit --allow-empty -qm baseline
g branch base
expect() {
  local name="$1" want="$2" message="$3" out rc=0
  shift 3
  out=$(bash "$lint" --orbit-root "$orbit_root" --base base "$@" 2>&1) || rc=$?
  if [ "$rc" -ne "$want" ] || [[ "$out" != *"$message"* ]]; then
    echo "FAIL: $name: expected $want and '$message', got $rc: $out"
    exit 1
  fi
  echo "PASS: $name"
}
answers() {
  printf '## Interview\n'
  for key in q1-outcome q2-intent q3-outcomes q4-acceptance q5-constraints q6-save; do
    printf -- '- 2026-10-12, %s: My answer.\n' "$key"
  done
}
printf '{"id":"plan-demo","revision":1}\n' > "$plan"
expect 'new Plan without notes' 16 'Missing ## Interview section'
printf '## Proof\n' > "$notes"
expect 'new Plan without Interview section' 16 'Missing ## Interview section'
answers | sed '/q5-constraints/d' > "$notes"
expect 'missing question names its key' 16 'q5-constraints'
answers > "$notes"
expect 'all six answers pass' 0 'records-lint: OK'
# Answers in a later section do not count.
printf '## Interview\n## Proof\n' > "$notes"
answers | sed '1d' >> "$notes"
expect 'answers must be inside Interview' 16 'q1-outcome'
answers | sed 's/2026-10-12, q1-outcome/undated, q1-outcome/' > "$notes"
expect 'undated answer fails' 16 'q1-outcome'
answers | sed 's/q1-outcome: My answer./q1-outcome:   /' > "$notes"
expect 'empty answer fails' 16 'q1-outcome'
# A legacy Plan remains exempt even when its notes change.
rm "$notes"
g add docs/orbit/plans/plan-demo.r1.json
g -c core.hooksPath=/dev/null commit -qm 'legacy Plan'
g branch -f base HEAD
printf '## Checks\n- Checked.\n' > "$notes"
expect 'unchanged Plan is not checked' 0 'records-lint: OK'
expect '--all checks unchanged Plans' 16 'Missing ## Interview section' --all
printf '{"id":"plan-demo","revision":2}\n' > "$plan"
expect 'changed Plan is checked' 16 'Missing ## Interview section'
answers > "$notes"
expect 'changed Plan with six answers passes' 0 'records-lint: OK'
