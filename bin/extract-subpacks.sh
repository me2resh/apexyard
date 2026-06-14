#!/usr/bin/env bash
# extract-subpacks.sh — extract the audit-pack + safety-hooks marketplace sub-packs
# from the upstream framework source.
#
# Strategic context: ApexYard's full framework is a fork-based ops repo (not a
# drop-in plugin). The Claude Code marketplace surface can't host the
# integrated whole, so we ship two narrowly-scoped sub-packs as marketplace
# plugins — `apexyard/audit-pack` and `apexyard/safety-hooks` — that work
# without the portfolio model, `/handover`, or role definitions. The sub-packs
# are EXTRACTED (not forked) from upstream HEAD at release time. See
# docs/agdr/AgDR-0049-marketplace-subpacks-as-funnel.md for the full rationale.
#
# Usage:
#   bin/extract-subpacks.sh              # extract into marketplace/ at repo root
#   bin/extract-subpacks.sh /tmp/out     # extract into /tmp/out/
#   bin/extract-subpacks.sh --dry-run    # list what would be extracted, copy nothing
#   bin/extract-subpacks.sh --manifest-only  # write only the manifest files (no file copies)
#
# Exit codes:
#   0 — extraction succeeded; both sub-pack manifests written
#   1 — extraction failed (file missing, copy error)
#   2 — invalid argument
#
# Idempotent: re-running overwrites the extracted output. Safe to invoke from
# CI on every release tag (.github/workflows/extract-subpacks-on-release.yml).

set -u

# ----- resolve repo root from this script's location ------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ----- parse args ------------------------------------------------------------
DRY_RUN=0
MANIFEST_ONLY=0
OUT_DIR="$REPO_ROOT/marketplace"

for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY_RUN=1 ;;
    --manifest-only)  MANIFEST_ONLY=1 ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "extract-subpacks.sh: unknown flag: $arg" >&2
      exit 2
      ;;
    *)
      OUT_DIR="$arg"
      ;;
  esac
done

# ----- helpers --------------------------------------------------------------
say()   { printf '%s\n' "$*"; }
fail()  { printf 'extract-subpacks.sh: FAIL: %s\n' "$*" >&2; exit 1; }

upstream_sha() {
  git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown"
}

# Copy a file from upstream → sub-pack. Mirrors directories.
# Args: <upstream-relative-path> <subpack-relative-path>
copy_file() {
  local src="$REPO_ROOT/$1"
  local dst="$2"
  if [ ! -f "$src" ]; then
    fail "missing upstream file: $1"
  fi
  if [ "$DRY_RUN" -eq 1 ] || [ "$MANIFEST_ONLY" -eq 1 ]; then
    say "  would copy: $1 → $dst"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst" || fail "copy failed: $1 → $dst"
}

# ----- audit-pack inventory --------------------------------------------------
# Skills: launch-check + 9 deep-dive audit skills
AUDIT_SKILLS=(
  launch-check
  seo-audit
  geo-audit
  accessibility-audit
  compliance-check
  analytics-audit
  monitoring-audit
  docs-audit
  performance-audit
)

# Hook libs: persistence + config reader
AUDIT_HOOK_LIBS=(
  _lib-audit-history.sh
  _lib-read-config.sh
  _lib-ops-root.sh
)

# Registries (consumed by /geo-audit)
AUDIT_REGISTRIES=(
  ai-crawlers.json
)

# Audit templates (consumed by all audit skills)
AUDIT_TEMPLATES=(
  accessibility-audit.md
  analytics-audit.md
  compliance-check.md
  docs-audit.md
  geo-audit.md
  monitoring-audit.md
  performance-audit.md
  seo-audit.md
)

# ----- safety-hooks inventory ------------------------------------------------
SAFETY_HOOKS=(
  check-secrets.sh
  block-main-push.sh
  block-git-add-all.sh
  pre-push-gate.sh
  verify-commit-refs.sh
  validate-pr-create.sh
  validate-branch-name.sh
)

SAFETY_HOOK_LIBS=(
  _lib-tracker.sh
  _lib-read-config.sh
  _lib-ops-root.sh
  _lib-extract-pr.sh
)

# ----- extract audit-pack ----------------------------------------------------
AUDIT_DIR="$OUT_DIR/audit-pack"
say "Extracting audit-pack → $AUDIT_DIR"

for skill in "${AUDIT_SKILLS[@]}"; do
  copy_file ".apexyard/skills/$skill/SKILL.md" "$AUDIT_DIR/.apexyard/skills/$skill/SKILL.md"
  # Carry sibling files (render-trend.sh for /launch-check, tests/ for /geo-audit)
  if [ -d "$REPO_ROOT/.apexyard/skills/$skill" ]; then
    for sibling in "$REPO_ROOT/.apexyard/skills/$skill"/*; do
      [ -e "$sibling" ] || continue
      name="$(basename "$sibling")"
      [ "$name" = "SKILL.md" ] && continue
      [ -d "$sibling" ] && continue   # skip nested dirs (e.g. tests/) for v1
      copy_file ".apexyard/skills/$skill/$name" "$AUDIT_DIR/.apexyard/skills/$skill/$name"
    done
  fi
done

for lib in "${AUDIT_HOOK_LIBS[@]}"; do
  copy_file ".apexyard/hooks/$lib" "$AUDIT_DIR/.apexyard/hooks/$lib"
done

for reg in "${AUDIT_REGISTRIES[@]}"; do
  copy_file ".apexyard/registries/$reg" "$AUDIT_DIR/.apexyard/registries/$reg"
done

for tmpl in "${AUDIT_TEMPLATES[@]}"; do
  copy_file "templates/audits/$tmpl" "$AUDIT_DIR/templates/audits/$tmpl"
done

# README + manifest live in the sub-pack source dir; they're not extracted from upstream
# — they're authored once and committed to marketplace/audit-pack/. Skip copying them
# from upstream (they don't exist there). The CI workflow / smoke test verifies they
# remain present in the sub-pack after extraction.

# ----- extract safety-hooks --------------------------------------------------
SAFETY_DIR="$OUT_DIR/safety-hooks"
say "Extracting safety-hooks → $SAFETY_DIR"

for hook in "${SAFETY_HOOKS[@]}"; do
  copy_file ".apexyard/hooks/$hook" "$SAFETY_DIR/.apexyard/hooks/$hook"
done

for lib in "${SAFETY_HOOK_LIBS[@]}"; do
  copy_file ".apexyard/hooks/$lib" "$SAFETY_DIR/.apexyard/hooks/$lib"
done

# ----- write manifests -------------------------------------------------------
SHA="$(upstream_sha)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_manifest() {
  local pack="$1"
  local dest="$2"
  local manifest="$dest/EXTRACTION_MANIFEST.json"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would write manifest: $manifest"
    return 0
  fi
  mkdir -p "$dest"
  {
    printf '{\n'
    printf '  "subpack": "%s",\n' "$pack"
    printf '  "upstream_repo": "me2resh/apexyard",\n'
    printf '  "upstream_sha": "%s",\n' "$SHA"
    printf '  "extracted_at": "%s",\n' "$NOW"
    printf '  "extracted_by": "bin/extract-subpacks.sh",\n'
    printf '  "files": [\n'
    local first=1
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      local rel="${f#$dest/}"
      [ "$rel" = "EXTRACTION_MANIFEST.json" ] && continue
      [ "$rel" = "README.md" ] && continue
      [ "$rel" = "PLUGIN.json" ] && continue
      [ "$rel" = ".apexyard/settings.snippet.json" ] && continue
      if [ "$first" -eq 1 ]; then
        first=0
      else
        printf ',\n'
      fi
      printf '    "%s"' "$rel"
    done < <(find "$dest" -type f | LC_ALL=C sort)
    printf '\n  ]\n'
    printf '}\n'
  } > "$manifest"
}

write_manifest "audit-pack"   "$AUDIT_DIR"
write_manifest "safety-hooks" "$SAFETY_DIR"

# ----- summary ---------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  say ""
  say "DRY RUN — no files written. Exit 0."
  exit 0
fi

audit_count=$(find "$AUDIT_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
safety_count=$(find "$SAFETY_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')

say ""
say "Extraction complete (upstream SHA: $SHA)"
say "  audit-pack:   $audit_count files at $AUDIT_DIR"
say "  safety-hooks: $safety_count files at $SAFETY_DIR"
say ""
say "Next steps:"
say "  1. Review marketplace/<pack>/EXTRACTION_MANIFEST.json"
say "  2. Run .apexyard/hooks/tests/test_subpack_extraction.sh to verify"
say "     no framework-distinctive elements leaked"
say "  3. On a release tag, push to the marketplace (manual operator step in v1)"
