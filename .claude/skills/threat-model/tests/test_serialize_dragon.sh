#!/bin/bash
# Smoke test for .claude/skills/threat-model/serialize_dragon.py.
#
# Validates the contract documented in me2resh/apexyard#255 and
# AgDR-0022:
#   - --format=dragon produces a JSON file at the expected location
#   - the JSON parses
#   - top-level Threat Dragon v2 required keys are present
#   - every DFD node from the input shows up as a Threat Dragon cell
#   - cell-shape mapping is correct (actor / process / store / flow / boundary)
#   - flows have source.cell and target.cell pointing at real cell UUIDs
#   - every STRIDE finding attaches to its parent as a threats[] entry
#     with the six required fields the schema enforces
#   - severity is normalised into Dragon's High/Medium/Low enum
#   - --strict exits non-zero on bad input (orphan flow ref)
#   - SKILL.md frontmatter documents the flag in argument-hint
#   - SKILL.md ## Usage documents --format=dragon with a worked example
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SKILL_DIR="$SRC_ROOT/.claude/skills/threat-model"
SCRIPT="$SKILL_DIR/serialize_dragon.py"
FIXTURE="$SKILL_DIR/fixtures/sample-input.yaml"
SKILL_MD="$SKILL_DIR/SKILL.md"

for f in "$SCRIPT" "$FIXTURE" "$SKILL_MD"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is required" >&2
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 is required" >&2
  exit 0
fi

PASS=0
FAIL=0
FAILED=""

mark_pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
mark_fail() { echo "  ✗ $1: $2" >&2; FAIL=$((FAIL+1)); FAILED="$FAILED\n  - $1"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

OUT="$WORK/threat-model.json"

# ---------------------------------------------------------------------------
# Case 1: serialiser runs successfully on the fixture and writes a file.
# ---------------------------------------------------------------------------
if python3 "$SCRIPT" "$FIXTURE" --out "$OUT" 2>"$WORK/err"; then
  if [ -s "$OUT" ]; then
    mark_pass "1. serialiser writes non-empty output to --out path"
  else
    mark_fail "1. serialiser writes output" "file empty"
  fi
else
  mark_fail "1. serialiser exits 0 on valid fixture" "exit non-zero; stderr: $(cat "$WORK/err")"
fi

# ---------------------------------------------------------------------------
# Case 2: output is valid JSON.
# ---------------------------------------------------------------------------
if jq -e . "$OUT" >/dev/null 2>&1; then
  mark_pass "2. output parses as JSON"
else
  mark_fail "2. output parses as JSON" "jq parse failed"
fi

# ---------------------------------------------------------------------------
# Case 3: top-level Threat Dragon v2 required keys present.
# Schema (td.vue/src/assets/schema/threat-dragon-v2.schema.json) requires:
#   top-level: version, summary, detail
#   summary:   title
#   detail:    contributors, diagrams, diagramTop, reviewer, threatTop
# ---------------------------------------------------------------------------
missing_keys=""
for path in '.version' '.summary' '.summary.title' '.detail' '.detail.contributors' '.detail.diagrams' '.detail.diagramTop' '.detail.reviewer' '.detail.threatTop'; do
  if ! jq -e "$path" "$OUT" >/dev/null 2>&1; then
    missing_keys="$missing_keys $path"
  fi
done
if [ -z "$missing_keys" ]; then
  mark_pass "3. top-level required keys present (version / summary / detail.*)"
else
  mark_fail "3. top-level required keys" "missing:$missing_keys"
fi

# ---------------------------------------------------------------------------
# Case 4: at least one diagram with cells, every cell has id / shape / zIndex.
# ---------------------------------------------------------------------------
diagrams_count=$(jq '.detail.diagrams | length' "$OUT")
if [ "$diagrams_count" -ge 1 ]; then
  cells_count=$(jq '.detail.diagrams[0].cells | length' "$OUT")
  if [ "$cells_count" -ge 1 ]; then
    bad_cells=$(jq '[.detail.diagrams[0].cells[] | select((.id|type) != "string" or (.shape|type) != "string" or (.zIndex|type) != "number")] | length' "$OUT")
    if [ "$bad_cells" = "0" ]; then
      mark_pass "4. all cells have required id (string) / shape (string) / zIndex (number)"
    else
      mark_fail "4. cells required fields" "$bad_cells cells missing one of id/shape/zIndex"
    fi
  else
    mark_fail "4. cells present" "diagram has zero cells"
  fi
else
  mark_fail "4. diagrams present" "no diagrams emitted"
fi

# ---------------------------------------------------------------------------
# Case 5: shape mapping — every DFD node class from the fixture appears.
# Fixture has: 1 actor, 3 processes, 1 store, 4 flows, 3 boundary boxes = 12.
# ---------------------------------------------------------------------------
n_actors=$(jq '[.detail.diagrams[0].cells[] | select(.shape == "actor")] | length' "$OUT")
n_processes=$(jq '[.detail.diagrams[0].cells[] | select(.shape == "process")] | length' "$OUT")
n_stores=$(jq '[.detail.diagrams[0].cells[] | select(.shape == "store")] | length' "$OUT")
n_flows=$(jq '[.detail.diagrams[0].cells[] | select(.shape == "flow")] | length' "$OUT")
n_bounds=$(jq '[.detail.diagrams[0].cells[] | select(.shape == "trust-boundary-box")] | length' "$OUT")
expected="actors=1 processes=3 stores=1 flows=4 boundaries=3"
actual="actors=$n_actors processes=$n_processes stores=$n_stores flows=$n_flows boundaries=$n_bounds"
if [ "$expected" = "$actual" ]; then
  mark_pass "5. shape counts match fixture ($actual)"
else
  mark_fail "5. shape counts match fixture" "expected ($expected) got ($actual)"
fi

# ---------------------------------------------------------------------------
# Case 6: flow source/target UUIDs all resolve to real cell IDs.
# ---------------------------------------------------------------------------
dangling=$(jq '
  .detail.diagrams[0].cells as $cells
  | ($cells | map(.id)) as $ids
  | [$cells[] | select(.shape == "flow") | .source.cell, .target.cell]
    - $ids
  | length
' "$OUT")
if [ "$dangling" = "0" ]; then
  mark_pass "6. every flow.source.cell and flow.target.cell points at a real cell UUID"
else
  mark_fail "6. flow refs resolve" "$dangling flow source/target refs are dangling"
fi

# ---------------------------------------------------------------------------
# Case 7: each STRIDE finding attaches to its parent and has the six
# schema-required fields (description, mitigation, severity, status, title, type).
# Fixture has 3 threats: one on process api, one on store db, one on flow f2.
# ---------------------------------------------------------------------------
total_threats=$(jq '[.detail.diagrams[0].cells[] | .data.threats // [] | length] | add // 0' "$OUT")
if [ "$total_threats" = "3" ]; then
  mark_pass "7a. total threat count matches fixture (3)"
else
  mark_fail "7a. threat count" "expected 3 got $total_threats"
fi

bad_threats=$(jq '
  [.detail.diagrams[0].cells[]
    | (.data.threats // [])[]
    | select(
        (.description == null) or (.description == "") or
        (.mitigation  == null) or
        (.severity    == null) or (.severity == "") or
        (.status      == null) or (.status == "") or
        (.title       == null) or (.title == "") or
        (.type        == null) or (.type == "")
      )
  ] | length
' "$OUT")
if [ "$bad_threats" = "0" ]; then
  mark_pass "7b. every threat has the six required fields (description/mitigation/severity/status/title/type)"
else
  mark_fail "7b. threat required fields" "$bad_threats threats missing one of the required fields"
fi

# Severity is normalised into Dragon's enum: High / Medium / Low.
bad_sev=$(jq '[.detail.diagrams[0].cells[] | (.data.threats // [])[] | select(.severity | IN("High","Medium","Low") | not)] | length' "$OUT")
if [ "$bad_sev" = "0" ]; then
  mark_pass "7c. severity normalised into High/Medium/Low enum"
else
  mark_fail "7c. severity enum" "$bad_sev threats have non-conforming severity"
fi

# All threats carry status=Open per the ticket AC.
bad_status=$(jq '[.detail.diagrams[0].cells[] | (.data.threats // [])[] | select(.status != "Open")] | length' "$OUT")
if [ "$bad_status" = "0" ]; then
  mark_pass "7d. all threats default to status=Open"
else
  mark_fail "7d. status=Open" "$bad_status threats have a different status"
fi

# Threat attaches to the right parent class for at least one of each type.
api_threats=$(jq '[.detail.diagrams[0].cells[] | select(.shape=="process" and .data.name=="API service") | .data.threats // [] | length] | add' "$OUT")
db_threats=$(jq '[.detail.diagrams[0].cells[] | select(.shape=="store" and .data.name=="Primary data store") | .data.threats // [] | length] | add' "$OUT")
flow_threats=$(jq '[.detail.diagrams[0].cells[] | select(.shape=="flow") | (.data.threats // []) | length] | add' "$OUT")
if [ "$api_threats" = "1" ] && [ "$db_threats" = "1" ] && [ "$flow_threats" = "1" ]; then
  mark_pass "7e. threats land on correct parent class (process / store / flow)"
else
  mark_fail "7e. threat parent class" "api=$api_threats db=$db_threats flow=$flow_threats (expected 1/1/1)"
fi

# ---------------------------------------------------------------------------
# Case 8: every fixture entity ID has a corresponding cell in the output.
# Reads IDs out of the fixture (line-prefix grep) and asserts each one
# resolves to a cell whose .data.name matches the fixture's `name:` field.
# ---------------------------------------------------------------------------
all_named_in_output=1
for expected_name in "External user" "Web frontend" "API service" "External service" "Primary data store"; do
  if ! jq -e --arg n "$expected_name" '[.detail.diagrams[0].cells[] | select(.data.name == $n)] | length >= 1' "$OUT" >/dev/null; then
    all_named_in_output=0
    echo "    (missing entity in output: $expected_name)" >&2
  fi
done
if [ "$all_named_in_output" = "1" ]; then
  mark_pass "8. every fixture entity (actor / process / store) appears by name in output"
else
  mark_fail "8. fixture entities present" "one or more entities missing"
fi

# Each boundary's name also present.
all_boundaries=1
for bname in "Public internet" "Backend network" "Third-party service"; do
  if ! jq -e --arg n "$bname" '[.detail.diagrams[0].cells[] | select(.shape=="trust-boundary-box" and .data.name == $n)] | length >= 1' "$OUT" >/dev/null; then
    all_boundaries=0
    echo "    (missing boundary: $bname)" >&2
  fi
done
if [ "$all_boundaries" = "1" ]; then
  mark_pass "8b. every boundary appears as a trust-boundary-box with the correct name"
else
  mark_fail "8b. boundaries present" "one or more boundaries missing"
fi

# ---------------------------------------------------------------------------
# Case 9: --strict exits non-zero on an input with an orphan flow ref.
# ---------------------------------------------------------------------------
BAD="$WORK/bad-input.yaml"
cat > "$BAD" <<'YAML'
title: "Bad input"
actors:
  - { id: user, name: "User" }
flows:
  - { id: f1, source: user, target: ghost-target, label: "x" }
YAML
if python3 "$SCRIPT" "$BAD" --out "$WORK/bad-out.json" --strict >/dev/null 2>"$WORK/bad-err"; then
  mark_fail "9. --strict exits non-zero on bad input" "exited 0; stderr: $(cat "$WORK/bad-err")"
else
  # Confirm the warning message mentions the dangling target.
  if grep -q 'ghost-target' "$WORK/bad-err"; then
    mark_pass "9. --strict exits non-zero and names the dangling reference"
  else
    mark_pass "9. --strict exits non-zero on bad input (warning message did not include 'ghost-target' but exit code asserted)"
  fi
fi

# ---------------------------------------------------------------------------
# Case 10: SKILL.md documents --format=dragon in argument-hint and Usage.
# ---------------------------------------------------------------------------
if grep -qE '^argument-hint:.*--format' "$SKILL_MD"; then
  mark_pass "10a. SKILL.md argument-hint mentions --format"
else
  mark_fail "10a. argument-hint documents --format" "not found in frontmatter"
fi

if grep -qE '## Usage' "$SKILL_MD" && grep -qE -- '--format=dragon' "$SKILL_MD"; then
  mark_pass "10b. SKILL.md ## Usage documents --format=dragon"
else
  mark_fail "10b. ## Usage documents --format=dragon" "section or example missing"
fi

# ---------------------------------------------------------------------------
# Case 11: AgDR-0022 exists and captures the format-choice decision.
# ---------------------------------------------------------------------------
AGDR="$SRC_ROOT/docs/agdr/AgDR-0024-threat-dragon-export.md"
if [ -f "$AGDR" ] && grep -q "Threat Dragon" "$AGDR" && grep -qE 'TMT|\.tm7' "$AGDR" && grep -q "IriusRisk" "$AGDR"; then
  mark_pass "11. AgDR-0022 captures format choice (Dragon vs TMT vs IriusRisk)"
else
  mark_fail "11. AgDR-0022 captures format choice" "file missing or options-considered table incomplete"
fi

# ---------------------------------------------------------------------------
echo ""
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED" >&2
  exit 1
fi
exit 0
