#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
root=$(cd "$(dirname "$0")/../../.." && pwd)
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT
# shellcheck source=/dev/null
. "$root/.claude/hooks/_lib-sla.sh"
count=0
check() {
  count=$((count+1))
  if ! "$@"; then echo "FAIL row $count: $*"; exit 1; fi
}
reject() { if "$@" >"$fixture_dir/rejected" 2>&1; then return 1; fi; }
# Offline tracker. Writes survive command substitutions, just like remote writes.
tracker_issue_kind() { echo "${FAKE_KIND:-gh}"; }
tracker_view() { jq '{body:.body}' "$fixture_dir/issue"; }
config_get_or() { echo "${DAYS_OVERRIDE:-$2}"; }
tracker_list_to() {
  [ ! -f "$fixture_dir/list-error" ] || return 1
  if [ -f "$fixture_dir/issue" ] && [ ! -f "$fixture_dir/closed" ]; then
    echo '[{"ref":"42"}]' > "$1"
  else echo '[]' > "$1"; fi
  echo "${LIST_STATUS:-COMPLETE}"
}
tracker_create() {
  [ "$4" = security,HIGH,sla ] || return 1
  echo create >> "$fixture_dir/creates"
  jq -n --rawfile body "$3" '{number:42, html_url:"https://example.invalid/issues/42",body:$body,created_at:"2026-01-01T23:59:59Z",state:"open"}' > "$fixture_dir/issue"
  echo '{"ref":"42","url":"https://example.invalid/issues/42"}'
}
apexyard_gh() {
  [ ! -f "$fixture_dir/api-error" ] || return 1
  if [ "$2" = --method ]; then
    [ ! -f "$fixture_dir/update-error" ] || return 1
    jq --arg body "${6#body=}" '.body=$body' "$fixture_dir/issue" > "$fixture_dir/updated"
    mv "$fixture_dir/updated" "$fixture_dir/issue"
  elif [[ "$2" = */comments ]]; then
    cat "$fixture_dir/comments"
  else cat "$fixture_dir/issue"; fi
}
echo '[[]]' > "$fixture_dir/comments"
fp=$(sla_fingerprint dependency package ADV-1)
check test "$fp" = "$(sla_fingerprint dependency package ADV-1)"
check test "$fp" != "$(sla_fingerprint dependency package ADV-2)"
check test "$(sla_fingerprint code rule src/file.sh run)" != "$fp"
check reject sla_fingerprint dependency '' ADV-1
check test "$(sla_due_date 2024-02-28T00:00:00Z 2)" = 2024-03-01
check test "$(sla_due_date 2026-01-01T00:00:00Z none)" = none
check test "$(sla_days CRITICAL)" = 7
check test "$(sla_days MEDIUM)" = 90
check test "$(DAYS_OVERRIDE=12 sla_days HIGH)" = 12
check reject sla_track example/repo "$fp" HIGH 'Fix advisory' ''
check test ! -f "$fixture_dir/creates"
sla_track example/repo "$fp" HIGH 'Fix advisory' 'base abc lockfile ADV-1' > "$fixture_dir/first"
check test "$(wc -l < "$fixture_dir/creates" | tr -d ' ')" = 1
check jq -e '.body | contains("Due: 2026-01-31") and contains("SLA days: 30")' "$fixture_dir/first"
DAYS_OVERRIDE=99 sla_track example/repo "$fp" HIGH 'Another PR' 'base def lockfile ADV-1' > "$fixture_dir/repeat"
check cmp "$fixture_dir/first" "$fixture_dir/repeat"
check test "$(wc -l < "$fixture_dir/creates" | tr -d ' ')" = 1
check sla_release_check example/repo owner 2026-01-31
check reject sla_release_check example/repo owner 2026-02-01
# A marker must be a full line, from the owner, on the issue.
echo '[[{"body":"Risk accepted by owner: scheduled repair","user":{"login":"author"}}]]' > "$fixture_dir/comments"
check reject sla_release_check example/repo owner 2026-02-01
echo '[[{"body":"> Risk accepted by owner: scheduled repair","user":{"login":"owner"}}]]' > "$fixture_dir/comments"
check reject sla_release_check example/repo owner 2026-02-01
echo '[[{"body":"Risk accepted by owner: ","user":{"login":"owner"}}]]' > "$fixture_dir/comments"
check reject sla_release_check example/repo owner 2026-02-01
# Acceptance on a later page must count.
echo '[[],[{"body":"Risk accepted by owner: scheduled repair","user":{"login":"owner"}}]]' > "$fixture_dir/comments"
check sla_release_check example/repo owner 2026-02-01
touch "$fixture_dir/closed"
check sla_release_check example/repo owner 2026-02-01
rm "$fixture_dir/closed"
touch "$fixture_dir/list-error"
check reject sla_track example/repo "$fp" HIGH 'Fix' 'base proof'
check reject sla_release_check example/repo owner 2026-02-01
rm "$fixture_dir/list-error"
LIST_STATUS=TRUNCATED
check reject sla_release_check example/repo owner 2026-02-01
unset LIST_STATUS
touch "$fixture_dir/api-error"
check reject sla_release_check example/repo owner 2026-02-01
rm "$fixture_dir/api-error"
# A partial creation remains unique and blocks release.
rm "$fixture_dir/issue"
touch "$fixture_dir/update-error"
check reject sla_track example/repo "$fp" HIGH Fix 'base abc lockfile ADV-1'
check reject sla_release_check example/repo owner 2026-02-01
sla_track example/repo "$fp" HIGH Fix 'base abc lockfile ADV-1' > "$fixture_dir/pending"
check test "$(wc -l < "$fixture_dir/creates" | tr -d ' ')" = 2
check jq -e '.body | contains("Due: pending")' "$fixture_dir/pending"
# Security presentation checks reject missing proof and missing fingerprint.
parser="$root/.claude/skills/code-review/check-review-body.sh"
line="- Pre-existing: Advisory. Suggested ticket title: Repair. Severity: HIGH. SLA: 30 days. Due: 2026-01-31. Fingerprint: $fp | Base proof: abc lockfile ADV-1"
printf '%s\n' "$line" > "$fixture_dir/review"
check bash "$parser" --security "$fixture_dir/review"
printf '%s\n' "${line%% | Base proof:*}" > "$fixture_dir/review"
check reject bash "$parser" --security "$fixture_dir/review"
printf '%s\n' "${line%% Fingerprint:*} Base proof: abc lockfile ADV-1" > "$fixture_dir/review"
check reject bash "$parser" --security "$fixture_dir/review"
for severity in CRITICAL HIGH MEDIUM; do
  printf '%s\n' "- Pre-existing: Advisory. Suggested ticket title: Repair. Severity: $severity. SLA: 30 days. Due: 2020-01-31. Fingerprint: $fp" > "$fixture_dir/review"
  check reject bash "$parser" --security "$fixture_dir/review"
  printf '%s\n' "- Pre-existing: Advisory. Suggested ticket title: Repair. Severity: $severity. SLA: 30 days. Due: 2020-01-31. Fingerprint: $fp | Base proof: abc lockfile ADV-1" > "$fixture_dir/review"
  check bash "$parser" --security "$fixture_dir/review"
done
# Invalid records fail closed, even with an owner's risk acceptance.
jq '.body |= sub("Due: pending"; "Due: 2026-02-30")' "$fixture_dir/issue" > "$fixture_dir/invalid"
mv "$fixture_dir/invalid" "$fixture_dir/issue"
check reject sla_release_check example/repo owner 2026-03-01
# Unsupported adapters must not create a record they cannot finalize.
rm "$fixture_dir/issue"
FAKE_KIND=none
check reject sla_track example/repo "$fp" HIGH Fix 'base abc lockfile ADV-1'
check test "$(wc -l < "$fixture_dir/creates" | tr -d ' ')" = 2
check reject bash "$root/bin/check-security-sla.sh"
check grep -qF 'bash bin/check-security-sla.sh me2resh/apexyard me2resh' "$root/.claude/skills/release/SKILL.md"
echo "PASS: $count SLA rows"
