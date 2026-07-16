#!/bin/bash
# _lib-fresh-fork.sh — single source of truth for "is this an apexyard fork,
# and has it been configured yet?"
#
# Extracted (behaviour-preserving) from onboarding-check.sh per AgDR-0098.
# The guided first-run onboarding PRD's Technical Constraint forbids a
# second, competing fresh-fork detection mechanism — both
# onboarding-check.sh (SessionStart hook) and /onboard source this file and
# call the same function, so there is exactly one implementation.
#
# Functions (sourced; do not exec this file directly):
#   fresh_fork_state()
#       Echoes one of: fresh | configured | not-a-fork ; always exits 0.
#   fresh_fork_config_path()
#       Echoes the resolved onboarding.yaml path this lib actually checked
#       (in-fork default, or the split-portfolio v2 sibling-repo override).
#       Empty string if there's no git toplevel at all. Callers that need
#       to distinguish "config file missing" from "config file present but
#       placeholder" (e.g. to pick a message) should check THIS path, not
#       a hardcoded in-fork default — otherwise split-portfolio v2 forks
#       (whose real onboarding.yaml lives in the sibling repo) mis-render.
#
# Detection rules (identical to the pre-extraction onboarding-check.sh —
# see docs/technical-designs/onboarding-increment-1.md § D2):
#   - No onboarding.yaml at the resolved path:
#       - onboarding.example.yaml present  → fresh (an apexyard fork that
#         hasn't been configured yet, per the #517 gitignored-config model)
#       - onboarding.example.yaml absent   → not-a-fork
#   - onboarding.yaml present:
#       - company.name still the placeholder "Your Company Name" → fresh
#       - otherwise                                               → configured
#
# Path resolution goes through portfolio_onboarding_path (from
# _lib-portfolio-paths.sh) so split-portfolio v2 adopters (onboarding.yaml
# committed in the private sibling repo) resolve correctly, exactly like
# every other consumer of that helper.
#
# Contract: read-only. No writes, no network calls. Safe to call from a
# SessionStart hook and from a bootstrap skill alike.
#
# Usage:
#   source ".../_lib-fresh-fork.sh"
#   state=$(fresh_fork_state)   # fresh | configured | not-a-fork

# Don't run twice in the same shell.
[ -n "${_LIB_FRESH_FORK_SOURCED:-}" ] && return 0
_LIB_FRESH_FORK_SOURCED=1

# Locate the lib's own dir so we can source siblings (read-config, portfolio-paths).
_FRESH_FORK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$_FRESH_FORK_LIB_DIR/_lib-read-config.sh" ]; then
  # shellcheck source=/dev/null
  . "$_FRESH_FORK_LIB_DIR/_lib-read-config.sh"
fi
if [ -f "$_FRESH_FORK_LIB_DIR/_lib-portfolio-paths.sh" ]; then
  # shellcheck source=/dev/null
  . "$_FRESH_FORK_LIB_DIR/_lib-portfolio-paths.sh"
fi

# Internal: resolve the onboarding.yaml path this lib checks, given a repo
# root. Shared by fresh_fork_state() and the public fresh_fork_config_path()
# so there is exactly one resolution — not one inline in each.
_fresh_fork_resolve_config() {
  local repo_root="$1"
  local config=""

  # Resolve onboarding.yaml through the portfolio helper so split-portfolio
  # v2 adopters get the sibling repo's copy. Falls back to the in-fork
  # default (single-fork mode, or the helper unavailable) — same fallback
  # onboarding-check.sh used pre-extraction.
  if command -v portfolio_onboarding_path >/dev/null 2>&1; then
    config=$(portfolio_onboarding_path 2>/dev/null)
  fi
  if [ -z "$config" ]; then
    config="$repo_root/onboarding.yaml"
  fi
  echo "$config"
}

fresh_fork_state() {
  local repo_root config

  repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$repo_root" ]; then
    echo "not-a-fork"
    return 0
  fi

  config=$(_fresh_fork_resolve_config "$repo_root")

  if [ ! -f "$config" ]; then
    if [ -f "$repo_root/onboarding.example.yaml" ]; then
      echo "fresh"
    else
      echo "not-a-fork"
    fi
    return 0
  fi

  if grep -q '"Your Company Name"' "$config" 2>/dev/null; then
    echo "fresh"
  else
    echo "configured"
  fi
  return 0
}

fresh_fork_config_path() {
  local repo_root

  repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$repo_root" ]; then
    echo ""
    return 0
  fi

  _fresh_fork_resolve_config "$repo_root"
  return 0
}
