#!/bin/bash
# v3.1.4 → v4.0.0 migration: model-neutral ApexYard refactor
#
# This release moves the canonical framework content from `.claude/` to
# `.apexyard/`. `.claude/` and `.kimi-code/` become generated registration
# layers synced from `.apexyard/` by `bin/apexyard-sync-tool-dirs`.
#
# This migration preserves adopter-local state and configuration that lived
# under the old `.claude/` canonical layout:
#
#   - `.claude/project-config.json`  → `.apexyard/project-config.json`
#   - `.claude/session/`             → `.apexyard/session/`
#
# It then regenerates `.claude/` and `.kimi-code/` from `.apexyard/` so the
# generated layers match the new canonical source.
#
# Idempotent: each move is gated on "source present AND target absent" so
# re-running after a successful run does nothing. The sync step is also
# idempotent.
#
# Exit codes:
#   0 — applied or skipped (success either way)
#   1 — conflict requires operator (e.g. config in both locations)
#   2 — hard error (missing deps, cannot locate ops root)
#
# Env knobs:
#   APEXYARD_MIGRATION_QUIET  1 to suppress informational stdout

set -u

QUIET="${APEXYARD_MIGRATION_QUIET:-0}"

info() { [ "$QUIET" = "1" ] || echo "$@"; }
warn() { echo "$@" >&2; }

# --- find the ops fork root --------------------------------------------------
find_ops_root() {
  local r cur
  r=$(git rev-parse --show-toplevel 2>/dev/null) || r=""
  if [ -z "$r" ]; then
    pwd
    return 0
  fi
  cur="$r"
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    [ -f "$cur/.apexyard-fork" ] && { echo "$cur"; return 0; }
    if [ -f "$cur/onboarding.yaml" ] && [ -f "$cur/apexyard.projects.yaml" ]; then
      echo "$cur"; return 0
    fi
    cur=$(dirname "$cur")
  done
  echo "$r"
}

OPS_ROOT=$(find_ops_root)
cd "$OPS_ROOT" || { warn "migration v3.1.4→v4.0.0: cannot cd to ops root $OPS_ROOT"; exit 2; }

if [ ! -d ".apexyard" ]; then
  warn "migration v3.1.4→v4.0.0: no .apexyard/ directory found at $OPS_ROOT"
  warn "  This migration expects the model-neutral refactor to already be present."
  exit 2
fi

info "migration v3.1.4→v4.0.0: model-neutral refactor"

# --- move .claude/project-config.json → .apexyard/project-config.json --------
if [ -f ".claude/project-config.json" ]; then
  if [ ! -f ".apexyard/project-config.json" ]; then
    mv ".claude/project-config.json" ".apexyard/project-config.json"
    git add ".apexyard/project-config.json" 2>/dev/null || true
    git rm -f ".claude/project-config.json" 2>/dev/null || rm -f ".claude/project-config.json"
    info "  ✓ moved .claude/project-config.json → .apexyard/project-config.json"
  else
    # Both exist — attempt a shallow merge (adopter keys win).
    if command -v jq >/dev/null 2>&1; then
      TMP=$(mktemp)
      if jq -s '.[0] * .[1]' ".apexyard/project-config.json" ".claude/project-config.json" > "$TMP" 2>/dev/null; then
        mv "$TMP" ".apexyard/project-config.json"
        git add ".apexyard/project-config.json" 2>/dev/null || true
        git rm -f ".claude/project-config.json" 2>/dev/null || rm -f ".claude/project-config.json"
        info "  ✓ merged .claude/project-config.json into .apexyard/project-config.json"
      else
        rm -f "$TMP"
        warn "migration v3.1.4→v4.0.0: both .claude/project-config.json and .apexyard/project-config.json exist, and merge failed."
        warn "  Resolve manually, then re-run this migration."
        exit 1
      fi
    else
      warn "migration v3.1.4→v4.0.0: both .claude/project-config.json and .apexyard/project-config.json exist, but jq is not installed."
      warn "  Install jq or merge the files manually, then re-run this migration."
      exit 1
    fi
  fi
fi

# --- move .claude/session/ → .apexyard/session/ ------------------------------
if [ -d ".claude/session" ]; then
  if [ ! -d ".apexyard/session" ]; then
    mv ".claude/session" ".apexyard/session"
    # Session state is gitignored; do not attempt git add/remove.
    info "  ✓ moved .claude/session/ → .apexyard/session/"
  else
    warn "migration v3.1.4→v4.0.0: both .claude/session/ and .apexyard/session/ exist."
    warn "  Move any active ticket/review markers you need from .claude/session/ to .apexyard/session/, then re-run this migration."
    exit 1
  fi
fi

# --- regenerate generated tool directories -----------------------------------
if [ -x "bin/apexyard-sync-tool-dirs" ]; then
  bash "bin/apexyard-sync-tool-dirs" >/dev/null 2>&1 || {
    warn "migration v3.1.4→v4.0.0: bin/apexyard-sync-tool-dirs failed."
    warn "  Run it manually after resolving any staged changes."
    exit 2
  }
  info "  ✓ regenerated .claude/ and .kimi-code/ from .apexyard/"
else
  warn "migration v3.1.4→v4.0.0: bin/apexyard-sync-tool-dirs not found or not executable."
  warn "  Run it manually after the sync."
  exit 2
fi

info "migration v3.1.4→v4.0.0: complete."
info "  Review staged changes with: git diff --cached"
info "  Review working-tree changes with: git status"
exit 0
