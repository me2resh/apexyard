#!/usr/bin/env bash
# test_check_writing_profile.sh — tests for bin/check-writing-profile.sh.
#
# Asserts:
#   (1) a semicolon in prose is reported
#   (2) a semicolon in a code fence, inline code, or a table row is NOT
#       reported
#   (3) a 30-word sentence is reported, a 20-word sentence is not
#   (4) an unchanged existing long line is not reported (only added lines
#       count, when checking a diff range)
#   (5) no findings prints nothing
#   (6) the script's own crash or bad input still exits 0, including the
#       two round-2 edge cases: `--range` with no value (must not hang)
#       and `--files` with no files (must not exit non-zero on bash 3.2)
#   (7) the pre-push wiring does not fail when the script reports findings,
#       and the finding it surfaces is an actual finding line, not just
#       the step's own banner text
#   (8) a pure rename with unchanged content reports nothing (round-2 fix:
#       renames used to be diffed one path at a time, so git could never
#       pair the rename and reported the whole file as new)
#   (9) the MAX_ADDED_LINES cap prints one notice and stops, instead of
#       checking every line of a very large diff
#  (10) YAML frontmatter content is skipped, not just its delimiter line
#  (11) a multi-line HTML comment's content is skipped, not just a
#       single-line comment
#
# Usage: bash .claude/hooks/tests/test_check_writing_profile.sh
# Exit 0 on pass, 1 on any failure.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/bin/check-writing-profile.sh"

FAIL=0
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

assert_contains() {
  local haystack="$1" needle="$2" desc="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    green "  PASS: $desc"
  else
    red "  FAIL: $desc"
    echo "    expected to find: $needle"
    echo "    got: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" desc="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    red "  FAIL: $desc"
    echo "    did not expect to find: $needle"
    echo "    got: $haystack"
    FAIL=$((FAIL + 1))
  else
    green "  PASS: $desc"
  fi
}

assert_empty() {
  local haystack="$1" desc="$2"
  if [ -z "$haystack" ]; then
    green "  PASS: $desc"
  else
    red "  FAIL: $desc"
    echo "    expected empty output, got: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_zero() {
  local rc="$1" desc="$2"
  if [ "$rc" -eq 0 ]; then
    green "  PASS: $desc"
  else
    red "  FAIL: $desc (exit $rc)"
    FAIL=$((FAIL + 1))
  fi
}

# run_with_timeout SECONDS -- CMD...
# Runs CMD in the background and polls for it to finish, killing it after
# SECONDS if it hasn't. Prints the exit code on stdout, or "TIMEOUT" if it
# had to be killed. Used to prove `--range` with no value does not hang —
# a plain `wait` would itself hang forever if the bug were still present.
run_with_timeout() {
  local secs="$1"
  shift
  "$@" >/dev/null 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      echo "TIMEOUT"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
  echo "$?"
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ---------------------------------------------------------------------------
# Test 1 + 2: semicolon in prose reported; semicolon in fence/code/table not
# ---------------------------------------------------------------------------

echo "== Test 1+2: semicolon in prose vs. skip-listed content"
FILE1="$TMP_ROOT/semicolon.md"
cat > "$FILE1" <<'EOF'
# Heading

This is a semicolon fault; it should be reported here.

- an inline code span with `a;b` must not trip the rule

| col | val; ue |
|-----|---------|

```
code; fence; semicolon; here
```
EOF

OUT1=$(bash "$SCRIPT" --files "$FILE1")
assert_contains "$OUT1" "semicolon-in-prose" "semicolon in prose is reported"
assert_not_contains "$OUT1" "a;b" "semicolon inside inline code is not reported"
assert_not_contains "$OUT1" "val; ue" "semicolon inside a table row is not reported"
assert_not_contains "$OUT1" "code; fence" "semicolon inside a fenced code block is not reported"

# ---------------------------------------------------------------------------
# Test 3: sentence length
# ---------------------------------------------------------------------------

echo "== Test 3: sentence length"
FILE2="$TMP_ROOT/length.md"
cat > "$FILE2" <<'EOF'
This short sentence has exactly twenty words in it so it should not be flagged by the checker at all today.

This much longer descriptive sentence keeps adding more and more extra words on purpose so that it clearly runs well past the twenty five word limit set by the profile and should be flagged.
EOF

OUT2=$(bash "$SCRIPT" --files "$FILE2")
assert_not_contains "$OUT2" "twenty words" "a sentence at or under the limit is not reported"
assert_contains "$OUT2" "sentence-over-25-words" "a sentence over the limit is reported"

# ---------------------------------------------------------------------------
# Test 4: only added lines count (diff-range mode)
# ---------------------------------------------------------------------------

echo "== Test 4: unchanged existing long line is not reported"
REPO_DIR="$TMP_ROOT/repo"
mkdir -p "$REPO_DIR"
(
  cd "$REPO_DIR" || exit 1
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  cat > doc.md <<'EOF'
This pre-existing descriptive sentence is already far too long on purpose so that it runs well past the twenty five word profile limit before any change happens.
EOF
  git add doc.md
  git commit -q -m "base"
  git branch -q base_marker
  cat >> doc.md <<'EOF'

This is a normal short added sentence.
EOF
  git add doc.md
  git commit -q -m "add"
)
OUT4=$(cd "$REPO_DIR" && bash "$SCRIPT" --range "base_marker..HEAD")
assert_not_contains "$OUT4" "pre-existing descriptive" "unchanged long line is not reported"

# ---------------------------------------------------------------------------
# Test 5: no findings prints nothing
# ---------------------------------------------------------------------------

echo "== Test 5: no findings"
FILE3="$TMP_ROOT/clean.md"
cat > "$FILE3" <<'EOF'
# Clean file

This is a short, clean sentence with no faults.

Another short sentence here too.
EOF
OUT5=$(bash "$SCRIPT" --files "$FILE3")
assert_empty "$OUT5" "a clean file produces no output"

# ---------------------------------------------------------------------------
# Test 6: crash / bad input never fails, including the round-2 edge cases
# ---------------------------------------------------------------------------

echo "== Test 6: bad input never fails"
bash "$SCRIPT" --files "$TMP_ROOT/does-not-exist.md" >/dev/null 2>&1
assert_exit_zero "$?" "a missing file argument still exits 0"

bash "$SCRIPT" --range "not-a-real-range" >/dev/null 2>&1
assert_exit_zero "$?" "a bogus diff range still exits 0"

(cd /tmp && bash "$SCRIPT" >/dev/null 2>&1)
assert_exit_zero "$?" "running outside a git repository still exits 0"

# Round-2 fix: `--range` with no following value used to loop forever
# (a `shift 2` that silently does nothing when only one argument is
# left). Prove it now returns promptly, with a hard kill as a backstop —
# a plain `wait` would itself hang forever if the bug had come back.
RANGE_RC=$(run_with_timeout 8 bash "$SCRIPT" --range)
if [ "$RANGE_RC" = "TIMEOUT" ]; then
  red "  FAIL: --range with no value still hangs (killed after 8s)"
  FAIL=$((FAIL + 1))
else
  assert_exit_zero "$RANGE_RC" "--range with no value returns promptly and exits 0"
fi

# Round-2 fix: `--files` with no following file used to exit 1 on bash
# 3.2, because expanding an empty array's elements under `set -u` is
# treated there as an unset-variable reference.
bash "$SCRIPT" --files >/dev/null 2>&1
assert_exit_zero "$?" "--files with no file arguments still exits 0"

# ---------------------------------------------------------------------------
# Test 7: pre-push wiring surfaces an actual finding, not just its banner
# ---------------------------------------------------------------------------

echo "== Test 7: pre-push wiring tolerates and surfaces findings"
RUNNER="$REPO_ROOT/bin/run-pre-push-checks.sh"
if [ -f "$RUNNER" ]; then
  WIRING_REPO="$TMP_ROOT/wiring-repo"
  FAKE_BIN="$TMP_ROOT/wiring-fakebin"
  mkdir -p "$WIRING_REPO" "$FAKE_BIN"

  # A fake npx: real markdownlint-cli2 would otherwise hit the network on
  # a cold cache, which has nothing to do with what this test checks, and
  # would make it slow and flaky. Always reports a clean lint pass.
  cat > "$FAKE_BIN/npx" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$FAKE_BIN/npx"

  (
    cd "$WIRING_REPO" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    mkdir -p .claude/hooks/tests bin
    cp "$RUNNER" bin/run-pre-push-checks.sh
    cp "$SCRIPT" bin/check-writing-profile.sh
    # A real, shellcheck-clean .sh file directly under .claude/hooks.
    # Round-2 fix: without one, `find .claude/hooks -maxdepth 1 -name
    # '*.sh' | xargs shellcheck` hands GNU xargs zero files. The linter
    # then exits 3 on zero files — a fixture bug, unrelated to the
    # writing-profile step, that blocked this exact test on Linux CI.
    # BSD xargs happened to skip the run on empty input instead, which is
    # why it only showed up there.
    cat > .claude/hooks/fixture-clean.sh <<'INNER'
#!/bin/bash
echo "clean fixture"
INNER
    echo "exit 0" > .claude/hooks/tests/test_subpack_extraction.sh
    chmod +x bin/run-pre-push-checks.sh bin/check-writing-profile.sh \
      .claude/hooks/fixture-clean.sh .claude/hooks/tests/test_subpack_extraction.sh
    git add -A
    git commit -q -m "base"
    # Markdownlint-clean on purpose (heading present, short lines): this
    # test isolates the writing-profile step, so the fixture must not also
    # trip the unrelated, already-blocking markdownlint check.
    cat > FAULT.md <<'INNER'
# Fault fixture

A semicolon fault; on purpose.
INNER
    git add FAULT.md
    git commit -q -m "add fault"
  )
  WIRING_LOG="$TMP_ROOT/wiring-out.log"
  (cd "$WIRING_REPO" && PATH="$FAKE_BIN:$PATH" bash bin/run-pre-push-checks.sh >"$WIRING_LOG" 2>&1)
  WIRING_RC=$?
  WIRING_OUT=$(cat "$WIRING_LOG" 2>/dev/null)
  assert_exit_zero "$WIRING_RC" "pre-push wiring exits 0 even with a writing-profile finding"
  assert_contains "$WIRING_OUT" "semicolon-in-prose" "pre-push wiring surfaces an actual finding line, not just its banner"
else
  echo "  SKIP: $RUNNER not found"
fi

# ---------------------------------------------------------------------------
# Test 8: a pure rename with unchanged content reports nothing
# ---------------------------------------------------------------------------

echo "== Test 8: pure rename reports nothing"
RENAME_REPO="$TMP_ROOT/rename-repo"
mkdir -p "$RENAME_REPO"
(
  cd "$RENAME_REPO" || exit 1
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  cat > old-name.md <<'EOF'
# Old file

This file has short, clean prose in it and nothing else worth noting.
EOF
  git add old-name.md
  git commit -q -m "base"
  git branch -q base_marker
  git mv old-name.md new-name.md
  git commit -q -m "rename"
)
OUT8=$(cd "$RENAME_REPO" && bash "$SCRIPT" --range "base_marker..HEAD")
assert_empty "$OUT8" "a pure rename with unchanged content reports nothing"

# ---------------------------------------------------------------------------
# Test 9: the added-lines cap stops checking and prints one notice
# ---------------------------------------------------------------------------

echo "== Test 9: the added-lines cap"
CAP_REPO="$TMP_ROOT/cap-repo"
mkdir -p "$CAP_REPO"
(
  cd "$CAP_REPO" || exit 1
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  echo "base" > big.md
  git add big.md
  git commit -q -m "base"
  git branch -q base_marker
  {
    echo "line one is short and clean"
    echo "line two is short and clean"
    echo "line three is short and clean"
    echo "line four is short and clean"
  } >> big.md
  git add big.md
  git commit -q -m "add lines"
)
OUT9=$(cd "$CAP_REPO" && WP_MAX_ADDED_LINES=2 bash "$SCRIPT" --range "base_marker..HEAD")
assert_contains "$OUT9" "line cap (2 added lines) reached" "the cap prints exactly one notice at the configured limit"
CAP_NOTICE_COUNT=$(printf '%s\n' "$OUT9" | grep -c "line cap")
if [ "$CAP_NOTICE_COUNT" -eq 1 ]; then
  green "  PASS: the cap notice prints exactly once, not once per remaining line"
else
  red "  FAIL: the cap notice printed $CAP_NOTICE_COUNT times, expected 1"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# Test 10: YAML frontmatter content is skipped, not just its delimiter
# ---------------------------------------------------------------------------

echo "== Test 10: frontmatter content is skipped"
FILE10="$TMP_ROOT/frontmatter.md"
cat > "$FILE10" <<'EOF'
---
description: this frontmatter value is written to be far too many words long on purpose so that it would trip the sentence length rule if frontmatter content were ever checked
---

# Heading

Short clean body sentence here.
EOF
OUT10=$(bash "$SCRIPT" --files "$FILE10")
assert_empty "$OUT10" "a long line inside YAML frontmatter is not reported"

# ---------------------------------------------------------------------------
# Test 11: a multi-line HTML comment's content is skipped
# ---------------------------------------------------------------------------

echo "== Test 11: multi-line HTML comment content is skipped"
FILE11="$TMP_ROOT/comment.md"
cat > "$FILE11" <<'EOF'
# Heading

<!--
This line is inside a multi line comment and has a semicolon; right here.
-->

Short clean body sentence here.
EOF
OUT11=$(bash "$SCRIPT" --files "$FILE11")
assert_empty "$OUT11" "a semicolon inside a multi-line HTML comment is not reported"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo ""
if [ "$FAIL" -eq 0 ]; then
  green "All tests passed."
  exit 0
else
  red "$FAIL test(s) failed."
  exit 1
fi
