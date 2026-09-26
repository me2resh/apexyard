#!/usr/bin/env bash
# test_snapshot_empty_section_warning.sh
#
# me2resh/apexyard#1358 — /threat-model Step 1b extracts three DFD sections
# into the audit snapshot. A section that extracted to nothing used to vanish
# from the audit with no message. Step 1b now prints a warning that names the
# heading it tried, and then continues.
#
# This test extracts Step 1b from SKILL.md. It runs the step against four
# small DFD fixtures and checks the warnings on stderr.
#
# Usage: bash .claude/skills/threat-model/tests/test_snapshot_empty_section_warning.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TM_SKILL="$(cd "$SCRIPT_DIR/.." && pwd)/SKILL.md"

if [ ! -f "$TM_SKILL" ]; then
  echo "FAIL: expected file missing: $TM_SKILL" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
FAILED_CASES=""

ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1 ($2)"; FAIL=$((FAIL + 1)); FAILED_CASES="$FAILED_CASES\n  $1"; }

# Extract the documented step from SKILL.md, byte for byte.
awk '/^### Step 1b/ { f = 1 }
     f && /^```bash$/ && !inb { inb = 1; next }
     inb && /^```$/ { exit }
     inb { print }' "$TM_SKILL" > "$WORK/step1b.sh"

if ! grep -q 'dfd_classifications=' "$WORK/step1b.sh" || ! grep -q 'WARNING' "$WORK/step1b.sh"; then
  echo "FAIL: could not extract Step 1b, or it has no warning, from $TM_SKILL" >&2
  exit 1
fi

# The fixtures share these sections.
diagram='## Diagram

```mermaid
flowchart LR
    user([User]) -->|HTTPS| api[API]
```
'
trust='## Trust boundaries

| Crossing | From | To | Auth |
|---|---|---|---|
| user to api | Internet | Backend | JWT |
'
classes='## Data classifications

| Element | Class |
|---|---|
| user.email | PII |
'

printf '# DFD\n\n%s\n%s\n%s\n' "$diagram" "$trust" "$classes" > "$WORK/full.md"
printf '# DFD\n\n%s\n%s\n' "$diagram" "$trust" > "$WORK/no-classifications.md"
printf '# DFD\n\n## Diagram\n\n%s\n%s\n' "$trust" "$classes" > "$WORK/empty-diagram.md"
printf '# DFD\n\n%s\n%s\n' "$diagram" "$classes" > "$WORK/no-trust.md"

# Run Step 1b against one fixture. Print its stderr. Print DONE on stdout
# after the step, to show the step did not stop.
run_step() {
  (
    # shellcheck disable=SC2034  # read by the sourced Step 1b
    dfd="$1"
    # shellcheck source=/dev/null
    . "$WORK/step1b.sh"
    echo DONE
  ) 2> "$WORK/err.txt" > "$WORK/out.txt"
}

echo ""
echo "1) A complete DFD"
run_step "$WORK/full.md"
if [ -s "$WORK/err.txt" ]; then
  bad "a complete DFD prints nothing on stderr" "$(head -c 200 "$WORK/err.txt")"
else
  ok "a complete DFD prints nothing on stderr"
fi
if grep -qx 'DONE' "$WORK/out.txt"; then
  ok "the step completes on a complete DFD"
else
  bad "the step completes on a complete DFD" "no DONE on stdout"
fi

echo ""
echo "2) A DFD with no Data classifications section"
run_step "$WORK/no-classifications.md"
if grep -q 'WARNING: .*## Data classifications' "$WORK/err.txt"; then
  ok "the warning names the Data classifications heading"
else
  bad "the warning names the Data classifications heading" "stderr: $(head -c 200 "$WORK/err.txt")"
fi
if [ "$(grep -c 'WARNING' "$WORK/err.txt")" -eq 1 ]; then
  ok "only the missing section gets a warning"
else
  bad "only the missing section gets a warning" "$(grep -c 'WARNING' "$WORK/err.txt") warnings"
fi
if grep -qx 'DONE' "$WORK/out.txt"; then
  ok "the step continues after the warning"
else
  bad "the step continues after the warning" "no DONE on stdout"
fi

echo ""
echo "3) A DFD with no Trust boundaries section"
run_step "$WORK/no-trust.md"
if grep -q 'WARNING: .*## Trust boundaries' "$WORK/err.txt"; then
  ok "the warning names the Trust boundaries heading"
else
  bad "the warning names the Trust boundaries heading" "stderr: $(head -c 200 "$WORK/err.txt")"
fi
if [ "$(grep -c 'WARNING' "$WORK/err.txt")" -eq 1 ]; then
  ok "only the Trust boundaries section gets a warning"
else
  bad "only the Trust boundaries section gets a warning" "$(grep -c 'WARNING' "$WORK/err.txt") warnings"
fi

echo ""
echo "4) A DFD with an empty Diagram section"
run_step "$WORK/empty-diagram.md"
if grep -q 'WARNING: .*## Diagram' "$WORK/err.txt"; then
  ok "the warning names the Diagram heading"
else
  bad "the warning names the Diagram heading" "stderr: $(head -c 200 "$WORK/err.txt")"
fi

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed:%b\n' "$FAILED_CASES" >&2
  exit 1
fi
exit 0
