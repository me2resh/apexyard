#!/usr/bin/env bash
# test_subpack_extraction.sh — smoke test for the marketplace sub-pack extraction.
#
# Asserts:
#   (1) bin/extract-subpacks.sh runs cleanly (exit 0) against the upstream tree
#       AND lands the expected file inventory in each sub-pack
#   (2) NO framework-distinctive file leaks into either sub-pack —
#       specifically: no `apexyard.projects.yaml`, no `_lib-portfolio-paths.sh`,
#       no `/handover` skill dir, no role-definition files, no portfolio
#       README, no AgDR docs
#   (3) Each sub-pack carries the authored manifest + README that turn it into
#       a real marketplace plugin (PLUGIN.json + README.md, plus
#       settings.snippet.json for safety-hooks)
#   (4) Deliberate-leak fixture: planting a framework-distinctive token in
#       the extracted output and re-running the leak scan MUST fail (proves
#       the scan is doing work, not silently passing)
#
# Usage: bash .claude/hooks/tests/test_subpack_extraction.sh
# Exit 0 on pass, 1 on any failure.

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"

FAIL=0
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# Run the extraction into a tmp dir so this test doesn't depend on the
# repo's marketplace/ state (and doesn't trample it).
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

echo "== Step 1: run bin/extract-subpacks.sh into a tmp dir"
if ! bash "$REPO_ROOT/bin/extract-subpacks.sh" "$TMP_ROOT" >/dev/null 2>&1; then
  red "  FAIL: extraction script exited non-zero"
  FAIL=$((FAIL + 1))
  exit "$FAIL"
fi
green "  OK"

AUDIT_DIR="$TMP_ROOT/audit-pack"
SAFETY_DIR="$TMP_ROOT/safety-hooks"

# -----------------------------------------------------------------------------
# Step 2: inventory check — audit-pack
# -----------------------------------------------------------------------------
echo "== Step 2: audit-pack inventory matches AgDR-0049 contract"
AUDIT_EXPECTED=(
  ".claude/skills/launch-check/SKILL.md"
  ".claude/skills/launch-check/render-trend.sh"
  ".claude/skills/seo-audit/SKILL.md"
  ".claude/skills/geo-audit/SKILL.md"
  ".claude/skills/accessibility-audit/SKILL.md"
  ".claude/skills/compliance-check/SKILL.md"
  ".claude/skills/analytics-audit/SKILL.md"
  ".claude/skills/monitoring-audit/SKILL.md"
  ".claude/skills/docs-audit/SKILL.md"
  ".claude/skills/performance-audit/SKILL.md"
  ".claude/hooks/_lib-audit-history.sh"
  ".claude/hooks/_lib-read-config.sh"
  ".claude/hooks/_lib-ops-root.sh"
  ".claude/registries/ai-crawlers.json"
  "templates/audits/accessibility-audit.md"
  "templates/audits/analytics-audit.md"
  "templates/audits/compliance-check.md"
  "templates/audits/docs-audit.md"
  "templates/audits/geo-audit.md"
  "templates/audits/monitoring-audit.md"
  "templates/audits/performance-audit.md"
  "templates/audits/seo-audit.md"
  "EXTRACTION_MANIFEST.json"
)
for f in "${AUDIT_EXPECTED[@]}"; do
  if [ ! -f "$AUDIT_DIR/$f" ]; then
    red "  FAIL: missing in audit-pack: $f"
    FAIL=$((FAIL + 1))
  fi
done
[ "$FAIL" -eq 0 ] && green "  OK (${#AUDIT_EXPECTED[@]} files present)"

# -----------------------------------------------------------------------------
# Step 3: inventory check — safety-hooks
# -----------------------------------------------------------------------------
PREV_FAIL=$FAIL
echo "== Step 3: safety-hooks inventory matches AgDR-0049 contract"
SAFETY_EXPECTED=(
  ".claude/hooks/check-secrets.sh"
  ".claude/hooks/block-main-push.sh"
  ".claude/hooks/block-git-add-all.sh"
  ".claude/hooks/pre-push-gate.sh"
  ".claude/hooks/verify-commit-refs.sh"
  ".claude/hooks/validate-pr-create.sh"
  ".claude/hooks/validate-branch-name.sh"
  ".claude/hooks/_lib-tracker.sh"
  ".claude/hooks/_lib-read-config.sh"
  ".claude/hooks/_lib-ops-root.sh"
  ".claude/hooks/_lib-extract-pr.sh"
  "EXTRACTION_MANIFEST.json"
)
for f in "${SAFETY_EXPECTED[@]}"; do
  if [ ! -f "$SAFETY_DIR/$f" ]; then
    red "  FAIL: missing in safety-hooks: $f"
    FAIL=$((FAIL + 1))
  fi
done
[ "$FAIL" -eq "$PREV_FAIL" ] && green "  OK (${#SAFETY_EXPECTED[@]} files present)"

# -----------------------------------------------------------------------------
# Step 4: leak scan — no framework-distinctive files in either sub-pack
# -----------------------------------------------------------------------------
PREV_FAIL=$FAIL
echo "== Step 4: framework-distinctive-file leak scan (must find zero)"

# Files/dirs that, if found inside an extracted sub-pack, indicate the
# extraction has leaked framework-distinctive elements. Each pattern is
# checked via `find -path` glob; presence == leak == fail.
LEAK_PATHS=(
  "*apexyard.projects.yaml*"
  "*_lib-portfolio-paths.sh*"
  "*_lib-tracker-aware*"
  "*/skills/handover/*"
  "*/skills/agdr/*"
  "*/skills/decide/*"
  "*/skills/projects/*"
  "*/skills/inbox/*"
  "*/skills/tasks/*"
  "*/skills/stakeholder-update/*"
  "*/skills/code-review/*"
  "*/skills/security-review/*"
  "*/skills/approve-merge/*"
  "*/skills/approve-design/*"
  "*/skills/start-ticket/*"
  "*/skills/handover.md"
  "*/agents/code-reviewer.md"
  "*/roles/engineering/*"
  "*/roles/product/*"
  "*/roles/security/*"
  "*/roles/design/*"
  "*/roles/data/*"
)

run_leak_scan() {
  local label="$1"
  local dir="$2"
  local found_any=0
  for pat in "${LEAK_PATHS[@]}"; do
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      red "  FAIL: $label: leaked framework-distinctive path: ${hit#$dir/}"
      FAIL=$((FAIL + 1))
      found_any=1
    done < <(find "$dir" -path "$pat" 2>/dev/null)
  done
  return "$found_any"
}

run_leak_scan "audit-pack"   "$AUDIT_DIR"   || true
run_leak_scan "safety-hooks" "$SAFETY_DIR"  || true
[ "$FAIL" -eq "$PREV_FAIL" ] && green "  OK (no leaked paths)"

# -----------------------------------------------------------------------------
# Step 5: each sub-pack has authored manifest + README (in the real
# marketplace/ dir at repo root — these are NOT extracted from upstream,
# they're committed source files)
# -----------------------------------------------------------------------------
PREV_FAIL=$FAIL
echo "== Step 5: authored marketplace manifest + README present at repo-root marketplace/"
REAL_AUDIT="$REPO_ROOT/marketplace/audit-pack"
REAL_SAFETY="$REPO_ROOT/marketplace/safety-hooks"
for path in \
  "$REAL_AUDIT/PLUGIN.json" \
  "$REAL_AUDIT/README.md" \
  "$REAL_SAFETY/PLUGIN.json" \
  "$REAL_SAFETY/README.md" \
  "$REAL_SAFETY/.claude/settings.snippet.json"; do
  if [ ! -f "$path" ]; then
    red "  FAIL: missing authored marketplace file: ${path#$REPO_ROOT/}"
    FAIL=$((FAIL + 1))
  fi
done
[ "$FAIL" -eq "$PREV_FAIL" ] && green "  OK"

# -----------------------------------------------------------------------------
# Step 6: deliberate-leak fixture — planting a leak token in the tmp output
# and rerunning the scan MUST fail. This proves the scan does work, not
# just exits 0 silently.
# -----------------------------------------------------------------------------
PREV_FAIL=$FAIL
echo "== Step 6: deliberate-leak fixture (must DETECT the planted token)"
PLANT_DIR="$(mktemp -d)"
cp -R "$AUDIT_DIR" "$PLANT_DIR/audit-pack"
mkdir -p "$PLANT_DIR/audit-pack/.claude/skills/handover"
echo "# planted framework-distinctive file" > "$PLANT_DIR/audit-pack/.claude/skills/handover/SKILL.md"

planted_found=0
for pat in "${LEAK_PATHS[@]}"; do
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    planted_found=1
  done < <(find "$PLANT_DIR/audit-pack" -path "$pat" 2>/dev/null)
done

rm -rf "$PLANT_DIR"

if [ "$planted_found" -eq 1 ]; then
  green "  OK (scan caught the deliberately-planted leak token)"
else
  red "  FAIL: deliberate leak NOT detected — the leak-scan logic is broken"
  FAIL=$((FAIL + 1))
fi

# -----------------------------------------------------------------------------
# Step 7: each sub-pack's EXTRACTION_MANIFEST.json records an upstream SHA
# -----------------------------------------------------------------------------
PREV_FAIL=$FAIL
echo "== Step 7: EXTRACTION_MANIFEST.json records upstream_sha"
for d in "$AUDIT_DIR" "$SAFETY_DIR"; do
  manifest="$d/EXTRACTION_MANIFEST.json"
  if [ ! -f "$manifest" ]; then
    red "  FAIL: missing manifest: ${manifest#$TMP_ROOT/}"
    FAIL=$((FAIL + 1))
    continue
  fi
  if ! grep -q '"upstream_sha":' "$manifest"; then
    red "  FAIL: ${manifest#$TMP_ROOT/} missing upstream_sha key"
    FAIL=$((FAIL + 1))
  fi
done
[ "$FAIL" -eq "$PREV_FAIL" ] && green "  OK"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
if [ "$FAIL" -eq 0 ]; then
  green "All sub-pack extraction invariants pass."
  exit 0
else
  red "$FAIL invariant(s) failed."
  exit 1
fi
