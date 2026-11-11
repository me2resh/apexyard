#!/usr/bin/env bash
# test_check_traceability.sh — tests for bin/check-traceability.sh.
#
# Asserts:
#   (1)  no --prd is a usage error (exit 2)
#   (2)  a clean PRD passes the PRD-only check (exit 0)
#   (3)  a user story with no FR is a BLOCK
#   (4)  an FR that serves an unknown story is a BLOCK
#   (5)  a requirements table with no Serves column is a WARN, not a BLOCK
#   (6)  a design that serves every story and FR passes
#   (7)  a design that misses a story is a BLOCK for the story and its FR
#   (8)  a task that serves an unknown ID is a BLOCK
#   (9)  a design with no Serves column falls back to IDs in the task row
#   (10) PRD drift (me2resh/apexyard#1749): US-4 added on the base branch
#        after the design branch was cut. Without --base the check reads
#        the branch copy and passes. With --base it reports BLOCK for US-4
#        and WARN for the PRD version.
#   (11) a matching PRD version passes, a missing one is a WARN
#   (12) a branch that changes the PRD itself reads the working copy
#   (13) an unknown --base ref is an input error (exit 2)
#   (14) ORBIT: a mapped criterion in no slice is a BLOCK, all in slices
#        passes, and no traceability table skips the ORBIT checks
#   (15) a PRD with CRLF line endings parses
#   (16) a PRD path that is a symbolic link is a WARN
#   (17) a PRD version that is not a commit SHA is a WARN that does not
#        print the design's token
#   (18) a branch that changes the PRD and the design together compares
#        the PRD version with HEAD, not the base, and warns when the base
#        also changed the PRD
#
# Usage: bash .claude/hooks/tests/test_check_traceability.sh
# Exit 0 on pass, 1 on any failure.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/bin/check-traceability.sh"

FAIL=0
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

assert_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then
    green "  PASS: $3"
  else
    red "  FAIL: $3"; echo "    expected: $2"; echo "    got: $1"; FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then
    red "  FAIL: $3"; echo "    did not expect: $2"; echo "    got: $1"; FAIL=$((FAIL + 1))
  else
    green "  PASS: $3"
  fi
}

assert_exit() {
  if [ "$1" = "$2" ]; then
    green "  PASS: $3"
  else
    red "  FAIL: $3 (expected exit $2, got $1)"; FAIL=$((FAIL + 1))
  fi
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t trace)
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "cannot create a temp directory"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

OUT="" RC=0
run() { OUT=$(bash "$SCRIPT" "$@" 2>&1); RC=$?; }

git_q() { git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@" >/dev/null 2>&1; }

# write_prd FILE STORIES FR_ROWS [HEADER]
# STORIES: space-separated numbers. FR_ROWS: lines "FR-n|US-n".
write_prd() {
  local file="$1" stories="$2" rows="$3" header="${4:-| ID | Requirement | Serves | Priority |}"
  {
    echo "# PRD: Invoices"
    echo
    echo "## User Stories"
    for n in $stories; do
      echo
      echo "### US-$n: Story $n"
      echo
      echo "> As an accountant, I want story $n, so that it works."
    done
    echo
    echo "## Requirements"
    echo
    echo "### Functional Requirements"
    echo
    echo "$header"
    echo "|----|-------------|--------|----------|"
    printf '%s\n' "$rows" | while IFS='|' read -r fr us; do
      [ -n "$fr" ] || continue
      case "$header" in
        *Serves*) echo "| $fr | Requirement $fr | $us | Must |" ;;
        *)        echo "| $fr | Requirement $fr | Must |" ;;
      esac
    done
  } > "$file"
}

# write_design FILE TASK_ROWS [VERSION] [HEADER]
# TASK_ROWS: lines "n|serves". VERSION: value for **PRD version**, or "".
write_design() {
  local file="$1" rows="$2" version="${3:-}" header="${4:-| # | Task | Serves | Estimate | Dependencies |}"
  {
    echo "# Technical Design: Invoices"
    echo
    echo "**PRD**: prd.md"
    [ -n "$version" ] && echo "**PRD version**: $version"
    echo
    echo "## Implementation Plan"
    echo
    echo "### Tasks"
    echo
    echo "$header"
    echo "|---|------|--------|----------|--------------|"
    printf '%s\n' "$rows" | while IFS='|' read -r n serves; do
      [ -n "$n" ] || continue
      case "$header" in
        *Serves*) echo "| $n | Task $n | $serves | 2h | - |" ;;
        *)        echo "| $n | Task $n for $serves | 2h | - |" ;;
      esac
    done
    echo
    echo "## Risks & Mitigations"
  } > "$file"
}

FR3='FR-1|US-1
FR-2|US-2
FR-3|US-3'
TASKS3='1|US-1, FR-1
2|US-2, FR-2
3|US-3, FR-3'

echo "Test 1: usage error"
run
assert_exit "$RC" 2 "no --prd exits 2"

echo "Test 2: clean PRD"
write_prd "$TMP/prd.md" "1 2 3" "$FR3"
run --prd "$TMP/prd.md"
assert_exit "$RC" 0 "clean PRD exits 0"
assert_contains "$OUT" "every user story has a functional requirement (3/3)" "story coverage passes"
assert_contains "$OUT" "Result: 0 BLOCK, 0 WARN" "no findings"

echo "Test 3: story with no FR"
write_prd "$TMP/prd.md" "1 2 3" 'FR-1|US-1
FR-2|US-2'
run --prd "$TMP/prd.md"
assert_exit "$RC" 1 "missing FR exits 1"
assert_contains "$OUT" "BLOCK: US-3 has no functional requirement" "US-3 reported"

echo "Test 4: FR serves an unknown story"
write_prd "$TMP/prd.md" "1 2" 'FR-1|US-1
FR-2|US-9'
run --prd "$TMP/prd.md"
assert_contains "$OUT" "BLOCK: FR-2 serves US-9, which is not in the PRD" "unknown story reported"

echo "Test 5: no Serves column in the PRD"
write_prd "$TMP/prd.md" "1 2 3" "$FR3" "| ID | Requirement | Priority |"
run --prd "$TMP/prd.md"
assert_exit "$RC" 0 "no Serves column exits 0"
assert_contains "$OUT" "WARN:  the requirements table has no Serves column" "WARN explains the skip"

echo "Test 6: design serves everything"
write_prd "$TMP/prd.md" "1 2 3" "$FR3"
write_design "$TMP/design.md" "$TASKS3"
run --prd "$TMP/prd.md" --design "$TMP/design.md"
assert_exit "$RC" 0 "full coverage exits 0"
assert_contains "$OUT" "every user story and requirement is served by an Implementation Plan task" "coverage passes"

echo "Test 7: design misses a story"
write_design "$TMP/design.md" '1|US-1, FR-1
3|US-3, FR-3'
run --prd "$TMP/prd.md" --design "$TMP/design.md"
assert_exit "$RC" 1 "missing story exits 1"
assert_contains "$OUT" "BLOCK: US-2 is not served by any Implementation Plan task" "US-2 reported"
assert_contains "$OUT" "BLOCK: FR-2 is not served by any Implementation Plan task" "FR-2 reported"

echo "Test 8: task serves an unknown ID"
write_design "$TMP/design.md" "$TASKS3
4|US-7"
run --prd "$TMP/prd.md" --design "$TMP/design.md"
assert_contains "$OUT" "BLOCK: task 4 serves US-7, which is not in the PRD" "unknown ID reported"

echo "Test 9: design with no Serves column"
write_design "$TMP/design.md" '1|FR-1
2|FR-2' "" "| # | Task | Estimate | Dependencies |"
run --prd "$TMP/prd.md" --design "$TMP/design.md"
assert_contains "$OUT" "the Implementation Plan has no Serves column" "WARN explains the fallback"
assert_contains "$OUT" "BLOCK: US-3 is not served by any Implementation Plan task" "fallback still finds the gap"
assert_not_contains "$OUT" "BLOCK: US-1 " "fallback counts FR-1 for US-1"

echo "Test 10: PRD drift across branches (#1749)"
R="$TMP/repo"
mkdir -p "$R/prds" "$R/designs"
git_q init -q "$R"
git_q -C "$R" checkout -q -b dev
write_prd "$R/prds/invoices.md" "1 2 3" "$FR3"
git_q -C "$R" add prds/invoices.md
git_q -C "$R" commit -q -m "docs: PRD US-1..US-3"
v1=$(git -C "$R" rev-parse --short HEAD)
git_q -C "$R" checkout -q -b feature/design
write_design "$R/designs/invoices-design.md" "$TASKS3" "$v1"
git_q -C "$R" add designs/invoices-design.md
git_q -C "$R" commit -q -m "docs: design"
git_q -C "$R" checkout -q dev
write_prd "$R/prds/invoices.md" "1 2 3 4" "$FR3
FR-4|US-4"
git_q -C "$R" commit -q -am "docs: add US-4"
git_q -C "$R" checkout -q feature/design
run --prd "$R/prds/invoices.md" --design "$R/designs/invoices-design.md"
assert_exit "$RC" 0 "without --base the branch copy hides US-4"
run --prd "$R/prds/invoices.md" --design "$R/designs/invoices-design.md" --base dev
assert_exit "$RC" 1 "with --base the check exits 1"
assert_contains "$OUT" "Checking PRD: $R/prds/invoices.md (dev)" "PRD read from dev"
assert_contains "$OUT" "BLOCK: US-4 is not served by any Implementation Plan task" "US-4 reported"
assert_contains "$OUT" "BLOCK: FR-4 is not served by any Implementation Plan task" "FR-4 reported"
assert_contains "$OUT" "WARN:  the PRD changed since this design was written (design: $v1, dev:" "PRD version drift reported"

echo "Test 11: PRD version matches, then missing"
v2=$(git -C "$R" log -1 --format=%h dev -- prds/invoices.md)
write_design "$R/designs/invoices-design.md" "$TASKS3
4|US-4, FR-4" "$v2"
run --prd "$R/prds/invoices.md" --design "$R/designs/invoices-design.md" --base dev
assert_exit "$RC" 0 "updated design exits 0"
assert_contains "$OUT" "PASS:  the design PRD version matches the PRD on dev" "matching version passes"
write_design "$R/designs/invoices-design.md" "$TASKS3
4|US-4, FR-4"
run --prd "$R/prds/invoices.md" --design "$R/designs/invoices-design.md" --base dev
assert_contains "$OUT" "WARN:  the design has no PRD version field" "missing version is a WARN"

echo "Test 12: the branch changes the PRD itself"
write_prd "$R/prds/invoices.md" "1 2 3 5" "$FR3
FR-5|US-5"
run --prd "$R/prds/invoices.md" --base dev
assert_contains "$OUT" "this branch changes the PRD, so the check reads the working copy" "branch copy used"
assert_contains "$OUT" "every user story has a functional requirement (4/4)" "branch stories counted"
git -C "$R" checkout -q -- prds/invoices.md

echo "Test 13: unknown base ref"
run --prd "$R/prds/invoices.md" --base no-such-branch
assert_exit "$RC" 2 "unknown ref exits 2"
assert_contains "$OUT" "base ref not found: no-such-branch" "error names the ref"

echo "Test 14: ORBIT traceability"
if command -v jq >/dev/null 2>&1; then
  O="$TMP/orbit"
  mkdir -p "$O/plans" "$O/slices"
  cat > "$O/plans/plan-x.r1.json" <<'JSON'
{"id":"plan-x","acceptanceCriteria":[{"id":"ac1-1"},{"id":"ac2-1"},{"id":"ac2-2"}]}
JSON
  cat > "$O/slices/slice-x-o1.json" <<'JSON'
{"id":"slice-x-o1","contributesTo":["ac1-1","ac2-1"]}
JSON
  write_prd "$TMP/prd.md" "1 2" 'FR-1|US-1
FR-2|US-2'
  cat >> "$TMP/prd.md" <<'MD'

## Traceability

| Story | ORBIT criteria |
|-------|----------------|
| US-1 | ac1-1 |
| US-2 | ac2-1, ac2-2 |
MD
  run --prd "$TMP/prd.md" --orbit "$O"
  assert_exit "$RC" 1 "criterion in no slice exits 1"
  assert_contains "$OUT" "BLOCK: ac2-2 (US-2) is in no ORBIT slice's contributesTo" "ac2-2 reported"
  cat > "$O/slices/slice-x-o2.json" <<'JSON'
{"id":"slice-x-o2","contributesTo":["ac2-2"]}
JSON
  run --prd "$TMP/prd.md" --orbit "$O"
  assert_exit "$RC" 0 "all criteria in slices exits 0"
  assert_contains "$OUT" "every mapped ORBIT criterion is in a slice" "ORBIT coverage passes"
  write_prd "$TMP/prd.md" "1 2" 'FR-1|US-1
FR-2|US-2'
  run --prd "$TMP/prd.md" --orbit "$O"
  assert_exit "$RC" 0 "no traceability table exits 0"
  assert_contains "$OUT" "no traceability table in the PRD, so the ORBIT checks are skipped" "ORBIT skipped"
else
  echo "  SKIP: jq not installed"
fi

echo "Test 15: CRLF line endings"
write_prd "$TMP/prd.md" "1 2 3" "$FR3"
awk '{ printf "%s\r\n", $0 }' "$TMP/prd.md" > "$TMP/prd-crlf.md"
run --prd "$TMP/prd-crlf.md"
assert_exit "$RC" 0 "CRLF PRD exits 0"
assert_contains "$OUT" "(3/3)" "CRLF stories counted"

echo "Test 16: symbolic link PRD"
write_prd "$TMP/prd.md" "1 2 3" "$FR3"
ln -s "$TMP/prd.md" "$TMP/prd-link.md"
run --prd "$TMP/prd-link.md"
assert_exit "$RC" 0 "symbolic link PRD exits 0"
assert_contains "$OUT" "WARN:  the PRD path is a symbolic link" "symbolic link reported"

echo "Test 17: PRD version is not a commit SHA"
write_design "$TMP/design.md" "$TASKS3" "NOT-A-SHA-TOKEN"
run --prd "$TMP/prd.md" --design "$TMP/design.md"
assert_contains "$OUT" "WARN:  the design PRD version is not a commit SHA" "non-SHA version reported"
assert_not_contains "$OUT" "NOT-A-SHA-TOKEN" "the design token is not printed"

echo "Test 18: branch changes the PRD and the design together"
git_q -C "$R" checkout -q feature/design
write_prd "$R/prds/invoices.md" "1 2 3 5" "$FR3
FR-5|US-5"
git_q -C "$R" commit -q -am "docs: add US-5 on the branch"
v5=$(git -C "$R" log -1 --format=%h HEAD -- prds/invoices.md)
write_design "$R/designs/invoices-design.md" "$TASKS3
5|US-5, FR-5" "$v5"
run --prd "$R/prds/invoices.md" --design "$R/designs/invoices-design.md" --base dev
assert_contains "$OUT" "this branch changes the PRD, so the check reads the working copy" "branch copy used"
assert_contains "$OUT" "WARN:  the PRD also changed on dev since this branch started" "base change reported"
assert_contains "$OUT" "PASS:  the design PRD version matches the PRD on HEAD" "version compared with HEAD"
assert_not_contains "$OUT" "the PRD changed since this design was written" "no false drift WARN"
assert_not_contains "$OUT" "BLOCK: task 5 serves US-5" "branch story is known"

echo
if [ "$FAIL" -eq 0 ]; then
  green "All check-traceability tests passed."
  exit 0
fi
red "$FAIL check-traceability test(s) failed."
exit 1
