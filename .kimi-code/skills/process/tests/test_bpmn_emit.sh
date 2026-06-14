#!/usr/bin/env bash
# /process generate-bpmn.sh test — BPMN XML emission edge cases.
#
# Asserts the emitter handles:
#   - special characters in labels (&, <, >, ", ') without breaking XML
#   - message flows (cross-pool / cross-repo handoffs)
#   - --pools layout mode
#   - empty edges (single-node process)
#   - bpmn:incoming / bpmn:outgoing references for every node
#
# Standalone; doesn't need a project fixture. Uses xmllint for validity.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

assert_contains() {
  local label="$1" needle="$2" file="$3"
  if grep -q -- "$needle" "$file" 2>/dev/null; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label  (needle '$needle' missing from $(basename "$file"))"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" file="$3"
  if grep -q -- "$needle" "$file" 2>/dev/null; then
    echo "  FAIL: $label  (unexpected '$needle' found in $(basename "$file"))"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

assert_xml_valid() {
  local label="$1" file="$2"
  if command -v xmllint >/dev/null 2>&1; then
    if xmllint --noout "$file" 2>/dev/null; then
      echo "  PASS: $label  (xmllint clean)"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: $label  (xmllint rejected $(basename "$file"))"
      FAIL=$((FAIL + 1))
    fi
  else
    echo "  SKIP: $label  (xmllint not installed)"
  fi
}

# ---------------------------------------------------------------------------
# Test 1: special characters in labels
# ---------------------------------------------------------------------------
echo ""
echo "1) Special characters in labels (&, <, >, ', \") are XML-escaped"
MODEL1=$(mktemp -t pbpmn-1-XXXXXX.json)
cat > "$MODEL1" <<'JSON'
{
  "slug": "specials",
  "description": "Tests <special> & 'tricky' \"chars\"",
  "nodes": [
    { "id": "evt_start", "type": "event-start",
      "label": "Start: \"intro\" & <welcome>", "evidence": "" },
    { "id": "task_amp", "type": "task",
      "label": "A & B (less<more>greater)", "evidence": "src/a.ts:1" },
    { "id": "evt_end", "type": "event-end", "label": "End", "evidence": "" }
  ],
  "edges": [
    { "from": "evt_start", "to": "task_amp",  "kind": "sequence" },
    { "from": "task_amp",  "to": "evt_end",   "kind": "sequence" }
  ]
}
JSON

OUT1=$(mktemp -t pbpmn-1-XXXXXX.bpmn)
"$SKILL_DIR/generate-bpmn.sh" --slug=specials --model="$MODEL1" -o "$OUT1" --skip-layout > /dev/null

assert_contains "Ampersand escaped to &amp;"   '&amp;'   "$OUT1"
assert_contains "Less-than escaped to &lt;"    '&lt;'    "$OUT1"
assert_contains "Greater-than escaped to &gt;" '&gt;'    "$OUT1"
assert_contains "Quote escaped to &quot;"      '&quot;'  "$OUT1"
assert_not_contains "Raw ampersand NOT in element labels (only in entities)" 'name="A & B' "$OUT1"
assert_xml_valid "Special-chars BPMN is valid XML" "$OUT1"

# ---------------------------------------------------------------------------
# Test 2: message flows for cross-pool / cross-repo handoffs
# ---------------------------------------------------------------------------
echo ""
echo "2) Message flows are emitted as bpmn:messageFlow inside bpmn:collaboration"
MODEL2=$(mktemp -t pbpmn-2-XXXXXX.json)
cat > "$MODEL2" <<'JSON'
{
  "slug": "cross-repo",
  "description": "Cross-repo handoff via message flow",
  "lanes": [
    { "id": "lane_a", "name": "service-a" },
    { "id": "lane_b", "name": "service-b" }
  ],
  "nodes": [
    { "id": "evt_start", "type": "event-start", "label": "Request received", "lane": "lane_a", "evidence": "" },
    { "id": "task_a", "type": "task-send", "label": "Emit identity.verify", "lane": "lane_a", "evidence": "" },
    { "id": "task_b", "type": "task-receive", "label": "Handle identity.verify", "lane": "lane_b", "evidence": "" },
    { "id": "evt_end", "type": "event-end", "label": "Identity stored", "lane": "lane_b", "evidence": "" }
  ],
  "edges": [
    { "from": "evt_start", "to": "task_a",  "kind": "sequence" },
    { "from": "task_a",    "to": "task_b",  "kind": "message", "label": "identity.verify" },
    { "from": "task_b",    "to": "evt_end", "kind": "sequence" }
  ]
}
JSON

OUT2=$(mktemp -t pbpmn-2-XXXXXX.bpmn)
"$SKILL_DIR/generate-bpmn.sh" --slug=cross-repo --model="$MODEL2" -o "$OUT2" --skip-layout > /dev/null

assert_contains "bpmn:collaboration present"   '<bpmn:collaboration' "$OUT2"
assert_contains "bpmn:messageFlow emitted"     '<bpmn:messageFlow'   "$OUT2"
assert_contains "Message flow has the label"   'identity.verify'      "$OUT2"
assert_contains "Two lanes present"            'lane_a'               "$OUT2"
assert_contains "Other lane present"           'lane_b'               "$OUT2"
assert_xml_valid "Cross-repo BPMN is valid XML" "$OUT2"

# ---------------------------------------------------------------------------
# Test 3: --pools mode
# ---------------------------------------------------------------------------
echo ""
echo "3) --pools mode emits one collaboration with separate processes"
OUT3=$(mktemp -t pbpmn-3-XXXXXX.bpmn)
"$SKILL_DIR/generate-bpmn.sh" --slug=cross-repo --model="$MODEL2" -o "$OUT3" --pools --skip-layout > /dev/null

assert_contains "--pools: bpmn:collaboration present"  '<bpmn:collaboration' "$OUT3"
assert_contains "--pools: bpmn:messageFlow present"    '<bpmn:messageFlow'   "$OUT3"
assert_xml_valid "--pools BPMN is valid XML" "$OUT3"

# ---------------------------------------------------------------------------
# Test 4: incoming / outgoing references for every node
# ---------------------------------------------------------------------------
echo ""
echo "4) Every flow node has bpmn:incoming / bpmn:outgoing references for its connected flows"
MODEL4=$(mktemp -t pbpmn-4-XXXXXX.json)
cat > "$MODEL4" <<'JSON'
{
  "slug": "refs",
  "description": "Verify flow refs",
  "nodes": [
    { "id": "a", "type": "event-start", "label": "Start" },
    { "id": "b", "type": "task",        "label": "Middle" },
    { "id": "c", "type": "event-end",   "label": "End" }
  ],
  "edges": [
    { "from": "a", "to": "b", "kind": "sequence" },
    { "from": "b", "to": "c", "kind": "sequence" }
  ]
}
JSON

OUT4=$(mktemp -t pbpmn-4-XXXXXX.bpmn)
"$SKILL_DIR/generate-bpmn.sh" --slug=refs --model="$MODEL4" -o "$OUT4" --skip-layout > /dev/null

# Start event has only outgoing
assert_contains "Start event has bpmn:outgoing flow_a_b" '<bpmn:outgoing>flow_a_b</bpmn:outgoing>' "$OUT4"
# Middle node has both incoming and outgoing
assert_contains "Middle node has incoming flow_a_b"      '<bpmn:incoming>flow_a_b</bpmn:incoming>' "$OUT4"
assert_contains "Middle node has outgoing flow_b_c"      '<bpmn:outgoing>flow_b_c</bpmn:outgoing>' "$OUT4"
# End event has only incoming
assert_contains "End event has incoming flow_b_c"        '<bpmn:incoming>flow_b_c</bpmn:incoming>' "$OUT4"
assert_xml_valid "Refs BPMN is valid XML" "$OUT4"

# ---------------------------------------------------------------------------
# Test 5: exporter signature
# ---------------------------------------------------------------------------
echo ""
echo "5) Exporter metadata is set"
assert_contains "exporter attribute is set to apexyard /process" 'exporter="apexyard /process"' "$OUT4"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "----------------------------------------"
echo "Total: $((PASS + FAIL))   Passed: $PASS   Failed: $FAIL"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo ""
echo "OK: generate-bpmn.sh edge cases verified."
exit 0
