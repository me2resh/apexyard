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
  printf 'Not covered by the checks: None\nBlocking 0 | Important 2 | Nits %s\n' "$1" > "$tmp/body"
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
