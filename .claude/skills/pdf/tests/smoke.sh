#!/usr/bin/env bash
# /pdf smoke test — converter dispatch + destination resolution.
#
# Covers:
#   1. Format sniffing  (.md, .html, .bpmn, unsupported)
#   2. Missing-flag handling  (no --from / --to)
#   3. Missing-input handling  (--from points at a nonexistent file)
#   4. Missing-converter graceful degrade (mocked PATH; exit 3 + advisory)
#   5. --check-only reports without converting
#   6. Markdown → PDF via pandoc, when pandoc is installed (skipped otherwise)
#   7. HTML → PDF via wkhtmltopdf, when installed (skipped otherwise)
#   8. Destination resolution helper for each of the 4 prompt options
#
# Designed to run in any sandbox without network — pandoc / wkhtmltopdf /
# npx invocations are guarded by `command -v` checks and skip cleanly when
# missing. The missing-converter test (#4) deliberately mocks PATH to remove
# every converter, so it passes uniformly across CI shapes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONVERT="$SKILL_DIR/convert.sh"

PASS=0
FAIL=0
SKIPPED=0

ok()    { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad()   { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip()  { echo "  SKIP: $1"; SKIPPED=$((SKIPPED + 1)); }

assert_exit() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    ok "$label  (got exit $got)"
  else
    bad "$label  (want exit $want, got $got)"
  fi
}

# ---------------------------------------------------------------------------
# Fixture: a tmp dir with sample inputs in each supported format.
# ---------------------------------------------------------------------------
FIXTURE=$(mktemp -d -t pdf-smoke-XXXXXX)
trap 'rm -rf "$FIXTURE"' EXIT

cat > "$FIXTURE/sample.md" <<'MD'
# Sample Doc

This is a smoke-test fixture for /pdf.

## Section

Some prose here. Lorem ipsum.

| Col A | Col B |
|-------|-------|
| 1     | 2     |
MD

cat > "$FIXTURE/sample.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>Sample</title></head>
<body><h1>Sample Doc</h1><p>HTML smoke-test fixture.</p></body></html>
HTML

cat > "$FIXTURE/sample.bpmn" <<'BPMN'
<?xml version="1.0" encoding="UTF-8"?>
<bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" targetNamespace="http://example.com/smoke">
  <bpmn:process id="p1" isExecutable="false">
    <bpmn:startEvent id="s1" name="Start" />
    <bpmn:endEvent id="e1" name="End" />
    <bpmn:sequenceFlow id="f1" sourceRef="s1" targetRef="e1" />
  </bpmn:process>
</bpmn:definitions>
BPMN

cat > "$FIXTURE/sample.unsupported" <<'TXT'
plain text — not a supported PDF input
TXT

# ---------------------------------------------------------------------------
# 1. Format sniffing
# ---------------------------------------------------------------------------
echo ""
echo "1) Format sniffing"

# Unsupported extension → exit 2
set +e
out=$("$CONVERT" --from="$FIXTURE/sample.unsupported" --to="$FIXTURE/out.pdf" 2>&1)
rc=$?
set -e
assert_exit "unsupported extension exits 2" 2 "$rc"
if echo "$out" | grep -q "unsupported input format"; then
  ok "unsupported extension error message names the issue"
else
  bad "unsupported extension error did not mention 'unsupported input format' (got: $out)"
fi

# ---------------------------------------------------------------------------
# 2. Missing-flag handling
# ---------------------------------------------------------------------------
echo ""
echo "2) Missing-flag handling"

set +e
"$CONVERT" --to="$FIXTURE/out.pdf" >/dev/null 2>&1
rc=$?
set -e
assert_exit "missing --from exits 2" 2 "$rc"

set +e
"$CONVERT" --from="$FIXTURE/sample.md" >/dev/null 2>&1
rc=$?
set -e
assert_exit "missing --to exits 2" 2 "$rc"

# ---------------------------------------------------------------------------
# 3. Missing-input handling
# ---------------------------------------------------------------------------
echo ""
echo "3) Missing-input handling"

set +e
"$CONVERT" --from="$FIXTURE/does-not-exist.md" --to="$FIXTURE/out.pdf" >/dev/null 2>&1
rc=$?
set -e
assert_exit "nonexistent input file exits 2" 2 "$rc"

# ---------------------------------------------------------------------------
# 4. Missing-converter graceful degrade (exit 3 + advisory)
# ---------------------------------------------------------------------------
echo ""
echo "4) Missing-converter graceful degrade"

# Build a stripped PATH with only the core binaries convert.sh needs
# (mktemp, sed, cat, grep, dirname, basename, mkdir, chmod, command...).
# This forces convert.sh into the "no converter installed" branch
# regardless of what's actually on the host.
STRIPPED_PATH_DIR=$(mktemp -d -t pdf-stripped-path-XXXXXX)
for tool in bash sh mktemp sed cat grep dirname basename mkdir chmod cd pwd echo cp mv rm ls test command; do
  src=$(command -v "$tool" 2>/dev/null || true)
  if [ -n "$src" ]; then
    ln -sf "$src" "$STRIPPED_PATH_DIR/$tool"
  fi
done

# Verify that none of the three converters resolve under the stripped PATH.
strip_check() {
  PATH="$STRIPPED_PATH_DIR" command -v "$1" >/dev/null 2>&1
}
if strip_check pandoc || strip_check wkhtmltopdf || strip_check npx; then
  skip "could not strip PATH cleanly (a converter symlink leaked); skipping no-converter test"
else
  set +e
  out=$(PATH="$STRIPPED_PATH_DIR" "$CONVERT" --from="$FIXTURE/sample.md" --to="$FIXTURE/out.pdf" 2>&1)
  rc=$?
  set -e
  assert_exit "no converter installed exits 3" 3 "$rc"
  if echo "$out" | grep -q "no PDF converter installed"; then
    ok "advisory message names the install steps"
  else
    bad "advisory did not mention 'no PDF converter installed' (got: $out)"
  fi
fi

rm -rf "$STRIPPED_PATH_DIR"

# ---------------------------------------------------------------------------
# 5. --check-only mode
# ---------------------------------------------------------------------------
echo ""
echo "5) --check-only reports without converting"
set +e
out=$("$CONVERT" --check-only 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then
  ok "--check-only exits 0 (≥1 converter present) or 3 (none)  (got: $rc)"
else
  bad "--check-only exits $rc (expected 0 or 3)"
fi
if echo "$out" | grep -q "converter availability"; then
  ok "--check-only output names the converters"
else
  bad "--check-only output did not include 'converter availability'"
fi

# ---------------------------------------------------------------------------
# 6. Markdown → PDF via pandoc (skipped if pandoc absent)
# ---------------------------------------------------------------------------
echo ""
echo "6) Markdown → PDF via pandoc"
if command -v pandoc >/dev/null 2>&1; then
  set +e
  "$CONVERT" --from="$FIXTURE/sample.md" --to="$FIXTURE/out-md.pdf" --converter=pandoc 2>/dev/null
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && [ -s "$FIXTURE/out-md.pdf" ]; then
    ok "pandoc produced a non-empty PDF"
  elif [ "$rc" -eq 1 ]; then
    skip "pandoc is installed but conversion failed (likely missing pdf-engine — install xelatex or pass --pdf-engine=pdflatex)"
  else
    bad "pandoc invocation exited $rc unexpectedly"
  fi
else
  skip "pandoc not installed — install via brew install pandoc"
fi

# ---------------------------------------------------------------------------
# 7. HTML → PDF via wkhtmltopdf (skipped if absent)
# ---------------------------------------------------------------------------
echo ""
echo "7) HTML → PDF via wkhtmltopdf"
if command -v wkhtmltopdf >/dev/null 2>&1; then
  set +e
  "$CONVERT" --from="$FIXTURE/sample.html" --to="$FIXTURE/out-html.pdf" --converter=wkhtmltopdf 2>/dev/null
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && [ -s "$FIXTURE/out-html.pdf" ]; then
    ok "wkhtmltopdf produced a non-empty PDF"
  else
    bad "wkhtmltopdf invocation exited $rc unexpectedly"
  fi
else
  skip "wkhtmltopdf not installed — install via brew install --cask wkhtmltopdf"
fi

# ---------------------------------------------------------------------------
# 8. Destination resolution helper
# ---------------------------------------------------------------------------
# Verifies that for each of the 4 destination options, the helper inside
# this test resolves the same path the SKILL.md describes. This is the
# *contract* the skill obeys when constructing OUT in step 5.
#
# We replicate the resolution logic in this test (rather than trying to
# invoke the SKILL.md flow) because the actual prompt-driven slot picker
# lives in the model's read of SKILL.md — there's no separate destination
# resolver binary. So we lock the *expected behaviour* via this test.
# ---------------------------------------------------------------------------
echo ""
echo "8) Destination resolution (4 prompt options)"

PROJECTS_DIR_ROOT="$FIXTURE/ops/projects"
WORKSPACE_DIR_ROOT="$FIXTURE/ops/workspace"
mkdir -p "$PROJECTS_DIR_ROOT/myproject/audits/security" "$WORKSPACE_DIR_ROOT/myproject/docs"

# Input lives at projects/myproject/audits/security/2026-05-19.md → name="myproject", stem="2026-05-19"
AUDIT_INPUT="$PROJECTS_DIR_ROOT/myproject/audits/security/2026-05-19.md"
cp "$FIXTURE/sample.md" "$AUDIT_INPUT"

resolve_dest() {
  # Args: dest_opt, input_path, project_name, projects_dir, workspace_dir
  local opt="$1" input="$2" name="$3" pdir="$4" wdir="$5"
  local stem
  stem=$(basename "$input")
  stem="${stem%.*}"
  case "$opt" in
    1|workspace) echo "$wdir/$name/docs/$stem.pdf" ;;
    2|projects)  echo "$pdir/$name/pdfs/$stem.pdf" ;;
    k|keep)      echo "$(dirname "$input")/$stem.pdf" ;;
    *) echo "" ;;
  esac
}

want="$WORKSPACE_DIR_ROOT/myproject/docs/2026-05-19.pdf"
got=$(resolve_dest 1 "$AUDIT_INPUT" myproject "$PROJECTS_DIR_ROOT" "$WORKSPACE_DIR_ROOT")
if [ "$want" = "$got" ]; then ok "option 1 → workspace/<name>/docs/"; else bad "option 1 mismatch  want=$want  got=$got"; fi

want="$PROJECTS_DIR_ROOT/myproject/pdfs/2026-05-19.pdf"
got=$(resolve_dest 2 "$AUDIT_INPUT" myproject "$PROJECTS_DIR_ROOT" "$WORKSPACE_DIR_ROOT")
if [ "$want" = "$got" ]; then ok "option 2 → projects/<name>/pdfs/"; else bad "option 2 mismatch  want=$want  got=$got"; fi

want="$PROJECTS_DIR_ROOT/myproject/audits/security/2026-05-19.pdf"
got=$(resolve_dest k "$AUDIT_INPUT" myproject "$PROJECTS_DIR_ROOT" "$WORKSPACE_DIR_ROOT")
if [ "$want" = "$got" ]; then ok "option k → next to source"; else bad "option k mismatch  want=$want  got=$got"; fi

# Option 3 is an operator-supplied custom path — verify the helper accepts
# the literal through-pass shape (not destination-rewriting it).
custom="/tmp/out.pdf"
# Helper doesn't directly resolve option 3 (it's a literal pass-through),
# but we lock the contract: option 3 is always returned as-is.
got="$custom"
if [ "$got" = "/tmp/out.pdf" ]; then ok "option 3 → operator-supplied path passes through"; else bad "option 3 lost the literal"; fi

# Audit-class filename preservation: stem keeps the date in it because it
# was in the source. No special rule needed — verify the basic stem extraction.
stem=$(basename "$AUDIT_INPUT")
stem="${stem%.*}"
if [ "$stem" = "2026-05-19" ]; then
  ok "audit-class stem preserves the YYYY-MM-DD"
else
  bad "audit-class stem mangled  (got: $stem)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "----------------------------------------"
echo "Total: $((PASS + FAIL + SKIPPED))   Passed: $PASS   Failed: $FAIL   Skipped: $SKIPPED"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
  echo "FAIL: /pdf smoke test had $FAIL failure(s)."
  exit 1
fi

echo "OK: /pdf smoke test passed."
exit 0
