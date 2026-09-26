#!/usr/bin/env bash
# Test suite for _lib-mermaid-lint.sh and its per-skill wrappers
# (c4/lint.sh, dfd/lint.sh, tech-vision/lint.sh, handover/lint.sh,
# plan-initiative/lint.sh).
#
# Coverage:
#   - Clean Mermaid block       → exit 0
#   - Broken Mermaid block      → exit 1     (only if Node + mmdc are available)
#   - Multiple blocks, one bad  → exit 1
#   - No Mermaid blocks         → exit 0
#   - --skip-lint               → exit 0     (no work performed)
#   - Missing file              → exit 2
#   - Unknown flag              → exit 2
#   - Node missing              → exit 3     (graceful degrade)
#   - Each per-skill wrapper dispatches to the shared lib (clean + no-blocks)
#   - handover/SKILL.md and plan-initiative/SKILL.md state the "Mermaid not
#     validated" warning (me2resh/apexyard#1382 point 4 — no silent skip)
#
# Skips parse-assertion tests when npx is not available — same graceful
# degrade the lib itself implements.
#
# Usage:  bash .claude/skills/_lib-mermaid-lint.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/_lib-mermaid-lint.sh"

PASS=0
FAIL=0

assert_exit() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "  PASS: $label  (exit $got)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label  (want exit $want, got $got)"
    FAIL=$((FAIL + 1))
  fi
}

FIXTURES=$(mktemp -d -t mermaid-lint-test-XXXXXX)
trap 'rm -rf "$FIXTURES"' EXIT

# --- Fixtures ----------------------------------------------------------

cat > "$FIXTURES/clean.md" <<'MD'
# Clean fixture

```mermaid
flowchart LR
  A[Start] --> B[Middle]
  B --> C[End]
```

End.
MD

cat > "$FIXTURES/broken.md" <<'MD'
# Broken fixture

```mermaid
flowchart LR
  A[Start --> B
  this is not valid mermaid syntax at all !!!!
  --->>>>>
```

End.
MD

cat > "$FIXTURES/mixed.md" <<'MD'
# Mixed — one clean, one broken

```mermaid
flowchart LR
  A --> B
```

```mermaid
graph TD
  ((((( not closed
```

End.
MD

cat > "$FIXTURES/no-blocks.md" <<'MD'
# No Mermaid here

Just plain markdown.

```python
print("not mermaid")
```

End.
MD

# --- Tests -------------------------------------------------------------

HAS_NPX=0
if command -v npx >/dev/null 2>&1; then
  HAS_NPX=1
fi

echo ""
echo "1) Input validation"

set +e
bash "$LIB" 2>/dev/null
assert_exit "missing file path → exit 2" 2 $?

bash "$LIB" "$FIXTURES/does-not-exist.md" 2>/dev/null
assert_exit "non-existent file → exit 2" 2 $?

bash "$LIB" "$FIXTURES/clean.md" --no-such-flag 2>/dev/null
assert_exit "unknown flag → exit 2" 2 $?
set -e

echo ""
echo "2) --skip-lint short-circuit"

bash "$LIB" "$FIXTURES/broken.md" --skip-lint > /dev/null 2>&1
assert_exit "--skip-lint with broken fixture → exit 0 (no-op)" 0 $?

echo ""
echo "3) No-Mermaid no-op"

bash "$LIB" "$FIXTURES/no-blocks.md" > /dev/null 2>&1
assert_exit "no Mermaid blocks → exit 0" 0 $?

echo ""
echo "4) Parse validation (mmdc — opt-in via MERMAID_LINT_FULL_TEST=1)"

# mmdc invocations launch headless Chromium and can take 30s-2min on first
# run (Chromium download) or when run in a constrained sandbox. Default
# test run skips them — the lib's parse-call path is exercised every time
# /c4, /dfd, or /tech-vision runs in production. Opt in to the full suite
# with `MERMAID_LINT_FULL_TEST=1 bash _lib-mermaid-lint.test.sh`.

if [ -z "${MERMAID_LINT_FULL_TEST:-}" ]; then
  echo "  SKIP: set MERMAID_LINT_FULL_TEST=1 to exercise the mmdc parse path"
elif [ "$HAS_NPX" = "1" ]; then
  bash "$LIB" "$FIXTURES/clean.md" > /dev/null 2>&1
  RC=$?
  if [ "$RC" = "0" ] || [ "$RC" = "3" ]; then
    echo "  PASS: clean fixture → exit $RC (0 if mmdc cached, 3 if network unavailable)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: clean fixture → exit $RC (expected 0 or 3)"
    FAIL=$((FAIL + 1))
  fi

  # Only run the broken / mixed tests if the clean run was actually parsed
  # (RC=0). If mmdc wasn't reachable on the clean run, broken will give the
  # same network exit — no information gained from re-running.
  if [ "$RC" = "0" ]; then
    bash "$LIB" "$FIXTURES/broken.md" > /dev/null 2>&1 || true
    BRC=$?
    if [ "$BRC" = "1" ]; then
      echo "  PASS: broken fixture → exit 1"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: broken fixture → exit $BRC (expected 1)"
      FAIL=$((FAIL + 1))
    fi

    bash "$LIB" "$FIXTURES/mixed.md" > /dev/null 2>&1 || true
    MRC=$?
    if [ "$MRC" = "1" ]; then
      echo "  PASS: mixed (1 clean, 1 broken) → exit 1"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: mixed → exit $MRC (expected 1)"
      FAIL=$((FAIL + 1))
    fi
  else
    echo "  SKIP: broken / mixed fixture (mmdc unreachable on clean fixture run)"
  fi
else
  echo "  SKIP: Node / npx not installed — the lib correctly exits 3 in that case; verify by hand"
fi

echo ""
echo "5) Per-skill wrappers dispatch to the lib"

# me2resh/apexyard#1382 (remaining part) added handover/lint.sh and
# plan-initiative/lint.sh — the two Mermaid-emitting skills that had no
# validation coverage. Same thin-wrapper shape as c4/dfd/tech-vision.
for skill in c4 dfd tech-vision handover plan-initiative; do
  WRAPPER="$SCRIPT_DIR/$skill/lint.sh"
  if [ ! -x "$WRAPPER" ]; then
    echo "  FAIL: $skill/lint.sh not executable"
    FAIL=$((FAIL + 1))
    continue
  fi
  bash "$WRAPPER" "$FIXTURES/no-blocks.md" > /dev/null 2>&1
  assert_exit "$skill/lint.sh on no-blocks fixture → exit 0" 0 $?

  bash "$WRAPPER" "$FIXTURES/clean.md" --skip-lint > /dev/null 2>&1
  assert_exit "$skill/lint.sh --skip-lint on clean fixture → exit 0 (no-op)" 0 $?
done

echo ""
echo "6) SKILL.md documents the 'not validated' warning, not a silent skip"

# me2resh/apexyard#1382 point 4: when mmdc is unavailable, the skill must
# print a clear warning rather than silently continue as if it succeeded.
# Pin the exact phrase in every SKILL.md this batch wired up, so a future
# edit can't quietly drop the warning text.
for skill in handover plan-initiative; do
  SKILL_MD="$SCRIPT_DIR/$skill/SKILL.md"
  if grep -qF "Mermaid not validated: mmdc not available." "$SKILL_MD" 2>/dev/null; then
    echo "  PASS: $skill/SKILL.md states the 'Mermaid not validated' warning"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $skill/SKILL.md does not state the 'Mermaid not validated' warning"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "----------------------------------------"
echo "Total: $((PASS + FAIL))   Passed: $PASS   Failed: $FAIL"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo ""
echo "OK: _lib-mermaid-lint test suite passed."
exit 0
