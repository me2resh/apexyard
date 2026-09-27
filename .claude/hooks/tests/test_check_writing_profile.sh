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
#   (6) the script's own crash or bad input still exits 0
#   (7) the pre-push wiring does not fail when the script reports findings
#
# Usage: bash .claude/hooks/tests/test_check_writing_profile.sh
# Exit 0 on pass, 1 on any failure.

set -u

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
# Test 6: crash / bad input still exits 0
# ---------------------------------------------------------------------------

echo "== Test 6: bad input never fails"
bash "$SCRIPT" --files "$TMP_ROOT/does-not-exist.md" >/dev/null 2>&1
assert_exit_zero "$?" "a missing file argument still exits 0"

bash "$SCRIPT" --range "not-a-real-range" >/dev/null 2>&1
assert_exit_zero "$?" "a bogus diff range still exits 0"

(cd /tmp && bash "$SCRIPT" >/dev/null 2>&1)
assert_exit_zero "$?" "running outside a git repository still exits 0"

# ---------------------------------------------------------------------------
# Test 7: pre-push wiring does not fail when the script reports findings
# ---------------------------------------------------------------------------

echo "== Test 7: pre-push wiring tolerates findings"
RUNNER="$REPO_ROOT/bin/run-pre-push-checks.sh"
if [ -f "$RUNNER" ]; then
  WIRING_REPO="$TMP_ROOT/wiring-repo"
  mkdir -p "$WIRING_REPO"
  (
    cd "$WIRING_REPO" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    mkdir -p .claude/hooks/tests bin
    cp "$RUNNER" bin/run-pre-push-checks.sh
    cp "$SCRIPT" bin/check-writing-profile.sh
    echo "true" > .claude/hooks/tests/test_subpack_extraction.sh
    chmod +x bin/run-pre-push-checks.sh bin/check-writing-profile.sh .claude/hooks/tests/test_subpack_extraction.sh
    git add -A
    git commit -q -m "base"
    # Markdownlint-clean on purpose (heading present, short lines): this
    # test isolates the writing-profile step, so the fixture must not also
    # trip the unrelated, already-blocking markdownlint check.
    cat > FAULT.md <<'EOF'
# Fault fixture

A semicolon fault; on purpose.
EOF
    git add FAULT.md
    git commit -q -m "add fault"
  )
  (cd "$WIRING_REPO" && bash bin/run-pre-push-checks.sh >/tmp/wiring-out.$$ 2>&1)
  WIRING_RC=$?
  WIRING_OUT=$(cat "/tmp/wiring-out.$$" 2>/dev/null)
  rm -f "/tmp/wiring-out.$$"
  assert_exit_zero "$WIRING_RC" "pre-push wiring exits 0 even with a writing-profile finding"
  assert_contains "$WIRING_OUT" "writing-profile" "pre-push wiring surfaces the writing-profile finding"
else
  echo "  SKIP: $RUNNER not found"
fi

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
