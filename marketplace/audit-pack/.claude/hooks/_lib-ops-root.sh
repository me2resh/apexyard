#!/bin/bash
# _lib-ops-root.sh — shared OPS_ROOT discovery for hooks and skills.
#
# An "ops root" is the directory containing one of:
#
#   1. a `.apexyard-fork` marker file (v2 layout, framework ≥ #242), OR
#   2. BOTH `onboarding.yaml` AND `apexyard.projects.yaml` (legacy v1
#      layout — pre-v2 single-fork OR pre-v2 split-portfolio adopters).
#
# Hooks that write or read framework session state (`.claude/session/*`)
# need this to resolve consistently regardless of cwd. The failure mode
# is real: when the operator works inside a managed-project workspace
# clone at `workspace/<project>/`, `git rev-parse --show-toplevel`
# returns the project clone, NOT the ops fork. Hooks that wrote markers
# under the ops fork (e.g. via `require-active-ticket.sh`'s OPS_ROOT
# walk) ended up invisible to merge-gate hooks that resolved REPO_ROOT
# via plain `git rev-parse`.
#
# Why a marker file: split-portfolio v2 (#242) moves both `onboarding.yaml`
# AND `apexyard.projects.yaml` to the private sibling repo. The legacy
# walk-up condition (BOTH files at the candidate dir) is no longer
# satisfied by the public fork, so we need a presence-only anchor that
# survives the move. `.apexyard-fork` is written by `/setup` at first
# run and by `/update` during the v2 migration. Single-fork adopters
# also benefit from the marker (set by `/setup`) but the legacy walk
# remains a fallback for un-migrated forks.
#
# Functions:
#   resolve_ops_root [start_dir]
#       Walks up from start_dir (default: $PWD) toward / looking for a
#       directory that satisfies either anchor condition.
#       Echoes the path on success; echoes nothing and returns 0 on miss
#       (caller is expected to fall back to start_dir or a sensible
#       default).
#
# Sourced by hooks; never executed directly.

[ -n "${_LIB_OPS_ROOT_SOURCED:-}" ] && return 0
_LIB_OPS_ROOT_SOURCED=1

resolve_ops_root() {
  local start="${1:-$PWD}"
  local r="$start"
  while [ -n "$r" ] && [ "$r" != "/" ]; do
    # v2 anchor (preferred): the explicit .apexyard-fork marker file.
    # Presence-only — content is ignored. Cheapest test runs first.
    if [ -f "$r/.apexyard-fork" ]; then
      printf '%s' "$r"
      return 0
    fi
    # Legacy v1 anchor: both fork-root files present. Covers
    # un-migrated single-fork AND un-migrated split-portfolio adopters.
    if [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ]; then
      printf '%s' "$r"
      return 0
    fi
    r=$(dirname "$r")
  done
  return 0
}
