#!/usr/bin/env bash
# Tests for bin/release-list-removed-lines.sh (#1490 / AgDR-0197).
#
# Strategy: create a temporary git repo with a main tip that holds a line,
# a release tip that deletes it, then assert the helper lists that exact
# deleted line. Never touches the framework worktree's own git history.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/_test-session-isolation.sh"


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/../../../bin" && pwd)"
LIST_SCRIPT="$BIN_DIR/release-list-removed-lines.sh"

pass=0; fail=0

eq() {
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
    pass=$((pass + 1))
  else
    echo "  FAIL: $1"
    echo "       expected: [$2]"
    echo "       got:      [$3]"
    fail=$((fail + 1))
  fi
}

contains() {
  if echo "$3" | grep -qF -- "$2"; then
    echo "  ok: $1"
    pass=$((pass + 1))
  else
    echo "  FAIL: $1 — expected to find [$2] in output"
    echo "  Output was:"
    echo "$3" | head -20 | sed 's/^/    /'
    fail=$((fail + 1))
  fi
}

not_contains() {
  if ! echo "$3" | grep -qF -- "$2"; then
    echo "  ok: $1"
    pass=$((pass + 1))
  else
    echo "  FAIL: $1 — expected NOT to find [$2] in output"
    echo "  Offending line:"
    echo "$3" | grep -F -- "$2" | head -3 | sed 's/^/    /'
    fail=$((fail + 1))
  fi
}

run_test() {
  local tmpdir root
  root="$(cd "$SCRIPT_DIR/../../.." && pwd)"
  mkdir -p "$root/.claude/hooks/tests/.tmp"
  # Workspace-local temp + named GIT_DIR: Cursor's sandbox blocks creating a
  # literal `.git` directory. Keep GIT_CEILING_DIRECTORIES and stop on init failure.
  tmpdir=$(mktemp -d "$root/.claude/hooks/tests/.tmp/repo.XXXXXX")
  (
    # Stop git from walking above the temp repo if init fails. Without this
    # ceiling, a failed `git init` lets later commands mutate the parent repo.
    export GIT_CEILING_DIRECTORIES="$tmpdir"
    cd "$tmpdir" || exit 1
    export GIT_DIR="$tmpdir/gitdir"
    export GIT_WORK_TREE="$tmpdir"
    mkdir -p "$GIT_DIR"
    if ! git init -q; then
      echo "FAIL: git init failed in $tmpdir — refusing to continue (would risk the parent repo)" >&2
      exit 1
    fi
    if [ ! -d "$GIT_DIR" ]; then
      echo "FAIL: git init produced no gitdir in $tmpdir" >&2
      exit 1
    fi
    git config user.email "test@test.local"
    git config user.name "Test"
    git config init.defaultBranch main 2>/dev/null || true
    eval "$1"
  )
  local rc=$?
  rm -rf "$tmpdir"
  return $rc
}

# ── missing env var ─────────────────────────────────────────────────────────

echo "--- missing env var ---"
out=$(MAIN_REF="" HEAD_REF="HEAD" bash "$LIST_SCRIPT" 2>&1 || true)
contains "missing MAIN_REF prints error" "MAIN_REF is required" "$out"

# ── #1490 — lists every line the release tip removes from main ──────────────
# Models the v5.6.3 / v5.7.0 failure: main still has two contributor rows,
# the release tip (cut from a drifted dev) deleted them. The helper must
# list both deleted lines so /release can ask before continuing.

echo "--- #1490 lists every line removed from main ---"
stderr_capture=$(mktemp)
out=$(run_test '
  printf "%s\n" "Alpha Project" "Beta Project" "Gamma Project" > README.md
  git add README.md
  git commit -q -m "chore: initial readme on main"
  git branch -M main
  MAIN_SHA=$(git rev-parse HEAD)

  git checkout -q -b release/v9.9.0
  printf "%s\n" "Alpha Project" > README.md
  git add README.md
  git commit -q -m "chore: release drop drifted contributor rows"

  MAIN_REF="$MAIN_SHA" HEAD_REF="HEAD" bash "'"$LIST_SCRIPT"'" 2>"'"$stderr_capture"'"
')
stderr_bytes=$(wc -c < "$stderr_capture" | tr -d ' ')
rm -f "$stderr_capture"
contains "lists first removed contributor row" "-Beta Project" "$out"
contains "lists second removed contributor row" "-Gamma Project" "$out"
not_contains "does not list the kept row as removed" "-Alpha Project" "$out"
eq "success path writes nothing to stderr" "0" "$stderr_bytes"

# ── empty removal set is success with empty listing ─────────────────────────

echo "--- #1490 empty removal set ---"
out=$(run_test '
  echo "same on both tips" > note.txt
  git add note.txt
  git commit -q -m "chore: initial"
  git branch -M main
  MAIN_SHA=$(git rev-parse HEAD)
  git checkout -q -b release/v9.9.1
  echo "additive only" > extra.txt
  git add extra.txt
  git commit -q -m "chore: release additive change"
  MAIN_REF="$MAIN_SHA" HEAD_REF="HEAD" bash "'"$LIST_SCRIPT"'"
  echo "EXIT_CODE=$?"
')
contains "exits 0 when nothing is removed" "EXIT_CODE=0" "$out"
not_contains "no deleted content lines" "-same on both tips" "$out"

# ── removed `---` content must still list (not filtered as a diff header) ───
# A blanket `^---` filter hid YAML front-matter / markdown-rule deletions.
# Only the `--- a/...` file header after `diff --git` must be skipped.

echo "--- #1490 lists a removed --- content line ---"
out=$(run_test '
  printf "%s\n" "---" "title: demo" "---" "body" > doc.md
  git add doc.md
  git commit -q -m "chore: front matter on main"
  git branch -M main
  MAIN_SHA=$(git rev-parse HEAD)

  git checkout -q -b release/v9.9.2
  printf "%s\n" "body" > doc.md
  git add doc.md
  git commit -q -m "chore: drop front matter"

  MAIN_REF="$MAIN_SHA" HEAD_REF="HEAD" bash "'"$LIST_SCRIPT"'"
')
contains "lists removed YAML --- fence" "----" "$out"
# Diff shows one "-" plus the content "---" → "----". Also list title: demo.
contains "lists removed front-matter title line" "-title: demo" "$out"

# ── removed `-- title` content must still list ──────────────────────────────
# Diff form is "-" + "-- title" → "--- title". Must not be mistaken for the
# `--- a/path` file header.

echo "--- #1490 lists a removed -- title content line ---"
out=$(run_test '
  printf "%s\n" "keep" "-- title" "end" > notes.md
  git add notes.md
  git commit -q -m "chore: dash-dash title on main"
  git branch -M main
  MAIN_SHA=$(git rev-parse HEAD)

  git checkout -q -b release/v9.9.3
  printf "%s\n" "keep" "end" > notes.md
  git add notes.md
  git commit -q -m "chore: drop dash-dash title"

  MAIN_REF="$MAIN_SHA" HEAD_REF="HEAD" bash "'"$LIST_SCRIPT"'"
')
contains "lists removed -- title line" "--- title" "$out"
not_contains "does not list kept line as removed" "-keep" "$out"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All $pass test(s) passed."
  exit 0
else
  echo "$fail test(s) FAILED (${pass} passed)."
  exit 1
fi
