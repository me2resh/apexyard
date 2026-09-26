#!/usr/bin/env bash
# test_snapshot_mermaid_fence.sh
#
# me2resh/apexyard#1409 — /threat-model Step 1b copied the DFD's own
# ```mermaid fence into ${dfd_mermaid}. Step 5b wrapped that text in a second
# fence. Its closing fence also joined the last captured line. GitHub then
# kept the inner fence line as diagram text. Mermaid rejected the result.
#
# This test extracts Step 1b and the Step 5b heredoc from SKILL.md.
# It runs them against a DFD from each producer. It checks the audit body for:
#   - exactly one ```mermaid fence
#   - no fence joined to the end of a content line
#   - the diagram starts on the first line inside the fence
#
# Usage: bash .claude/skills/threat-model/tests/test_snapshot_mermaid_fence.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$(cd "$TM_DIR/.." && pwd)"
ROOT="$(cd "$SKILLS_DIR/../.." && pwd)"

TM_SKILL="$TM_DIR/SKILL.md"
GENERATOR="$SKILLS_DIR/dfd/generate-mermaid.sh"
TEMPLATE="$ROOT/templates/architecture/dfd.md"

for f in "$TM_SKILL" "$GENERATOR" "$TEMPLATE"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: expected file missing: $f" >&2
    exit 1
  fi
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
FAILED_CASES=""

ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1 ($2)"; FAIL=$((FAIL + 1)); FAILED_CASES="$FAILED_CASES\n  $1"; }

# Extract the documented steps from SKILL.md, byte for byte.
awk '/^### Step 1b/ { f = 1 }
     f && /^```bash$/ && !inb { inb = 1; next }
     inb && /^```$/ { exit }
     inb { print }' "$TM_SKILL" > "$WORK/step1b.sh"
awk 'index($0, "body=$(mktemp); cat > \"$body\" <<EOF") == 1 { f = 1 }
     f { print }
     f && $0 == "EOF" { exit }' "$TM_SKILL" > "$WORK/step5b.sh"

if ! grep -q 'dfd_mermaid=' "$WORK/step1b.sh"; then
  echo "FAIL: could not extract Step 1b from $TM_SKILL" >&2
  exit 1
fi
# The extraction stops only at a line that is exactly EOF. If the heredoc
# changes shape, stop here rather than source the rest of SKILL.md.
if ! grep -q 'dfd_mermaid' "$WORK/step5b.sh" || [ "$(tail -n 1 "$WORK/step5b.sh")" != "EOF" ]; then
  echo "FAIL: could not extract the Step 5b heredoc from $TM_SKILL" >&2
  exit 1
fi

# The generator prints an unrelated error to stderr today
# (me2resh/apexyard#1410). This test does not depend on it, so the test
# discards stderr.
bash "$GENERATOR" demo /dev/null /dev/null > "$WORK/generated-dfd.md" 2>/dev/null
if ! grep -q '^## Diagram' "$WORK/generated-dfd.md"; then
  echo "FAIL: the generator produced no '## Diagram' section" >&2
  exit 1
fi

check_path() {
  local label="$1" dfd_file="$2" audit
  audit="$WORK/audit-$label.md"
  (
    # Step 5b calls mktemp. Keep its file inside the directory the trap removes.
    export TMPDIR="$WORK"
    # shellcheck disable=SC2034  # read by the sourced Step 1b
    dfd="$dfd_file"
    # shellcheck source=/dev/null
    . "$WORK/step1b.sh"
    # shellcheck source=/dev/null
    . "$WORK/step5b.sh"
    # shellcheck disable=SC2154  # set by the sourced Step 5b
    cp "$body" "$audit"
    rm -f "$body"
  )

  echo ""
  echo "$label path"

  local opens
  opens=$(grep -c '^```mermaid' "$audit")
  if [ "$opens" -eq 1 ]; then
    ok "$label: exactly one mermaid fence"
  else
    bad "$label: exactly one mermaid fence" "found $opens"
  fi

  local joined
  joined=$(grep -nE '[^`[:space:]][[:space:]]*```[[:space:]]*$' "$audit" | head -1)
  if [ -z "$joined" ]; then
    ok "$label: no fence joined to a content line"
  else
    bad "$label: no fence joined to a content line" "line $joined"
  fi

  local first
  first=$(awk '/^```mermaid/ { getline; print; exit }' "$audit")
  case "$first" in
    flowchart*) ok "$label: the diagram starts inside the fence" ;;
    *) bad "$label: the diagram starts inside the fence" "first line: '$first'" ;;
  esac
}

check_path generator "$WORK/generated-dfd.md"
check_path template "$TEMPLATE"

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed:%b\n' "$FAILED_CASES" >&2
  exit 1
fi
exit 0
