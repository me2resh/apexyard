#!/usr/bin/env bash
# Union ownership partition, fetch completeness, and the state-dir guard.
. "$(dirname "$0")/_helpers.sh"

state="$SANDBOX/state.json"
"$DUTY" init "$state" "2026-01-04T08:00:00Z"
"$DUTY" record-action "$state" "3" push "2026-01-04T09:00:00Z"
"$DUTY" record-action "$state" "9" push "2026-01-03T09:00:00Z"
"$DUTY" record-action "$state" "42" push "2026-01-04T09:00:00Z"

K='"assignee_known": true, "comments_known": true, "unresolved_known": true'
cat > "$SANDBOX/items.json" <<EOF
[
  {"id": "1", "created": "2026-01-04T09:00:00Z", "assignee_id": "u-me",
   "unresolved_waiting_on_me": 2, $K},
  {"id": "2", "created": "2026-01-01T09:00:00Z", "assignee_id": "u-me", $K},
  {"id": "3", "created": "2026-01-01T09:00:00Z", "assignee_id": "u-other", $K},
  {"id": "4", "created": "2026-01-04T09:00:00Z", "assignee_id": "u-other", $K},
  {"id": "5", "created": "2026-01-04T09:00:00Z", "assignee_id": "", $K},
  {"id": "6", "created": "2026-01-01T09:00:00Z", "assignee_id": "u-me",
   "last_comment_at": "2026-01-04T10:00:00Z", "last_comment_author_id": "u-reviewer", $K},
  {"id": "7", "created": "2026-01-01T09:00:00Z", "assignee_id": "u-me",
   "last_comment_at": "2026-01-04T10:00:00Z", "last_comment_author_id": "u-me", $K},
  {"id": "8", "created": null, "assignee_known": false, "comments_known": false,
   "unresolved_known": false},
  {"id": "9", "created": "2026-01-01T09:00:00Z", "assignee_id": "u-other", $K},
  {"id": 42, "created": "2026-01-01T09:00:00Z", "assignee_id": "u-other", $K},
  {"id": "11", "created": "2026-01-01T09:00:00Z", "assignee_id": "u-me"},
  {"id": "12", "created": "2026-01-04T10:30:00.123+02:00", "assignee_id": "u-me", $K},
  {"id": "13", "created": "2026-01-04T08:30:00+02:00", "assignee_id": "u-me", $K}
]
EOF

out=$("$DUTY" partition "$SANDBOX/items.json" "$state" "u-me")
get() { printf '%s' "$out" | jq -c --arg id "$1" ".[] | select(.id == \$id) | $2"; }

expect_eq "$(get 1 .matched)" '["new_in_scope","reviewer_waiting"]' \
  "every matching condition is recorded, not only the first"
expect_eq "$(get 2 .owned)" "false" "old item with no activity is backlog"
expect_eq "$(get 3 .matched)" '["acted_this_shift"]' "ledger action makes an old item owned"
expect_eq "$(get 4 .owned)" "false" "new item assigned to someone else is not owned"
expect_eq "$(get 5 .matched)" '["new_in_scope"]' "new unassigned item is owned"
expect_eq "$(get 6 .matched)" '["mine_new_comment"]' "comment from someone else is owned"
expect_eq "$(get 7 .owned)" "false" "your own comment does not pull an item in"
expect_eq "$(get 8 .unknown)" '["new_in_scope","mine_new_comment","reviewer_waiting"]' \
  "unread inputs are unknown, not false"
expect_eq "$(get 9 .owned)" "false" "a ledger action before the scope timestamp does not count"
expect_eq "$(get 42 .matched)" '["acted_this_shift"]' "a numeric id matches a string ledger entry"
expect_eq "$(get 11 .unknown)" '["new_in_scope","mine_new_comment","reviewer_waiting"]' \
  "absent known flags are unknown, not false"
expect_eq "$(get 12 .matched)" '["new_in_scope"]' "offset timestamps with fractions compare by instant"
expect_eq "$(get 13 .owned)" "false" "an offset timestamp before the scope instant is out of scope"

odd="$SANDBOX/odd.json"
echo "[{\"id\": \"20\", \"created\": \"2026-01-04T09:00:00\", \"assignee_id\": \"u-me\", $K},
       {\"id\": \"21\", \"created\": \"2026-01-01T09:00:00Z\", \"assignee_id\": \"u-me\",
        \"last_comment_at\": \"yesterday\", \"last_comment_author_id\": \"u-reviewer\", $K}]" > "$odd"
out3=$("$DUTY" partition "$odd" "$state" "u-me"); rc=$?
expect_eq "$rc" "0" "one unparseable item does not break the partition"
expect_eq "$(printf '%s' "$out3" | jq -c '.[] | select(.id == "20") | .unknown')" '["new_in_scope"]' \
  "an unparseable creation time is unknown, not false"
expect_eq "$(printf '%s' "$out3" | jq -c '.[] | select(.id == "21") | .unknown')" '["mine_new_comment"]' \
  "an unparseable comment time is unknown, not false"

"$DUTY" init "$SANDBOX/bad-scope.json" "2026-01-04 08:00" 2>/dev/null; rc=$?
expect_eq "$rc" "2" "init refuses an unparseable scope timestamp"
jq '.shift.scope_timestamp = "2026-01-04 08:00"' "$state" > "$SANDBOX/bad-state.json"
"$DUTY" partition "$SANDBOX/items.json" "$SANDBOX/bad-state.json" "u-me" >/dev/null 2>&1; rc=$?
expect_eq "$([ "$rc" -ne 0 ] && echo failed || echo "passed silently")" "failed" \
  "a corrupt scope timestamp fails loudly instead of printing nothing"

display="$SANDBOX/display.json"
echo "[{\"id\": \"10\", \"created\": \"2026-01-04T09:00:00Z\", \"assignee_id\": \"u-namesake\",
        \"assignee_name\": \"Same Name\", $K}]" > "$display"
out2=$("$DUTY" partition "$display" "$state" "u-me")
expect_eq "$(printf '%s' "$out2" | jq -r '.[0].owned')" "false" "a shared display name is not identity"

reversed="$SANDBOX/reversed.json"
jq 'reverse' "$SANDBOX/items.json" > "$reversed"
a=$("$DUTY" partition "$SANDBOX/items.json" "$state" "u-me" | jq -S 'sort_by(.id)')
b=$("$DUTY" partition "$reversed" "$state" "u-me" | jq -S 'sort_by(.id)')
expect_eq "$a" "$b" "the partition does not depend on input order"

expect_eq "$("$DUTY" fetch-status 0 28 100)" "COMPLETE" "a short page proves the end"
expect_eq "$("$DUTY" fetch-status 0 100 100)" "TRUNCATED" "a full page does not prove the end"
expect_eq "$("$DUTY" fetch-status 1 0 100)" "UNKNOWN" "a failed fetch is not zero"
expect_eq "$("$DUTY" fetch-status 0 "" 100)" "UNKNOWN" "an unreadable count is not zero"
expect_eq "$("$DUTY" fetch-status 0 100 200 100)" "TRUNCATED" "a capped page size is not a short read"
expect_eq "$("$DUTY" fetch-status 0 99 200 100)" "COMPLETE" "a read below the cap proves the end"

repo="$SANDBOX/repo"
mkdir -p "$repo" && git -C "$repo" init -q
out=$("$DUTY" state-dir-check "$repo/.duty"); rc=$?
expect_eq "$rc" "1" "a state dir inside a repository is refused"
expect_contains "$out" "INSIDE_REPO" "refusal names the reason"
expect_eq "$("$DUTY" state-dir-check "$SANDBOX/outside/state")" "OK" "a state dir outside repositories is accepted"

finish test_duty_partition
