#!/bin/bash
# Base check fixtures use only a small fake command.
set -Eeuo pipefail
trap 'printf "FAIL line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
ROOT=$(cd "$(dirname "$0")/../../.." && pwd -P)
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
# shellcheck source=/dev/null
. "$ROOT/.claude/hooks/_lib-progress-note.sh"
# shellcheck source=/dev/null
. "$ROOT/.claude/hooks/_lib-baseline.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/tree"
git -C "$TMP/tree" init -q
printf 'unchanged\n' > "$TMP/tree/input"
printf '.claude/worktrees/\n' > "$TMP/tree/.gitignore"
git -C "$TMP/tree" add input .gitignore
git -C "$TMP/tree" -c user.name=Test -c user.email=test@example.test commit -qm fixture
sha=$(git -C "$TMP/tree" rev-parse HEAD)
printf 'edited\n' > "$TMP/tree/input"
# Fixture config replaces only the reader, never the check runner.
config_get_or() {
  case "$1" in
    .checks.baseline_command) printf '%s' "$fake_command" ;;
    .checks.baseline_mode) printf '%s' "$fake_mode" ;;
    .checks.baseline_timeout_seconds) printf '%s' 1 ;;
  esac
}
number=0
run_case() {
  number=$((number + 1))
  printf 'repo=owner/repo\nnumber=%s\n' "$number" > "$TMP/tree/.git/apexyard-ticket"
  baseline_check "$TMP/tree" > "$TMP/out" 2>&1
}
note="$TMP/tree/.git/apexyard-progress.md"
fake_mode=warn
# The check expands this expression in its own working directory.
# shellcheck disable=SC2016
fake_command='test "$(cat input)" = unchanged'
run_case
grep -q "base_sha=$sha; base_result=pass" "$note"
fake_command="echo run >> '$TMP/counter'; echo FAIL: first-check; echo FAIL: second-check; exit 1"
run_case
grep -q 'base_result=fail; first_failing_check=first-check' "$note"
[ "$(grep -c WARN "$TMP/out")" = 1 ]
grep -q pre-existing "$TMP/out"
# Repeating a start must not execute the check again.
baseline_check "$TMP/tree"
grep -q 'base_result=fail' "$note"
[ "$(wc -l < "$TMP/counter" | tr -d ' ')" = 1 ]
fake_command=''
run_case
grep -q 'base_result=not configured' "$note"
[ "$(wc -l < "$TMP/out" | tr -d ' ')" = 1 ]
fake_command='sleep 20'
run_case
grep -q 'base_result=timed out' "$note"
fake_mode=refuse
fake_command='echo FAIL: refused-check; exit 1'
if run_case; then exit 1; fi
grep -q 'base_result=fail; first_failing_check=refused-check' "$note"
if baseline_check "$TMP/tree"; then exit 1; fi
fake_command='sleep 20'
if run_case; then exit 1; fi
grep -q 'base_result=timed out' "$note"
[ "$(git -C "$TMP/tree" worktree list --porcelain | grep -c '^worktree ')" = 1 ]
[ "$(cat "$TMP/tree/input")" = edited ]
# A managed project's committed config must never supply executable settings.
(
  # shellcheck source=/dev/null
  . "$ROOT/.claude/hooks/_lib-read-config.sh"
  mkdir -p "$TMP/ops/.claude" "$TMP/tree/.claude"
  touch "$TMP/ops/.apexyard-fork"
  cp "$ROOT/.claude/project-config.defaults.json" "$TMP/ops/.claude/"
  jq -n --arg cmd "touch '$TMP/hostile-ran'" '{checks:{baseline_command:$cmd,baseline_mode:"refuse"}}' > "$TMP/tree/.claude/project-config.json"
  git -C "$TMP/tree" add .claude/project-config.json
  git -C "$TMP/tree" -c user.name=Test -c user.email=test@example.test commit -qm config
  mv "$TMP/tree" "$TMP/ops/project"
  tree="$TMP/ops/project"
  note="$tree/.git/apexyard-progress.md"
  # Start from the managed tree, with a stale project config cache too.
  cd "$tree"
  _CONFIG_ROOT_CACHE="$tree"
  _CONFIG_CACHE=$(cat .claude/project-config.json)
  printf 'repo=owner/repo\nnumber=8\n' > .git/apexyard-ticket
  baseline_check "$tree" > "$TMP/out" 2>&1
  grep -q 'base_result=not configured' "$note"
  [ ! -e "$TMP/hostile-ran" ]
  jq -n --arg cmd "touch '$TMP/operator-ran'" '{checks:{baseline_command:$cmd}}' > "$TMP/ops/.claude/project-config.json"
  printf 'repo=owner/repo\nnumber=9\n' > .git/apexyard-ticket
  baseline_check "$tree" > "$TMP/out" 2>&1
  grep -q 'base_result=pass' "$note"
  [ -f "$TMP/operator-ran" ]
  [ ! -e "$TMP/hostile-ran" ]
)
# Missing python3 is setup evidence, even in refuse mode.
(
  fake_mode=refuse
  fake_command='exit 1'
  # shellcheck disable=SC2329
  command() {
    if [ "$*" = '-v python3' ]; then return 1; fi
    builtin command "$@"
  }
  printf 'repo=owner/repo\nnumber=10\n' > "$TMP/ops/project/.git/apexyard-ticket"
  baseline_check "$TMP/ops/project" > "$TMP/out" 2>&1
  grep -q 'base_result=not run; first_failing_check=python3 unavailable' "$TMP/ops/project/.git/apexyard-progress.md"
  [ "$(grep -c WARN "$TMP/out")" = 1 ]
)
# A note update failure allows a warn-mode start after the command ran.
(
  fake_mode=warn
  fake_command="touch '$TMP/check-ran'"
  # shellcheck disable=SC2329
  progress_note_update() { return 1; }
  printf 'repo=owner/repo\nnumber=11\n' > "$TMP/ops/project/.git/apexyard-ticket"
  baseline_check "$TMP/ops/project" > "$TMP/out" 2>&1
  [ -f "$TMP/check-ran" ]
  [ "$(grep -c WARN "$TMP/out")" = 1 ]
  grep -q 'evidence not recorded' "$TMP/out"
)
# A setup failure allows a warn-mode start too.
(
  fake_mode=warn
  fake_command='exit 0'
  # shellcheck disable=SC2329
  mkdir() {
    case "$*" in *worktrees*) return 1 ;; esac
    builtin command mkdir "$@"
  }
  printf 'repo=owner/repo\nnumber=12\n' > "$TMP/ops/project/.git/apexyard-ticket"
  baseline_check "$TMP/ops/project" > "$TMP/out" 2>&1
  [ "$(grep -c WARN "$TMP/out")" = 1 ]
  grep -q 'could not run' "$TMP/out"
)
# Both ticket-start routes and builder instructions use the shared evidence.
# shellcheck disable=SC2016
grep -q 'baseline_check "$tree"' "$ROOT/bin/apexyard-start-ticket"
# shellcheck disable=SC2016
grep -q 'baseline_check "$tree"' "$ROOT/.claude/skills/start-ticket/SKILL.md"
for file in .claude/skills/fan-out/SKILL.md .claude/rules/reconcile-before-build.md; do
  # shellcheck disable=SC2016
  grep -q 'Read `<tree git dir>/apexyard-progress.md`' "$ROOT/$file"
  grep -q 'Run the full project check command before you push' "$ROOT/$file"
done
grep -q 'State whether the same failure was already on the base' "$ROOT/.claude/agents/code-reviewer.md"
printf 'PASS: 12 base check cases\n'
