#!/usr/bin/env bash
set -eu
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
root=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
count=0
check() {
  count=$((count + 1))
  if ! "$@"; then echo "FAIL row $count"; exit 1; fi
}
body() {
  printf 'Not covered by the checks: None\nImportant 2 | Nit %s | Pre-existing 0\n' "$1" > "$tmp/body"
  i=0
  while [ "$i" -lt "$2" ]; do echo '- Nit: name is unclear' >> "$tmp/body"; i=$((i+1)); done
  [ "$3" = none ] || echo "Additional nits: $3" >> "$tmp/body"
}
parser="$root/.claude/skills/code-review/check-review-body.sh"
body 0 0 none; check bash "$parser" "$tmp/body"
body 5 5 none; check bash "$parser" "$tmp/body"
body 7 5 2; check bash "$parser" "$tmp/body"
body 6 6 none; check test "$(bash "$parser" "$tmp/body" 2>/dev/null; echo $?)" = 1
body 7 5 1; check test "$(bash "$parser" "$tmp/body" 2>/dev/null; echo $?)" = 1
printf 'Blocking 0 | Important 0 | Nits 0\n' > "$tmp/body"
check test "$(bash "$parser" "$tmp/body" 2>/dev/null; echo $?)" = 1
body 7 5 2; echo 'Additional nits: 0' >> "$tmp/body"
check test "$(bash "$parser" "$tmp/body" 2>/dev/null; echo $?)" = 1
# Check the shared contract and all reviewer entry points.
for file in .claude/agents/code-reviewer.md .claude/agents/security-reviewer.md \
  .claude/agents/solution-architect.md .claude/skills/code-review/SKILL.md \
  .claude/skills/security-review/SKILL.md .claude/skills/design-review/SKILL.md; do
  check grep -qF 'Give each finding exactly one tag: `Important`, `Nit`, or `Pre-existing`.' "$root/$file"
  check grep -qF 'Only `Important` findings can cause `CHANGES REQUESTED`' "$root/$file"
  check grep -qF '`Nit` and `Pre-existing` findings never block the PR.' "$root/$file"
  check grep -qF 'Each `Pre-existing` finding includes base evidence and a suggested ticket title.' "$root/$file"
done
check grep -qF 'Android unit tests already fail on the base' "$root/templates/REVIEW.md"
check grep -qF 'A withdrawn audit advisory predates this change' "$root/templates/REVIEW.md"
check grep -qF 'Do not classify a new exposure or regression as Pre-existing.' "$root/templates/REVIEW.md"
body 0 0 none
sed 's/Pre-existing 0/Pre-existing 1/' "$tmp/body" > "$tmp/pre-existing"
echo '- Pre-existing: Old tests fail on the base. Suggested ticket title: Repair old tests' >> "$tmp/pre-existing"
check bash "$parser" "$tmp/pre-existing"
sed 's/Pre-existing 0/Pre-existing 1/' "$tmp/body" > "$tmp/pre-existing"
echo '- Pre-existing: Old tests fail on the base.' >> "$tmp/pre-existing"
check test "$(bash "$parser" "$tmp/pre-existing" 2>/dev/null; echo $?)" = 1
sed 's/Pre-existing 0/Pre-existing 2/' "$tmp/body" > "$tmp/pre-existing"
check test "$(bash "$parser" "$tmp/pre-existing" 2>/dev/null; echo $?)" = 1
sla='A Pre-existing security finding does not block the PR. It gets a ticket due on its first-seen date plus its SLA (`.security.remediation_sla_days`: CRITICAL 7 days, HIGH 30 days, MEDIUM 90 days, LOW no SLA). It blocks a release only after the SLA is breached. The review names the severity, the SLA and the due date. Tracking: me2resh/apexyard#2109.'
for file in .claude/agents/security-reviewer.md .claude/skills/security-review/SKILL.md templates/REVIEW.md; do
  check grep -qF "$sla" "$root/$file"
done
check jq -e '.security.remediation_sla_days | .critical == 7 and .high == 30 and .medium == 90 and .low == null' "$root/.claude/project-config.defaults.json"
# A Pre-existing security finding must state severity, SLA and due date.
body 0 0 none
sed 's/Pre-existing 0/Pre-existing 1/' "$tmp/body" > "$tmp/sec"
echo '- Pre-existing: HIGH SQL injection on the base. Suggested ticket title: Fix SQL injection. Severity: HIGH. SLA: 30 days. Due: 2099-12-21' >> "$tmp/sec"
check bash "$parser" "$tmp/sec"
check bash "$parser" --security "$tmp/sec"
# One Pre-existing line per case: lower-case severity, wrong SLA, past date, bad format, bad calendar date.
secline() {
  printf 'Not covered by the checks: None\nImportant 0 | Nit 0 | Pre-existing 1\n- Pre-existing: %s Suggested ticket title: Fix it\n' "$1" > "$tmp/sec"
}
secline 'high finding on the base. SLA: 30 days. Due: 2099-12-21'; check bash "$parser" "$tmp/sec"
secline 'critical finding on the base. SLA: 7 days. Due: 2099-12-21'; check bash "$parser" "$tmp/sec"
secline 'medium finding on the base. SLA: 90 days. Due: 2099-12-21'; check bash "$parser" --security "$tmp/sec"
secline 'high finding on the base. SLA: 7 days. Due: 2099-12-21'; check test "$(bash "$parser" "$tmp/sec" 2>/dev/null; echo $?)" = 1
secline 'critical finding on the base. SLA: 30 days. Due: 2099-12-21'; check test "$(bash "$parser" "$tmp/sec" 2>/dev/null; echo $?)" = 1
secline 'High finding on the base. SLA: 30 days. Due: 2020-01-01'; check test "$(bash "$parser" "$tmp/sec" 2>/dev/null; echo $?)" = 1
secline 'High finding on the base. SLA: 30 days. Due: 21-12-2099'; check test "$(bash "$parser" "$tmp/sec" 2>/dev/null; echo $?)" = 1
secline 'High finding on the base. SLA: 30 days. Due: 2099-02-30'; check test "$(bash "$parser" "$tmp/sec" 2>/dev/null; echo $?)" = 1
secline 'High finding on the base. SLA: 30 days. Due: 2099-13-01'; check test "$(bash "$parser" --security "$tmp/sec" 2>/dev/null; echo $?)" = 1
check grep -qF 'config_get_or' "$parser"
check grep -qF 'check-review-body.sh --security' "$root/.claude/agents/security-reviewer.md"
check grep -qF 'the finding reproduces on the PR base commit' "$root/templates/REVIEW.md"
sed 's/Pre-existing 0/Pre-existing 1/' "$tmp/body" > "$tmp/sec"
echo '- Pre-existing: HIGH SQL injection on the base. Suggested ticket title: Fix SQL injection.' >> "$tmp/sec"
check test "$(bash "$parser" "$tmp/sec" 2>/dev/null; echo $?)" = 1
preview="$root/.claude/skills/drive-to-green/dry-run.sh"
printf 'changes\napproved\n' > "$tmp/state"
bash "$preview" --dry-run "$tmp/state" > "$tmp/out"
check grep -q 'build agent fixes and tests' "$tmp/out"
check grep -q 'Pending: human approval' "$tmp/out"
bash "$preview" --dry-run "$tmp/state" 1 > "$tmp/out"
check grep -q 'Blocker: review-round cap' "$tmp/out"
check test "$(grep -c 'build agent' "$tmp/out" || :)" = 0
for state in pending failed carry unknown; do
  echo "$state" > "$tmp/state"
  bash "$preview" --dry-run "$tmp/state" > "$tmp/out"
  case "$state" in
    pending) check grep -q 'Blocker: CI pending' "$tmp/out" ;;
    failed) check grep -q 'build agent fixes CI' "$tmp/out" ;;
    carry) check grep -q 'rex_approval_carries_over -> true' "$tmp/out" ;;
    unknown) check grep -q '/code-review delta review' "$tmp/out" ;;
  esac
done
check test "$(bash "$preview" --dry-run "$tmp/state" invalid 2>/dev/null; echo $?)" = 2
echo "PASS: $count rows"
