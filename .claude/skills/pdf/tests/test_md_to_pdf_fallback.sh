#!/usr/bin/env bash
# Regression test for me2resh/apexyard#404
#
# Before the fix, convert.sh passed --pdf-output-folder and --dest-name to
# md-to-pdf.  Those flags were removed in a breaking change; md-to-pdf now
# exits with:
#
#   ArgError: unknown or unexpected option: --pdf-output-folder
#
# This test verifies that:
#   a) --converter=md-to-pdf succeeds when npx + md-to-pdf are available
#   b) The PDF lands at the requested --to path with non-zero size
#   c) --pdf-output-folder is NOT passed (old stale flag is gone)
#
# The test is skipped — not failed — when npx is absent, so it never blocks CI
# on a pandoc-only host.  In a local dev environment with Node installed, run:
#
#   bash .claude/skills/pdf/tests/test_md_to_pdf_fallback.sh
#
# md-to-pdf version pinning:
#   This test intentionally does NOT pin a specific md-to-pdf version via
#   --save-exact because the skill calls `npx -y md-to-pdf` which resolves
#   npm `latest` at invocation time.  If a future md-to-pdf major version
#   changes the output-path contract again, this test is the first line of
#   defence — it will catch the regression before it reaches adopters.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONVERT="$SKILL_DIR/convert.sh"

PASS=0
FAIL=0
SKIPPED=0

ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1"; SKIPPED=$((SKIPPED + 1)); }

# ---------------------------------------------------------------------------
# Gate: skip entire file when npx is absent
# ---------------------------------------------------------------------------
if ! command -v npx >/dev/null 2>&1; then
  echo "SKIP: npx not found — install Node to run the md-to-pdf fallback test."
  exit 0
fi

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------
FIXTURE=$(mktemp -d -t pdf-md-fallback-XXXXXX)
trap 'rm -rf "$FIXTURE"' EXIT

cat > "$FIXTURE/sample.md" <<'MD'
# md-to-pdf regression test

This file is used by the `/pdf` regression test for issue #404.

## Purpose

Verifies that `convert.sh --converter=md-to-pdf` no longer passes the
removed `--pdf-output-folder` flag to md-to-pdf.

| Column A | Column B |
|----------|----------|
| foo      | bar      |
MD

OUT="$FIXTURE/out.pdf"

# ---------------------------------------------------------------------------
# Test A: --converter=md-to-pdf succeeds and produces a non-empty PDF
# ---------------------------------------------------------------------------
echo ""
echo "A) md-to-pdf fallback path — produces a non-empty PDF at the requested path"

set +e
stderr_out=$("$CONVERT" --from="$FIXTURE/sample.md" --to="$OUT" --converter=md-to-pdf 2>&1)
rc=$?
set -e

if [ "$rc" -eq 3 ]; then
  skip "md-to-pdf not available via npx (npx present but md-to-pdf download failed or network unavailable)"
elif [ "$rc" -ne 0 ]; then
  bad "conversion failed with exit $rc — stderr: $stderr_out"
else
  if [ -s "$OUT" ]; then
    ok "PDF written at $OUT with non-zero size ($(wc -c < "$OUT") bytes)"
  else
    bad "convert.sh exited 0 but PDF is missing or empty at $OUT"
  fi
fi

# ---------------------------------------------------------------------------
# Test B: --pdf-output-folder is NOT mentioned in stderr (old stale flag gone)
# ---------------------------------------------------------------------------
echo ""
echo "B) stale --pdf-output-folder flag is not passed (old bug is gone)"

set +e
stderr_flag_check=$("$CONVERT" --from="$FIXTURE/sample.md" --to="$FIXTURE/flag-check.pdf" --converter=md-to-pdf 2>&1)
rc_flag=$?
set -e

if echo "$stderr_flag_check" | grep -q "pdf-output-folder"; then
  bad "stderr still mentions --pdf-output-folder — the old stale flag is still being passed"
elif [ "$rc_flag" -eq 3 ]; then
  skip "md-to-pdf not downloadable — cannot verify flag absence, but exit 3 is not the ArgError exit"
else
  ok "--pdf-output-folder not found in stderr (stale flag is gone)"
fi

# ---------------------------------------------------------------------------
# Test C: --dest-name is NOT mentioned in stderr (other stale flag gone)
# ---------------------------------------------------------------------------
echo ""
echo "C) stale --dest-name flag is not passed"

if echo "$stderr_flag_check" | grep -q "dest-name"; then
  bad "stderr still mentions --dest-name — the old stale flag is still being passed"
elif [ "$rc_flag" -eq 3 ]; then
  skip "md-to-pdf not downloadable — cannot verify flag absence"
else
  ok "--dest-name not found in stderr (stale flag is gone)"
fi

# ---------------------------------------------------------------------------
# Test D: output file lands at exactly the requested --to path
# ---------------------------------------------------------------------------
echo ""
echo "D) PDF lands at exactly the requested --to path (not in a temp dir or next to source)"

custom_out="$FIXTURE/subdir/custom-name.pdf"
mkdir -p "$(dirname "$custom_out")"

set +e
"$CONVERT" --from="$FIXTURE/sample.md" --to="$custom_out" --converter=md-to-pdf >/dev/null 2>&1
rc_custom=$?
set -e

if [ "$rc_custom" -eq 3 ]; then
  skip "md-to-pdf not downloadable — cannot verify destination"
elif [ "$rc_custom" -ne 0 ]; then
  bad "custom destination: convert.sh exited $rc_custom"
else
  if [ -s "$custom_out" ]; then
    ok "PDF landed at requested custom path $custom_out"
  else
    bad "convert.sh exited 0 but PDF missing at $custom_out"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "--------------------------------------------------------------"
echo "Total: $((PASS + FAIL + SKIPPED))   Passed: $PASS   Failed: $FAIL   Skipped: $SKIPPED"
echo "--------------------------------------------------------------"

if [ "$FAIL" -gt 0 ]; then
  echo "FAIL: md-to-pdf fallback regression test had $FAIL failure(s)."
  exit 1
fi

echo "OK: md-to-pdf fallback regression test passed."
exit 0
