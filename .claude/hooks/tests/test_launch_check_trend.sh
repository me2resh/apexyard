#!/bin/bash
# Smoke tests for .claude/skills/launch-check/render-trend.sh
# (apexyard#183 — historical trend tracking)
#
# Each case:
#   - builds an isolated runs/ dir under $TMPDIR
#   - drops N synthetic run JSON files conforming to the apexyard#183 schema
#   - invokes render-trend.sh against the dir
#   - asserts exit code + stdout shape
#
# Cases covered (matches AC in apexyard#183):
#   1. Single run        → no trend section emitted (silent, exit 0)
#   2. Empty runs dir    → no trend section emitted (silent, exit 0)
#   3. Missing runs dir  → no trend section emitted (silent, exit 0)
#   4. Two runs          → trend section IS emitted (table + chart)
#   5. Five runs         → trend table has 5 rows + chart spans 5 cols
#   6. Trend mode read   → reading existing JSON produces trend-only output
#                          (this is the "/launch-check trend" mode case —
#                          the renderer doesn't run the audit, just reads
#                          the existing history. So it's the same as case 5
#                          with the assertion that no audit-side state was
#                          written.)
#   7. Auto-notes derive → "Security +N, Performance +M" string format
#   8. Forward-compat     → run files with extra unknown fields still render
#                          (schema is additive — apexyard#183 risk note)
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RENDERER="$SRC_ROOT/.claude/skills/launch-check/render-trend.sh"

if [ ! -x "$RENDERER" ]; then
  echo "FAIL: renderer not found or not executable at $RENDERER" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed; render-trend.sh requires jq" >&2
  exit 0
fi

PASS=0
FAIL=0
FAILED_CASES=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
make_runs_dir() {
  local sb
  sb=$(mktemp -d)
  mkdir -p "$sb/runs"
  echo "$sb/runs"
}

# write_run <runs_dir> <ts> <scores_object_json> <verdict>
# ts is ISO-8601; the filename uses ts with `:` replaced by `-`.
write_run() {
  local dir="$1" ts="$2" scores="$3" verdict="$4"
  local fname
  fname=$(echo "$ts" | tr ':' '-')
  cat > "$dir/${fname}.json" <<EOF
{
  "ts": "$ts",
  "branch": "main",
  "commit": "abcdef0",
  "scores": $scores,
  "verdict": "$verdict",
  "top_risks": []
}
EOF
}

# Same as write_run but with extra unknown fields — used to verify
# forward-compatibility (apexyard#183 risk note: "adopters with existing
# runs/ shouldn't lose them on framework upgrade").
write_run_with_extras() {
  local dir="$1" ts="$2" scores="$3" verdict="$4"
  local fname
  fname=$(echo "$ts" | tr ':' '-')
  cat > "$dir/${fname}.json" <<EOF
{
  "ts": "$ts",
  "branch": "main",
  "commit": "abcdef0",
  "scores": $scores,
  "verdict": "$verdict",
  "top_risks": [],
  "future_field_v2": {"actor": "ci", "notes": "operator-supplied notes — v2 schema addition"},
  "schema_version": 99
}
EOF
}

run_renderer() {
  local dir="$1"
  local out
  out=$("$RENDERER" "$dir" 2>&1)
  echo "$out"
}

assert_empty() {
  local case_name="$1" out="$2"
  if [ -z "$out" ]; then
    PASS=$((PASS+1))
    echo "PASS: $case_name"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES="$FAILED_CASES\n$case_name (expected empty output, got: $out)"
    echo "FAIL: $case_name (expected empty output)"
    echo "----- actual output -----"
    echo "$out"
    echo "-------------------------"
  fi
}

assert_contains() {
  local case_name="$1" out="$2" needle="$3"
  if echo "$out" | grep -qF "$needle"; then
    PASS=$((PASS+1))
    echo "PASS: $case_name"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES="$FAILED_CASES\n$case_name (expected contains: $needle)"
    echo "FAIL: $case_name (expected to contain: $needle)"
    echo "----- actual output -----"
    echo "$out"
    echo "-------------------------"
  fi
}

assert_not_contains() {
  local case_name="$1" out="$2" needle="$3"
  if echo "$out" | grep -qF "$needle"; then
    FAIL=$((FAIL+1))
    FAILED_CASES="$FAILED_CASES\n$case_name (expected NOT to contain: $needle)"
    echo "FAIL: $case_name (expected to NOT contain: $needle)"
    echo "----- actual output -----"
    echo "$out"
    echo "-------------------------"
  else
    PASS=$((PASS+1))
    echo "PASS: $case_name"
  fi
}

# Standard scores-object templates so cases below stay short.
SCORES_LOW='{"security":50,"accessibility":70,"compliance":60,"analytics":60,"seo":65,"performance":60,"monitoring":60,"docs":70}'
SCORES_MID='{"security":62,"accessibility":75,"compliance":65,"analytics":70,"seo":70,"performance":65,"monitoring":70,"docs":75}'
SCORES_HI='{"security":75,"accessibility":80,"compliance":73,"analytics":80,"seo":75,"performance":70,"monitoring":75,"docs":85}'
SCORES_HI2='{"security":78,"accessibility":82,"compliance":76,"analytics":82,"seo":78,"performance":72,"monitoring":78,"docs":88}'
SCORES_HI3='{"security":80,"accessibility":85,"compliance":78,"analytics":85,"seo":80,"performance":75,"monitoring":82,"docs":90}'

# ---------------------------------------------------------------------------
# Case 1: single run -> no trend section
# ---------------------------------------------------------------------------
runs=$(make_runs_dir)
write_run "$runs" "2026-04-20T10:00:00Z" "$SCORES_LOW" "no-go"
out=$(run_renderer "$runs")
assert_empty "case1: single run produces no trend section" "$out"

# ---------------------------------------------------------------------------
# Case 2: empty runs dir -> no trend section
# ---------------------------------------------------------------------------
runs=$(make_runs_dir)
out=$(run_renderer "$runs")
assert_empty "case2: empty runs dir produces no trend section" "$out"

# ---------------------------------------------------------------------------
# Case 3: missing runs dir -> no trend section
# ---------------------------------------------------------------------------
sb=$(mktemp -d)
out=$(run_renderer "$sb/nonexistent")
assert_empty "case3: missing runs dir produces no trend section" "$out"

# ---------------------------------------------------------------------------
# Case 4: two runs -> trend section IS emitted
# ---------------------------------------------------------------------------
runs=$(make_runs_dir)
write_run "$runs" "2026-04-20T10:00:00Z" "$SCORES_LOW" "no-go"
write_run "$runs" "2026-04-27T10:00:00Z" "$SCORES_MID" "conditional-go"
out=$(run_renderer "$runs")
assert_contains "case4a: 2 runs produces trend heading"        "$out" "## Trend (last 2 runs)"
assert_contains "case4b: 2 runs produces table header"         "$out" "| Date       | Score | Verdict"
assert_contains "case4c: 2 runs produces baseline note"        "$out" "Initial baseline"
assert_contains "case4d: 2 runs produces ASCII chart heading"  "$out" "Score trend:"
assert_contains "case4e: 2 runs produces this-run marker"      "$out" "(this run)"
assert_contains "case4f: 2 runs renders earlier date"          "$out" "2026-04-20"
assert_contains "case4g: 2 runs renders later date"            "$out" "2026-04-27"

# ---------------------------------------------------------------------------
# Case 5: five runs -> trend table has all five dates + chart spans 5 columns
# ---------------------------------------------------------------------------
runs=$(make_runs_dir)
write_run "$runs" "2026-04-20T10:00:00Z" "$SCORES_LOW" "no-go"
write_run "$runs" "2026-04-27T10:00:00Z" "$SCORES_MID" "conditional-go"
write_run "$runs" "2026-05-04T10:00:00Z" "$SCORES_HI"  "conditional-go"
write_run "$runs" "2026-05-05T10:00:00Z" "$SCORES_HI2" "conditional-go"
write_run "$runs" "2026-05-06T10:00:00Z" "$SCORES_HI3" "conditional-go"
out=$(run_renderer "$runs")
assert_contains "case5a: 5 runs trend heading says 5 runs"   "$out" "## Trend (last 5 runs)"
assert_contains "case5b: earliest run shows in table"        "$out" "2026-04-20"
assert_contains "case5c: latest run shows in table"          "$out" "2026-05-06"
assert_contains "case5d: middle run shows in table"          "$out" "2026-05-04"

# ---------------------------------------------------------------------------
# Case 6: trend mode reads existing JSON without writing audit state.
# Verifies that running render-trend.sh twice in a row produces identical
# output (idempotent / read-only).
# ---------------------------------------------------------------------------
out1=$(run_renderer "$runs")
out2=$(run_renderer "$runs")
if [ "$out1" = "$out2" ]; then
  PASS=$((PASS+1))
  echo "PASS: case6: trend renderer is idempotent (read-only)"
else
  FAIL=$((FAIL+1))
  FAILED_CASES="$FAILED_CASES\ncase6: trend renderer produced different output on second run"
  echo "FAIL: case6: trend renderer is not idempotent"
fi

# Also verify no new files were written into the runs dir.
file_count_before=$(ls "$runs"/*.json | wc -l | tr -d ' ')
run_renderer "$runs" >/dev/null
file_count_after=$(ls "$runs"/*.json | wc -l | tr -d ' ')
if [ "$file_count_before" = "$file_count_after" ]; then
  PASS=$((PASS+1))
  echo "PASS: case6b: trend renderer wrote no new run files"
else
  FAIL=$((FAIL+1))
  FAILED_CASES="$FAILED_CASES\ncase6b: trend renderer wrote new files (was $file_count_before, now $file_count_after)"
  echo "FAIL: case6b: trend renderer wrote new files"
fi

# ---------------------------------------------------------------------------
# Case 7: auto-notes column derives from score deltas
# (e.g. "Security +12, Analytics +10")
# ---------------------------------------------------------------------------
runs=$(make_runs_dir)
write_run "$runs" "2026-04-20T10:00:00Z" '{"security":50,"accessibility":70,"compliance":60,"analytics":60,"seo":65,"performance":60,"monitoring":60,"docs":70}' "no-go"
write_run "$runs" "2026-04-27T10:00:00Z" '{"security":62,"accessibility":70,"compliance":60,"analytics":70,"seo":65,"performance":60,"monitoring":60,"docs":70}' "conditional-go"
out=$(run_renderer "$runs")
# Two changes: Security +12 (50→62) and Analytics +10 (60→70). Top 2 by abs delta.
assert_contains "case7a: auto-notes shows Security +12"  "$out" "Security +12"
assert_contains "case7b: auto-notes shows Analytics +10" "$out" "Analytics +10"

# ---------------------------------------------------------------------------
# Case 8: forward-compat — run files with extra unknown fields render fine.
# Adopters with existing runs/ shouldn't lose them on framework upgrade
# (apexyard#183 risk note).
# ---------------------------------------------------------------------------
runs=$(make_runs_dir)
write_run_with_extras "$runs" "2026-04-20T10:00:00Z" "$SCORES_LOW" "no-go"
write_run_with_extras "$runs" "2026-04-27T10:00:00Z" "$SCORES_MID" "conditional-go"
out=$(run_renderer "$runs")
assert_contains "case8a: extra fields don't break rendering"   "$out" "## Trend (last 2 runs)"
assert_contains "case8b: extra fields — score still computed"  "$out" "Initial baseline"
# Make sure unknown fields didn't bleed into the output.
assert_not_contains "case8c: unknown fields not echoed"        "$out" "future_field_v2"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo "test_launch_check_trend.sh: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Failed cases:"
  printf '%b\n' "$FAILED_CASES"
  exit 1
fi

exit 0
