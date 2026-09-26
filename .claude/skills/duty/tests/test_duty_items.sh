#!/usr/bin/env bash
# Escalation states: open, parked, closed.
. "$(dirname "$0")/_helpers.sh"

state="$SANDBOX/state.json"
"$DUTY" init "$state" "2026-01-04T08:00:00Z"

expect_eq "$("$DUTY" item "$state" A escalate loop "needs a merge")" "open" "escalation opens an item"
expect_eq "$("$DUTY" item "$state" A escalate loop "again")" "open" "repeat escalation is idempotent"
"$DUTY" item "$state" B escalate loop "needs a migration" >/dev/null
"$DUTY" item "$state" C escalate loop "runner fleet" >/dev/null

out=$("$DUTY" item "$state" A park loop "the loop decided"); rc=$?
expect_eq "$rc" "1" "the loop cannot park an item"
expect_contains "$out" "only the operator" "refusal names the operator"

expect_eq "$("$DUTY" item "$state" A park operator "defer to next week")" "parked" "operator parks an item"

nag=$("$DUTY" nag "$state" | sort | tr '\n' ' ')
expect_eq "$nag" "B C " "parked items are not repeated in reports"

hand=$("$DUTY" handover-items "$state" | cut -f1,2 | sort | tr '\t\n' ':|')
expect_eq "$hand" "open:B|open:C|parked:A|" "handover keeps parked items"

expect_eq "$("$DUTY" item "$state" A escalate loop "loop saw it again")" "parked" \
  "re-escalating a parked item does not reopen it"

out=$("$DUTY" item "$state" A unpark loop "x"); rc=$?
expect_eq "$rc" "1" "the loop cannot unpark an item"
expect_eq "$("$DUTY" item "$state" A unpark operator "ready now")" "open" "operator unparks an item"

expect_eq "$("$DUTY" item "$state" B close loop "operator merged")" "closed" "an item closes"
hand=$("$DUTY" handover-items "$state" | cut -f2 | sort | tr '\n' ' ')
expect_eq "$hand" "A C " "closed items leave the handover"

out=$("$DUTY" item "$state" Z park operator "x"); rc=$?
expect_eq "$rc" "1" "an unknown item cannot be parked"

finish test_duty_items
