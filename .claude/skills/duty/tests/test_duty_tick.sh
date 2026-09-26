#!/usr/bin/env bash
# Tick order, the failed-tick check, and the liveness gate.
. "$(dirname "$0")/_helpers.sh"

state="$SANDBOX/state.json"
"$DUTY" init "$state" "2026-01-04T08:00:00Z"

plan=$("$DUTY" plan "$state" "2026-01-04T08:00:00Z" | tr '\n' ' ')
expect_eq "$plan" "liveness watcher stamp_watcher review stamp_review report journal " \
  "first tick plans the review pass after the watcher stamp"

"$DUTY" stamp "$state" watcher "2026-01-04T08:00:00Z"
"$DUTY" stamp "$state" review "2026-01-04T08:00:00Z"
plan=$("$DUTY" plan "$state" "2026-01-04T08:15:00Z" | tr '\n' ' ')
expect_eq "$plan" "liveness watcher stamp_watcher report journal " \
  "review pass is skipped when not due, the watcher pass is not"

plan=$("$DUTY" plan "$state" "2026-01-04T08:30:00Z" | tr '\n' ' ')
expect_contains "$plan" "stamp_watcher review" "review pass is due at 30 minutes"

log="$SANDBOX/good.log"
printf '%s\n' liveness watcher stamp_watcher review stamp_review report journal > "$log"
expect_eq "$("$DUTY" verify-tick "$log")" "OK" "correct tick verifies"

printf '%s\n' liveness review stamp_review report journal > "$SANDBOX/skip.log"
out=$("$DUTY" verify-tick "$SANDBOX/skip.log"); rc=$?
expect_eq "$rc" "1" "tick that skipped the watcher fails"
expect_contains "$out" "watcher pass skipped" "failure names the skipped watcher"

printf '%s\n' liveness watcher review stamp_watcher report > "$SANDBOX/late.log"
out=$("$DUTY" verify-tick "$SANDBOX/late.log")
expect_contains "$out" "review ran before the watcher stamp" "late watcher stamp fails"

printf '%s\n' watcher liveness stamp_watcher report > "$SANDBOX/gate.log"
out=$("$DUTY" verify-tick "$SANDBOX/gate.log")
expect_contains "$out" "liveness gate did not run first" "liveness gate must be first"

printf '%s\n' liveness watcher report > "$SANDBOX/nostamp.log"
out=$("$DUTY" verify-tick "$SANDBOX/nostamp.log")
expect_contains "$out" "watcher stamp missing" "missing watcher stamp fails"

expect_eq "$("$DUTY" liveness "$state" "2026-01-04T08:40:00Z")" "OK" "fresh stamps are live"

out=$("$DUTY" liveness "$state" "2026-01-04T09:00:00Z")
expect_eq "$out" "STALE watcher 60" "stale watcher reports the minutes lost"

out=$("$DUTY" liveness "$state" "2026-01-04T10:00:00Z" | tr '\n' '|')
expect_eq "$out" "STALE watcher 120|STALE review 120|" "both stale stamps are reported"

out=$(DUTY_CONFIG_JSON='{"watcher_stale_minutes": 120}' "$DUTY" liveness "$state" "2026-01-04T09:00:00Z")
expect_eq "$out" "OK" "configured threshold is honoured"

fresh="$SANDBOX/fresh.json"
"$DUTY" init "$fresh" "2026-01-04T08:00:00Z"
expect_eq "$("$DUTY" liveness "$fresh" "2026-01-04T08:01:00Z")" "NEVER watcher" \
  "a shift with no watcher stamp is reported, not treated as live"

jq '.last_tick = "2026-01-04T09:59:00Z"' "$state" > "$SANDBOX/renamed.json"
out=$("$DUTY" liveness "$SANDBOX/renamed.json" "2026-01-04T10:00:00Z" | head -1)
expect_eq "$out" "STALE watcher 120" "a field nothing reads cannot mask a stale stamp"

"$DUTY" record-action "$state" "42" push "2026-01-04T08:05:00Z"
expect_eq "$(jq -r '.actions[0].item + ":" + .actions[0].action' "$state")" "42:push" \
  "actions are recorded in the ledger"

printf '%s\n' liveness watcher stamp_watcher review stamp_review report journal > "$SANDBOX/plan"
printf '%s\n' liveness watcher stamp_watcher report journal > "$SANDBOX/noreview.log"
out=$("$DUTY" verify-tick "$SANDBOX/noreview.log" "$SANDBOX/plan"); rc=$?
expect_eq "$rc" "1" "a tick that skipped a planned review fails"
expect_contains "$out" "planned review pass skipped" "failure names the skipped review"
expect_eq "$("$DUTY" verify-tick "$log" "$SANDBOX/plan")" "OK" "a tick that ran its plan verifies"

archived=$("$DUTY" stop "$state" "2026-01-08T17:00:00Z")
expect_eq "$([ -f "$state" ] && echo present || echo gone)" "gone" "stop removes the live state file"
expect_eq "$(jq -r .shift.stopped "$archived")" "2026-01-08T17:00:00Z" "stop archives the shift"
"$DUTY" init "$state" "2026-01-11T08:00:00Z"
expect_eq "$(jq -r .shift.scope_timestamp "$state")" "2026-01-11T08:00:00Z" "a new shift starts after stop"

"$DUTY" init "$state" "2026-01-12T08:00:00Z" 2>/dev/null; rc=$?
expect_eq "$rc" "2" "init refuses to overwrite a live shift"

finish test_duty_tick
