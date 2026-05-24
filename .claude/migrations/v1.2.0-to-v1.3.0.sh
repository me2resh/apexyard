#!/bin/bash
# v1.2.0 → v1.3.0 migration: split-portfolio v1 → v2 (data move)
#
# v1.3.0 absorbed onboarding.yaml AND workspace/<name>/ into the private
# sibling repo for split-portfolio adopters. This script automates the
# per-file-class move for adopters who:
#
#   (a) are on the v1 split-portfolio layout (have a portfolio: block in
#       .claude/project-config.json but no .apexyard-fork anchor file), and
#   (b) still have onboarding.yaml OR workspace/<name>/ in the public fork
#
# Adopters on single-fork mode hit a no-op branch — neither precondition
# applies, exit 0 silently.
#
# Idempotent: each move is gated on "source present AND target absent" so
# re-running after a successful run does nothing. Operator-confirmable: the
# script PROMPTS per file class via APEXYARD_MIGRATION_PROMPT (default y).
# Stages changes via `git add`, never commits.
#
# Exit codes:
#   0 — applied or skipped (success either way)
#   1 — conflict requires operator (e.g. file in both places, can't pick)
#   2 — hard error (missing deps, bad config)
#
# Env knobs (defaults match interactive use; tests set these to non-interactive):
#   APEXYARD_MIGRATION_PROMPT  yes (default) | onboarding | workspace | none
#   APEXYARD_MIGRATION_QUIET   1 to suppress informational stdout

set -u

QUIET="${APEXYARD_MIGRATION_QUIET:-0}"
PROMPT="${APEXYARD_MIGRATION_PROMPT:-yes}"

info() { [ "$QUIET" = "1" ] || echo "$@"; }
warn() { echo "$@" >&2; }

if ! command -v jq >/dev/null 2>&1; then
  warn "migration v1.2.0→v1.3.0: jq required (split-portfolio config parse). Skipping."
  exit 0
fi

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
cd "$OPS_ROOT" || { warn "migration v1.2.0→v1.3.0: cannot cd to ops root $OPS_ROOT"; exit 2; }

PCONFIG=".claude/project-config.json"

# --- detect "this adopter is on v1 split-portfolio" --------------------------
# Conditions: portfolio block exists, .apexyard-fork marker absent (still v1
# layout). Single-fork adopters lack the portfolio block entirely → no-op.
if [ ! -f "$PCONFIG" ]; then
  info "migration v1.2.0→v1.3.0: no $PCONFIG — single-fork mode, no migration needed."
  exit 0
fi

HAS_PORTFOLIO=$(jq -e '.portfolio.registry // empty' "$PCONFIG" >/dev/null 2>&1 && echo 1 || echo 0)
HAS_V2_ANCHOR=0
[ -f .apexyard-fork ] && HAS_V2_ANCHOR=1

if [ "$HAS_PORTFOLIO" != "1" ]; then
  info "migration v1.2.0→v1.3.0: no portfolio block — single-fork mode, no migration needed."
  exit 0
fi

if [ "$HAS_V2_ANCHOR" = "1" ]; then
  info "migration v1.2.0→v1.3.0: .apexyard-fork marker present — already on v2 layout."
  exit 0
fi

# --- resolve sibling root from existing portfolio.registry -------------------
SIBLING_ROOT=$(dirname "$(jq -r '.portfolio.registry' "$PCONFIG")")
if [ -z "$SIBLING_ROOT" ] || [ ! -d "$SIBLING_ROOT" ]; then
  warn "migration v1.2.0→v1.3.0: sibling private repo not found at '$SIBLING_ROOT'"
  warn "  Check portfolio.registry in $PCONFIG."
  exit 2
fi

info "migration v1.2.0→v1.3.0: split-portfolio v1 detected"
info "  Sibling private repo: $SIBLING_ROOT"

# --- ask the operator (per file class) ---------------------------------------
do_onboarding=0
do_workspace=0
case "$PROMPT" in
  yes)
    do_onboarding=1
    do_workspace=1
    ;;
  onboarding)
    do_onboarding=1
    ;;
  workspace)
    do_workspace=1
    ;;
  none|no)
    info "migration v1.2.0→v1.3.0: APEXYARD_MIGRATION_PROMPT=$PROMPT — skipping moves, only marker + config keys."
    ;;
  *)
    warn "migration v1.2.0→v1.3.0: unknown APEXYARD_MIGRATION_PROMPT='$PROMPT' — defaulting to yes."
    do_onboarding=1
    do_workspace=1
    ;;
esac

# --- move onboarding.yaml ----------------------------------------------------
if [ "$do_onboarding" = "1" ]; then
  if [ -f onboarding.yaml ] && [ ! -f "$SIBLING_ROOT/onboarding.yaml" ]; then
    mv onboarding.yaml "$SIBLING_ROOT/onboarding.yaml"
    ( cd "$SIBLING_ROOT" 2>/dev/null && git add onboarding.yaml 2>/dev/null ) || true
    info "  ✓ moved onboarding.yaml → $SIBLING_ROOT/"
  elif [ -f onboarding.yaml ] && [ -f "$SIBLING_ROOT/onboarding.yaml" ]; then
    warn "migration v1.2.0→v1.3.0: onboarding.yaml exists in BOTH locations."
    warn "  Resolve manually before re-running."
    exit 1
  fi
fi

# --- move workspace/* (preserve workspace/README.md framework file) ----------
if [ "$do_workspace" = "1" ]; then
  if [ -d workspace ] && [ "$(ls -A workspace 2>/dev/null)" ]; then
    mkdir -p "$SIBLING_ROOT/workspace"
    for entry in workspace/*; do
      [ -e "$entry" ] || continue
      name=$(basename "$entry")
      # workspace/README.md is a framework artefact — stays in the public fork.
      if [ "$name" = "README.md" ]; then
        continue
      fi
      if [ -e "$SIBLING_ROOT/workspace/$name" ]; then
        warn "  WARN: workspace/$name exists in BOTH locations — skipped."
        continue
      fi
      mv "$entry" "$SIBLING_ROOT/workspace/$name"
      info "  ✓ moved workspace/$name → $SIBLING_ROOT/workspace/"
    done
  fi
fi

# --- update .gitignore in the public fork ------------------------------------
NEEDS=()
grep -qxF onboarding.yaml .gitignore 2>/dev/null || NEEDS+=(onboarding.yaml)
grep -qxF workspace .gitignore 2>/dev/null || NEEDS+=(workspace)
if [ "${#NEEDS[@]}" -gt 0 ]; then
  {
    echo ""
    echo "# Split-portfolio v2 (framework ≥ v1.3.0): onboarding + workspace live in the private sibling repo."
    for n in "${NEEDS[@]}"; do echo "$n"; done
  } >> .gitignore
  git add .gitignore 2>/dev/null || true
  info "  ✓ updated .gitignore (added ${NEEDS[*]})"
fi

# --- write the .apexyard-fork anchor -----------------------------------------
if [ ! -f .apexyard-fork ]; then
  echo "# This file marks the directory as an ApexYard ops fork (split-portfolio v2)." > .apexyard-fork
  git add .apexyard-fork 2>/dev/null || true
  info "  ✓ wrote .apexyard-fork marker"
fi

# --- add v2 keys to .claude/project-config.json ------------------------------
TMP=$(mktemp)
jq --arg onb "$SIBLING_ROOT/onboarding.yaml" \
   --arg ws  "$SIBLING_ROOT/workspace" \
   '.portfolio.onboarding = (.portfolio.onboarding // $onb)
    | .portfolio.workspace_dir = (.portfolio.workspace_dir // $ws)' \
   "$PCONFIG" > "$TMP" && mv "$TMP" "$PCONFIG"
git add "$PCONFIG" 2>/dev/null || true
info "  ✓ added portfolio.{onboarding,workspace_dir} keys to $PCONFIG"

info "migration v1.2.0→v1.3.0: complete."
info "  Public-fork changes staged for review (git diff --cached)."
info "  Don't forget to commit the sibling repo too:"
info "    cd $SIBLING_ROOT && git status"
exit 0
