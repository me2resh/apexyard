#!/bin/bash
# Regression tests for the explicit tracker-repository guard (#1268).

set -u
SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="$SRC_ROOT/.claude/hooks/block-ambient-tracker-repo.sh"
PASS=0
FAIL=0

run_case() {
  local name="$1" expected="$2" command="$3" root="$4" rc
  rc=0
  (cd "$root" && printf '%s' "{\"tool_input\":{\"command\":$(printf '%s' "$command" | jq -Rs .)}}" | "$HOOK" >/tmp/ambient-tracker.out 2>&1) || rc=$?
  if [ "$rc" -eq "$expected" ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected $expected, got $rc)" >&2
    cat /tmp/ambient-tracker.out >&2
    FAIL=$((FAIL + 1))
  fi
}

make_repo() {
  local root="$1" origin="$2"
  mkdir -p "$root/.claude/session/tickets"
  : > "$root/.apexyard-fork"
  git init -q "$root"
  git -C "$root" remote add origin "$origin"
}

root=$(mktemp -d)
make_repo "$root" "git@github.com:owner/framework.git"
printf '%s\n' 'repo=owner/project' > "$root/.claude/session/tickets/demo"
run_case 'unqualified issue lookup is blocked for a different active repo' 2 'gh issue view 42' "$root"
run_case 'explicit issue repo is allowed' 0 'gh issue view 42 --repo owner/project' "$root"
run_case 'explicit short repo flag is allowed' 0 'gh pr list -R owner/project' "$root"

matching=$(mktemp -d)
make_repo "$matching" "git@github.com:owner/project.git"
printf '%s\n' 'repo=owner/project' > "$matching/.claude/session/tickets/demo"
run_case 'matching checkout origin keeps ambient lookup available' 0 'gh issue view 42' "$matching"

empty=$(mktemp -d)
make_repo "$empty" "git@github.com:owner/framework.git"
run_case 'no active repo marker leaves unrelated commands unchanged' 0 'gh issue view 42' "$empty"

multiple=$(mktemp -d)
make_repo "$multiple" "git@github.com:owner/framework.git"
printf '%s\n' 'repo=owner/project-a' > "$multiple/.claude/session/tickets/a"
printf '%s\n' 'repo=owner/project-b' > "$multiple/.claude/session/tickets/b"
run_case 'multiple active repos require an explicit target' 2 'gh pr list' "$multiple"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
