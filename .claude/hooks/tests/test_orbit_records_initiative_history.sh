#!/usr/bin/env bash
# orbit_records_initiative resolves a branch initiative from plans/ or, for a
# branch that retires an initiative, from a superseded plan in history/.
# A reconciliation in history/ (it carries .planId) never resolves one.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../_lib-orbit-records.sh"

fail=0
sb=$(mktemp -d)
trap 'rm -rf "$sb"' EXIT
git -C "$sb" init -q
git -C "$sb" config user.email test@example.com
git -C "$sb" config user.name test
mkdir -p "$sb/docs/orbit/plans" "$sb/docs/orbit/history"

check() {
  local name="$1" want="$2" rc
  orbit_records_initiative "$sb" "$3"; rc=$?
  if [ "$want" = none ]; then
    [ "$rc" -ne 0 ] || { echo "FAIL: $name: resolved $ORBIT_INITIATIVE"; fail=1; }
  else
    [ "$rc" -eq 0 ] && [ "$ORBIT_INITIATIVE" = "$want" ] || { echo "FAIL: $name: rc=$rc got '$ORBIT_INITIATIVE'"; fail=1; }
  fi
}

printf '{"id":"plan-demo-widget","revision":1}\n' > "$sb/docs/orbit/plans/plan-demo-widget.r1.json"
git -C "$sb" add docs && git -C "$sb" commit -qm base
git -C "$sb" checkout -qb orbit/demo-widget-cycle
check "plan in plans/" demo-widget orbit/demo-widget-cycle

git -C "$sb" checkout -qb orbit/demo-widget-retire
git -C "$sb" mv docs/orbit/plans/plan-demo-widget.r1.json docs/orbit/history/plan-demo-widget.r1.json
git -C "$sb" commit -qm retire
check "retired plan in history/" demo-widget orbit/demo-widget-retire

git -C "$sb" checkout -qb orbit/other-thing-retire
git -C "$sb" rm -q docs/orbit/history/plan-demo-widget.r1.json
mkdir -p "$sb/docs/orbit/history"
printf '{"id":"reconciliation-other-thing-r1","planId":"plan-other-thing"}\n' > "$sb/docs/orbit/history/reconciliation-other-r1.json"
git -C "$sb" add docs && git -C "$sb" commit -qm recon-only
check "history reconciliation only" none orbit/other-thing-retire

[ "$fail" -eq 0 ] && echo "PASS: orbit_records_initiative reads plans/ and history/ plans"
exit "$fail"
