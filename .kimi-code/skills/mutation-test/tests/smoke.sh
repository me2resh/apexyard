#!/usr/bin/env bash
# /mutation-test smoke test — language detection + graceful-degradation + report shape.
#
# Covers:
#   1. Language detection — file-count heuristic across each supported language
#   2. Mixed-language tie-breaking — TS files always win over JS
#   3. Unknown / empty project handling — exits cleanly with "unknown"
#   4. Runner check — known runner names accepted, unknown rejected
#   5. Graceful degradation — exit 3 + advisory when no runner is installed
#   6. --check-only mode — reports runner availability without running
#   7. Report shape — the six-section structure documented in SKILL.md is
#      buildable by the operator from a known-good payload
#
# Designed to run in any sandbox without network. Runner-installed checks
# are guarded — the test passes whether or not stryker/mutpy/etc. happen
# to be on the host PATH.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
DETECT="$SKILL_DIR/detect.sh"

PASS=0
FAIL=0
SKIPPED=0

ok()    { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad()   { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip()  { echo "  SKIP: $1"; SKIPPED=$((SKIPPED + 1)); }

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    ok "$label  (got: $got)"
  else
    bad "$label  (want: $want, got: $got)"
  fi
}

assert_exit() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    ok "$label  (got exit $got)"
  else
    bad "$label  (want exit $want, got exit $got)"
  fi
}

FIXTURE=$(mktemp -d -t mut-smoke-XXXXXX)
trap 'rm -rf "$FIXTURE"' EXIT

# ---------------------------------------------------------------------------
# 1. Language detection — one fixture per language
# ---------------------------------------------------------------------------
echo ""
echo "1) Language detection (file-count heuristic)"

# Python-dominant fixture (5 .py + 0 others)
PY_DIR="$FIXTURE/python-project"
mkdir -p "$PY_DIR/src"
for i in 1 2 3 4 5; do
  echo "def f${i}(): return ${i}" > "$PY_DIR/src/mod${i}.py"
done
got=$("$DETECT" --detect "$PY_DIR")
assert_eq "5 .py files → python" "python" "$got"

# TS-dominant fixture
TS_DIR="$FIXTURE/ts-project"
mkdir -p "$TS_DIR/src"
for i in 1 2 3 4 5 6; do
  echo "export const v${i} = ${i};" > "$TS_DIR/src/mod${i}.ts"
done
got=$("$DETECT" --detect "$TS_DIR")
assert_eq "6 .ts files → ts" "ts" "$got"

# Pure-JS fixture
JS_DIR="$FIXTURE/js-project"
mkdir -p "$JS_DIR/src"
for i in 1 2 3 4; do
  echo "exports.v${i} = ${i};" > "$JS_DIR/src/mod${i}.js"
done
got=$("$DETECT" --detect "$JS_DIR")
assert_eq "4 .js files (no .ts) → js" "js" "$got"

# Go fixture
GO_DIR="$FIXTURE/go-project"
mkdir -p "$GO_DIR"
for i in 1 2 3; do
  echo "package main" > "$GO_DIR/file${i}.go"
done
got=$("$DETECT" --detect "$GO_DIR")
assert_eq "3 .go files → go" "go" "$got"

# Ruby fixture
RB_DIR="$FIXTURE/ruby-project"
mkdir -p "$RB_DIR"
for i in 1 2 3 4; do
  echo "class C${i}; end" > "$RB_DIR/c${i}.rb"
done
got=$("$DETECT" --detect "$RB_DIR")
assert_eq "4 .rb files → ruby" "ruby" "$got"

# Acceptance-criteria spec: 5 .py + 2 .ts → MutPy (python wins by count)
MIXED_AC="$FIXTURE/ac-fixture"
mkdir -p "$MIXED_AC/src"
for i in 1 2 3 4 5; do
  echo "def f${i}(): return ${i}" > "$MIXED_AC/src/mod${i}.py"
done
for i in 1 2; do
  echo "export const v${i} = ${i};" > "$MIXED_AC/src/mod${i}.ts"
done
got=$("$DETECT" --detect "$MIXED_AC")
assert_eq "AC fixture (5 .py + 2 .ts) → python (MutPy)" "python" "$got"

# ---------------------------------------------------------------------------
# 2. TS-wins-over-JS tie-breaker
# ---------------------------------------------------------------------------
echo ""
echo "2) Mixed TS/JS tie-breaker"

MIXED_DIR="$FIXTURE/mixed-ts-js"
mkdir -p "$MIXED_DIR/src"
# More .js than .ts, but the presence-of-TS rule should still pick TS
for i in 1 2 3 4 5 6; do
  echo "exports.v${i} = ${i};" > "$MIXED_DIR/src/mod${i}.js"
done
for i in 1 2; do
  echo "export const t${i} = ${i};" > "$MIXED_DIR/src/t${i}.ts"
done
got=$("$DETECT" --detect "$MIXED_DIR")
assert_eq "6 .js + 2 .ts → ts (presence-of-TS rule)" "ts" "$got"

# ---------------------------------------------------------------------------
# 3. Unknown / empty project
# ---------------------------------------------------------------------------
echo ""
echo "3) Unknown / empty project handling"

EMPTY_DIR="$FIXTURE/empty-project"
mkdir -p "$EMPTY_DIR"
got=$("$DETECT" --detect "$EMPTY_DIR")
assert_eq "empty dir → unknown" "unknown" "$got"

# Project with only .md files
DOCS_DIR="$FIXTURE/docs-only"
mkdir -p "$DOCS_DIR"
echo "# Hello" > "$DOCS_DIR/README.md"
echo "# Other" > "$DOCS_DIR/CHANGELOG.md"
got=$("$DETECT" --detect "$DOCS_DIR")
assert_eq "docs-only dir → unknown" "unknown" "$got"

# node_modules exclusion — files inside node_modules don't count
EXCL_DIR="$FIXTURE/excluded-deps"
mkdir -p "$EXCL_DIR/src" "$EXCL_DIR/node_modules/some-lib"
echo "exports.v = 1;" > "$EXCL_DIR/node_modules/some-lib/index.js"
echo "exports.v = 2;" > "$EXCL_DIR/node_modules/some-lib/util.js"
echo "exports.v = 3;" > "$EXCL_DIR/node_modules/some-lib/more.js"
# But the project itself has one .py file — Python should still win
echo "def f(): return 1" > "$EXCL_DIR/src/a.py"
got=$("$DETECT" --detect "$EXCL_DIR")
assert_eq "node_modules excluded → python wins on a single .py" "python" "$got"

# ---------------------------------------------------------------------------
# 4. Runner check — name validation
# ---------------------------------------------------------------------------
echo ""
echo "4) Runner check — name validation"

# Known runner names → exit 0 (if installed) or 3 (if not), but never 2
for r in stryker mutpy go-mutesting mutant; do
  set +e
  "$DETECT" --check "$r" >/dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then
    ok "runner $r → exit 0|3 (got: $rc)"
  else
    bad "runner $r → unexpected exit $rc"
  fi
done

# Unknown runner → exit 2
set +e
"$DETECT" --check bogus-runner >/dev/null 2>&1
rc=$?
set -e
assert_exit "unknown runner → exit 2" 2 "$rc"

# Missing name → exit 2
set +e
"$DETECT" --check >/dev/null 2>&1
rc=$?
set -e
assert_exit "--check with no name → exit 2" 2 "$rc"

# ---------------------------------------------------------------------------
# 5. Graceful degradation — exit 3 + advisory under stripped PATH
# ---------------------------------------------------------------------------
echo ""
echo "5) Graceful degradation (exit 3 + advisory)"

# Mock PATH to strip all four runners — same shape as /pdf's smoke test.
STRIPPED_PATH_DIR=$(mktemp -d -t mut-stripped-path-XXXXXX)
for tool in bash sh mktemp sed cat grep dirname basename mkdir chmod cd pwd echo cp mv rm ls test command find wc tr awk; do
  src=$(command -v "$tool" 2>/dev/null || true)
  if [ -n "$src" ]; then
    ln -sf "$src" "$STRIPPED_PATH_DIR/$tool"
  fi
done

# Verify none of the four runners leak through the stripped PATH
strip_check() {
  PATH="$STRIPPED_PATH_DIR" command -v "$1" >/dev/null 2>&1
}
if strip_check stryker || strip_check mut.py || strip_check go-mutesting || strip_check mutant; then
  skip "could not strip PATH cleanly (a runner symlink leaked); skipping no-runner test"
else
  set +e
  out=$(PATH="$STRIPPED_PATH_DIR" "$DETECT" --check-only "$PY_DIR" 2>&1)
  rc=$?
  set -e
  assert_exit "no runner installed → exit 3" 3 "$rc"
  if echo "$out" | grep -q "No mutation tester installed"; then
    ok "advisory message names the gap"
  else
    bad "advisory did not mention 'No mutation tester installed' (got: $out)"
  fi
  if echo "$out" | grep -q "stryker-mutator"; then
    ok "advisory includes the Stryker install one-liner"
  else
    bad "advisory missing the Stryker install one-liner (got: $out)"
  fi
  if echo "$out" | grep -q "mutpy"; then
    ok "advisory includes the MutPy install one-liner"
  else
    bad "advisory missing the MutPy install one-liner (got: $out)"
  fi
  if echo "$out" | grep -q "go-mutesting"; then
    ok "advisory includes the go-mutesting install one-liner"
  else
    bad "advisory missing the go-mutesting install one-liner (got: $out)"
  fi
  if echo "$out" | grep -q "mutant"; then
    ok "advisory includes the mutant install one-liner"
  else
    bad "advisory missing the mutant install one-liner (got: $out)"
  fi
fi
rm -rf "$STRIPPED_PATH_DIR"

# Advisory-only flag
set +e
out=$("$DETECT" --advisory 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "No mutation tester installed"; then
  ok "--advisory prints the install message and exits 0"
else
  bad "--advisory did not print the expected message (rc=$rc, out=$out)"
fi

# ---------------------------------------------------------------------------
# 6. --check-only mode — reports without running
# ---------------------------------------------------------------------------
echo ""
echo "6) --check-only mode"

set +e
out=$("$DETECT" --check-only "$PY_DIR" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then
  ok "--check-only exits 0 (≥1 runner present) or 3 (none)  (got: $rc)"
else
  bad "--check-only exits $rc unexpectedly"
fi
if echo "$out" | grep -q "language detected: python"; then
  ok "--check-only reports the detected language"
else
  bad "--check-only did not report language (got: $out)"
fi
if echo "$out" | grep -q "runner availability"; then
  ok "--check-only reports runner availability"
else
  bad "--check-only did not report runner availability (got: $out)"
fi

# ---------------------------------------------------------------------------
# 7. Report shape contract — the six-section structure
# ---------------------------------------------------------------------------
# The actual report rendering lives in the SKILL.md flow (model-driven).
# This test pins the *contract* — given a known payload, the section
# headings the operator-facing rendering must include.
# ---------------------------------------------------------------------------
echo ""
echo "7) Report shape contract"

REPORT_FIXTURE="$FIXTURE/sample-report.md"
cat > "$REPORT_FIXTURE" <<'REPORT'
# Mutation report — example-app — 2026-05-20

| Field | Value |
|-------|-------|
| Project   | example-app |
| Language  | python |
| Runner    | mutpy |
| Threshold | 60% |
| Command   | `mut.py --target src --unit-test tests` |
| Duration  | 00:23:14 |

## Score

**142 / 220 = 65%** — PASS

## Summary

| Outcome | Count | Notes |
|---------|-------|-------|
| Killed         | 142 | Test suite caught the mutation |
| Survived       | 58  | Test gap — investigate top-5 below |
| Timed out      | 8   | Counts as killed |
| No coverage    | 12  | Mutated line not exercised |
| Compile error  | 0   | n/a (Python) |
| Runtime error  | 0   | Excluded from score |

## Top-5 survived mutants

### 1. `src/foo.py:42` — ArithmeticOperator (`+` → `-`)

Original code; mutated code; hint.

### 2. `src/bar.py:18` — RelationalOperator (`<` → `<=`)

Original code; mutated code; hint.

## Trend (last 5 runs)

| Date | Score | Threshold | Verdict |
|------|-------|-----------|---------|
| 2026-05-20 | 65% | 60% | PASS |

## Recommendations

- Strengthen assertions in `tests/test_foo.py`
REPORT

required_sections="^# Mutation report
^## Score
^## Summary
^## Top-5 survived mutants
^## Trend
^## Recommendations"

while IFS= read -r section; do
  if grep -q "$section" "$REPORT_FIXTURE"; then
    ok "report includes section: ${section#^}"
  else
    bad "report missing section: ${section#^}"
  fi
done <<< "$required_sections"

# Score line shape — "<killed> / <denominator> = <pct>%"
if grep -qE '^\*\*[0-9]+ / [0-9]+ = [0-9]+%\*\*' "$REPORT_FIXTURE"; then
  ok "score line matches the contract: **K / D = P%**"
else
  bad "score line does not match the contract"
fi

# Threshold + verdict line in the score section
if grep -qE 'PASS|WARN below threshold' "$REPORT_FIXTURE"; then
  ok "score section names the PASS/WARN verdict"
else
  bad "score section did not name the verdict"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "----------------------------------------"
echo "Total: $((PASS + FAIL + SKIPPED))   Passed: $PASS   Failed: $FAIL   Skipped: $SKIPPED"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
  echo "FAIL: /mutation-test smoke test had $FAIL failure(s)."
  exit 1
fi

echo "OK: /mutation-test smoke test passed."
exit 0
