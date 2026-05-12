#!/bin/bash
# Smoke tests for .claude/hooks/_lib-audit-history.sh
# (apexyard#218 — audit-skill artefact persistence + canonical structure)
#
# Each case:
#   - builds an isolated sandbox under $TMPDIR
#   - overrides portfolio_projects_dir to point at the sandbox
#   - exercises the lib function under test
#   - asserts file presence, JSON shape, frontmatter shape, or stdout shape
#
# Cases covered (matches AC in apexyard#218):
#   1. audit_resolve_dir creates the dim dir + runs/ subdir
#   2. audit_run_persist writes both JSON + MD with augmented top-level fields
#   3. audit_run_persist derives stats.by_severity from findings[]
#   4. audit_run_persist preserves explicit stats{} when caller provides them
#   5. audit_run_persist applies .gitignore based on .audit-history-tracked marker
#   6. audit_run_list returns paths sorted by ts ascending
#   7. audit_run_list reads legacy launch-check/runs/ path for the launch-check dim
#   8. audit_render_trend silent (<2 runs)
#   9. audit_render_trend emits table + chart (>=2 runs) for a generic dimension
#  10. audit_render_trend for launch-check dispatches to legacy render-trend.sh
#  11. audit_render_trend for launch-check merges old + new history (regression
#      test for AC: "/launch-check refactored without behaviour change")
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$SRC_ROOT/.claude/hooks/_lib-audit-history.sh"

if [ ! -f "$LIB" ]; then
  echo "FAIL: lib not found at $LIB" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed; lib requires jq" >&2
  exit 0
fi

PASS=0
FAIL=0
FAILED_CASES=""

# ---------------------------------------------------------------------------
# Sandbox + lib loader. Each call creates a fresh sandbox, defines a stub
# portfolio_projects_dir pointing at it, and sources the lib (after the
# stub so the lib's later use of `command -v portfolio_projects_dir` finds
# our stub via shell function name resolution).
# ---------------------------------------------------------------------------
fresh_sandbox() {
  mktemp -d
}

source_lib_with_projects_dir() {
  local sb="$1"
  # Define stub BEFORE sourcing — but the lib re-sources real portfolio
  # paths if available. Workaround: source the lib first (using guard
  # already), then redefine the function in our shell. Bash will use the
  # latest definition for subsequent calls.
  # shellcheck source=/dev/null
  . "$LIB"
  portfolio_projects_dir() { printf '%s' "$1/projects"; }
  # Force re-export by binding to a local var via closure-style trick:
  # since bash dynamic-scopes function bodies, we redefine using the sb
  # value baked into a string.
  eval "portfolio_projects_dir() { printf '%s' '$sb/projects'; }"
}

# write_payload_json <findings_json>
# Echoes a payload JSON containing only the findings array (lib derives
# stats from it).
write_payload_json() {
  local findings="$1"
  printf '{"findings": %s}\n' "$findings"
}

# write_payload_with_stats <findings_json> <stats_json>
# Echoes a payload with explicit stats (lib should preserve, not derive).
write_payload_with_stats() {
  local findings="$1" stats="$2"
  printf '{"findings": %s, "stats": %s}\n' "$findings" "$stats"
}

mark_pass() { echo "  ✓ $1"; return 0; }
mark_fail() { echo "  ✗ $1: $2" >&2; return 1; }
# Each case_N runs in a subshell (so the lib's function-redefinition
# trickery doesn't leak between cases). Subshells can't mutate the
# parent's PASS/FAIL counters, so the runner aggregates via $? from
# each case invocation.
run_case() {
  local fn="$1"
  if "$fn"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES $fn"
  fi
}

# ---------------------------------------------------------------------------
# Case 1: audit_resolve_dir creates dirs
# ---------------------------------------------------------------------------
case_1() {
  local case_name="audit_resolve_dir creates dim + runs/"
  local sb
  sb=$(fresh_sandbox)
  ( source_lib_with_projects_dir "$sb"
    out=$(audit_resolve_dir "demo" "threat-model")
    expected="$sb/projects/demo/audits/threat-model"
    [ "$out" = "$expected" ] || { mark_fail "$case_name" "wrong path: $out"; return; }
    [ -d "$expected/runs" ] || { mark_fail "$case_name" "runs/ not created"; return; }
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 2: audit_run_persist writes JSON + MD pair
# ---------------------------------------------------------------------------
case_2() {
  local case_name="audit_run_persist writes JSON + MD"
  local sb
  sb=$(fresh_sandbox)
  ( source_lib_with_projects_dir "$sb"
    body=$(mktemp)
    echo "## Body" > "$body"
    findings='[{"id":"T1","severity":"high","status":"open","summary":"x"}]'
    write_payload_json "$findings" \
      | audit_run_persist "demo" "threat-model" "2026-05-11T20:30:00Z" "fail" 65 "$body"
    [ -f "$sb/projects/demo/audits/threat-model/runs/2026-05-11T20-30-00Z.json" ] \
      || { mark_fail "$case_name" "JSON not written"; return; }
    [ -f "$sb/projects/demo/audits/threat-model/2026-05-11T20-30-00Z.md" ] \
      || { mark_fail "$case_name" "MD not written"; return; }
    rm -f "$body"
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 3: derived stats.by_severity
# ---------------------------------------------------------------------------
case_3() {
  local case_name="audit_run_persist derives stats from findings"
  local sb
  sb=$(fresh_sandbox)
  ( source_lib_with_projects_dir "$sb"
    body=$(mktemp); echo "x" > "$body"
    findings='[
      {"id":"T1","severity":"high","status":"open","summary":"a"},
      {"id":"T2","severity":"high","status":"open","summary":"b"},
      {"id":"T3","severity":"medium","status":"mitigated","summary":"c"}
    ]'
    write_payload_json "$findings" \
      | audit_run_persist "demo" "threat-model" "2026-05-11T20:30:00Z" "fail" 50 "$body"
    json="$sb/projects/demo/audits/threat-model/runs/2026-05-11T20-30-00Z.json"
    high=$(jq -r '.stats.by_severity.high' "$json")
    medium=$(jq -r '.stats.by_severity.medium' "$json")
    [ "$high" = "2" ]   || { mark_fail "$case_name" "high count: $high"; return; }
    [ "$medium" = "1" ] || { mark_fail "$case_name" "medium count: $medium"; return; }
    rm -f "$body"
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 4: explicit stats preserved
# ---------------------------------------------------------------------------
case_4() {
  local case_name="audit_run_persist preserves caller-provided stats"
  local sb
  sb=$(fresh_sandbox)
  ( source_lib_with_projects_dir "$sb"
    body=$(mktemp); echo "x" > "$body"
    findings='[]'
    stats='{"by_severity":{"critical":7,"high":2},"by_status":{"open":5}}'
    write_payload_with_stats "$findings" "$stats" \
      | audit_run_persist "demo" "threat-model" "2026-05-11T20:30:00Z" "fail" 30 "$body"
    json="$sb/projects/demo/audits/threat-model/runs/2026-05-11T20-30-00Z.json"
    critical=$(jq -r '.stats.by_severity.critical' "$json")
    [ "$critical" = "7" ] || { mark_fail "$case_name" "explicit stats lost: $critical"; return; }
    rm -f "$body"
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 5: gitignore semantics from .audit-history-tracked marker
# ---------------------------------------------------------------------------
case_5() {
  local case_name="audit_run_persist applies marker-driven .gitignore"
  local sb
  sb=$(fresh_sandbox)
  ( source_lib_with_projects_dir "$sb"
    body=$(mktemp); echo "x" > "$body"
    payload='{"findings":[]}'

    # First run: marker absent → .gitignore should suppress runs/
    printf '%s' "$payload" \
      | audit_run_persist "demo" "threat-model" "2026-05-11T20:30:00Z" "pass" 100 "$body"
    gi="$sb/projects/demo/audits/threat-model/.gitignore"
    grep -q '^runs/$' "$gi" \
      || { mark_fail "$case_name" "marker absent: gitignore should ignore runs/"; return; }

    # Drop the marker, persist again → .gitignore should un-ignore *.json
    touch "$sb/projects/demo/audits/threat-model/.audit-history-tracked"
    printf '%s' "$payload" \
      | audit_run_persist "demo" "threat-model" "2026-05-11T21:00:00Z" "pass" 100 "$body"
    grep -q '!runs/\*\.json' "$gi" \
      || { mark_fail "$case_name" "marker present: gitignore should un-ignore *.json"; return; }
    rm -f "$body"
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 6: audit_run_list sorts by ts ascending
# ---------------------------------------------------------------------------
case_6() {
  local case_name="audit_run_list sorts by ts ascending"
  local sb
  sb=$(fresh_sandbox)
  ( source_lib_with_projects_dir "$sb"
    body=$(mktemp); echo "x" > "$body"
    for ts in "2026-05-11T20:30:00Z" "2026-04-15T14:22:00Z" "2026-05-01T09:00:00Z"; do
      printf '{"findings":[]}' \
        | audit_run_persist "demo" "threat-model" "$ts" "pass" 90 "$body"
    done
    out=$(audit_run_list "demo" "threat-model" 10)
    first=$(echo "$out" | head -1)
    last=$(echo "$out" | tail -1)
    echo "$first" | grep -q "2026-04-15" \
      || { mark_fail "$case_name" "first should be Apr-15: $first"; return; }
    echo "$last"  | grep -q "2026-05-11" \
      || { mark_fail "$case_name" "last should be May-11: $last"; return; }
    rm -f "$body"
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 7: audit_run_list reads legacy launch-check path
# ---------------------------------------------------------------------------
case_7() {
  local case_name="audit_run_list reads legacy launch-check/runs/"
  local sb
  sb=$(fresh_sandbox)
  ( source_lib_with_projects_dir "$sb"
    # Drop a legacy-shape run JSON in projects/demo/launch-check/runs/
    legacy_dir="$sb/projects/demo/launch-check/runs"
    mkdir -p "$legacy_dir"
    cat > "$legacy_dir/2026-04-01T00-00-00Z.json" <<'EOF'
{"ts":"2026-04-01T00:00:00Z","scores":{"security":80,"performance":75},"verdict":"go"}
EOF
    out=$(audit_run_list "demo" "launch-check" 10)
    echo "$out" | grep -q "launch-check/runs/2026-04-01" \
      || { mark_fail "$case_name" "legacy file not surfaced. out=$out"; return; }
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 8: audit_render_trend silent on <2 runs
# ---------------------------------------------------------------------------
case_8() {
  local case_name="audit_render_trend silent on <2 runs"
  local sb
  sb=$(fresh_sandbox)
  ( source_lib_with_projects_dir "$sb"
    body=$(mktemp); echo "x" > "$body"
    printf '{"findings":[]}' \
      | audit_run_persist "demo" "threat-model" "2026-05-11T20:30:00Z" "pass" 90 "$body"
    out=$(audit_render_trend "demo" "threat-model" 5)
    [ -z "$out" ] || { mark_fail "$case_name" "expected empty, got: $out"; return; }
    rm -f "$body"
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 9: audit_render_trend emits trend on >=2 runs (generic dim)
# ---------------------------------------------------------------------------
case_9() {
  local case_name="audit_render_trend emits trend on 2+ runs"
  local sb
  sb=$(fresh_sandbox)
  ( source_lib_with_projects_dir "$sb"
    body=$(mktemp); echo "x" > "$body"
    for ts in "2026-04-15T14:22:00Z" "2026-05-11T20:30:00Z"; do
      printf '{"findings":[]}' \
        | audit_run_persist "demo" "threat-model" "$ts" "pass" 90 "$body"
    done
    out=$(audit_render_trend "demo" "threat-model" 5)
    echo "$out" | grep -q "## Trend (last 2 runs)" \
      || { mark_fail "$case_name" "no trend heading. out=$out"; return; }
    echo "$out" | grep -q "Score trend:" \
      || { mark_fail "$case_name" "no score-trend chart. out=$out"; return; }
    rm -f "$body"
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Case 10: audit_render_trend dispatches to render-trend.sh for launch-check
# ---------------------------------------------------------------------------
case_10() {
  local case_name="audit_render_trend dispatches to legacy renderer for launch-check"
  local sb
  sb=$(fresh_sandbox)
  ( source_lib_with_projects_dir "$sb"
    runs_dir="$sb/projects/demo/audits/launch-check/runs"
    mkdir -p "$runs_dir"
    for i in 1 2; do
      ts="2026-05-0${i}T12-00-00Z"
      cat > "$runs_dir/$ts.json" <<EOF
{"ts":"2026-05-0${i}T12:00:00Z","scores":{"security":80,"performance":7${i}},"verdict":"go"}
EOF
    done
    out=$(audit_render_trend "demo" "launch-check" 5)
    # The legacy renderer emits "Score trend:" too; assert it ran (heading present).
    echo "$out" | grep -q "## Trend (last 2 runs)" \
      || { mark_fail "$case_name" "legacy renderer didn't fire. out=$out"; return; }
    mark_pass "$case_name"
  )
}

# ---------------------------------------------------------------------------
# Run all cases
# ---------------------------------------------------------------------------
echo "Running audit-history lib tests..."
# ---------------------------------------------------------------------------
# Case 11: launch-check trend merges old + new path histories (regression test
# for the "without behaviour change" AC). One run in legacy path, one run in
# canonical path; trend should render with BOTH dates visible in the chart.
# ---------------------------------------------------------------------------
case_11() {
  local case_name="audit_render_trend merges legacy + canonical for launch-check"
  local sb
  sb=$(fresh_sandbox)
  ( source_lib_with_projects_dir "$sb"
    legacy_dir="$sb/projects/demo/launch-check/runs"
    canon_dir="$sb/projects/demo/audits/launch-check/runs"
    mkdir -p "$legacy_dir" "$canon_dir"
    cat > "$legacy_dir/2026-04-01T00-00-00Z.json" <<'EOF'
{"ts":"2026-04-01T00:00:00Z","scores":{"security":80,"performance":75},"verdict":"go"}
EOF
    cat > "$canon_dir/2026-05-01T00-00-00Z.json" <<'EOF'
{"ts":"2026-05-01T00:00:00Z","scores":{"security":85,"performance":80},"verdict":"go","dimension":"launch-check","score":82,"schema_version":1}
EOF
    out=$(audit_render_trend "demo" "launch-check" 5)
    # Both dates should appear in the rendered table.
    echo "$out" | grep -q "2026-04-01" \
      || { mark_fail "$case_name" "legacy date missing from trend. out=$out"; return; }
    echo "$out" | grep -q "2026-05-01" \
      || { mark_fail "$case_name" "canonical date missing from trend. out=$out"; return; }
    mark_pass "$case_name"
  )
}

for fn in case_1 case_2 case_3 case_4 case_5 case_6 case_7 case_8 case_9 case_10 case_11; do
  run_case "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:$FAILED_CASES"
  exit 1
fi
exit 0
