#!/bin/bash
# _lib-ops-root.sh — shared OPS_ROOT discovery for hooks and skills.
#
# An "ops root" is the directory containing one of:
#
#   1. a `.apexyard-fork` marker file (v2 layout, framework ≥ #242), OR
#   2. BOTH `onboarding.yaml` AND `apexyard.projects.yaml` (legacy v1
#      layout — pre-v2 single-fork OR pre-v2 split-portfolio adopters).
#
# Hooks that write or read framework session state (`.apexyard/session/*`)
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
# -----------------------------------------------------------------------
# PIN-FIRST, WALK-UP-FALLBACK RESOLUTION (apexyard#381)
# -----------------------------------------------------------------------
#
# The walk-up alone has a sharp edge: if a hook runs from a cwd inside
# an UNRELATED ops-fork-shaped directory tree, the walk resolves to
# THAT tree, not the operator's real ops fork. The motivating incident:
# the code-reviewer sub-agent (Rex) was reviewing a PR by cloning the
# fork into /tmp and `cd`ing into the clone before resolving
# MARKER_HOME. A /tmp ops-fork clone satisfies the anchor conditions,
# so the walk resolved to the throwaway clone; the <pr>-rex.approved
# marker landed in /tmp instead of the real ops fork, and the merge
# gate (running from the real ops fork) couldn't find it.
#
# Mitigation: a SessionStart hook (`pin-ops-root.sh`) captures the
# launch-cwd ops root and writes it to
# `${APEXYARD_OPS_PIN_DIR:-$HOME/.apexyard/pins}/ops-root-<SESSION_ID>`.
# `resolve_ops_root` consults the pin BEFORE walking up. Stale pins
# self-heal because the pinned path is re-validated against the anchor
# conditions; a pin pointing at a dir that no longer satisfies the
# anchors is ignored and the walk-up runs.
#
# Escape hatches:
#   - APEXYARD_OPS_DISABLE_PIN=1     → ignore the pin, use walk-up only
#   - APEXYARD_OPS_PIN_DIR=<dir>     → override the pin directory
#   - CLAUDE_CODE_SESSION_ID unset   → no pin lookup, walk-up only
#
# Spaced-path safety: the pin file is written by `pin-ops-root.sh` with
# `printf '%s\n' "$path"` and read here with `IFS= read -r` so paths
# containing spaces survive the round-trip intact.
#
# No-regression guarantee: if the pin is absent for any reason (no
# session id, no pin dir, stale pin, escape hatch set), resolution
# falls back to `resolve_ops_root_walk` — the pure walk-up that was
# this lib's only behaviour before #381. Worst case is no improvement,
# never worse.
#
# Functions:
#   resolve_ops_root [start_dir]
#       Pin-first (when available + valid), then walk up from start_dir
#       (default: $PWD) toward / looking for a directory that satisfies
#       either anchor condition.
#       Echoes the path on success; echoes nothing and returns 0 on miss
#       (caller is expected to fall back to start_dir or a sensible
#       default).
#
#   resolve_ops_root_walk [start_dir]
#       Pure walk-up — never consults the pin. Used by `pin-ops-root.sh`
#       itself (to avoid a self-referential lookup at pin-write time)
#       and by any caller that explicitly wants pinless resolution.
#
# Sourced by hooks; never executed directly.

[ -n "${_LIB_OPS_ROOT_SOURCED:-}" ] && return 0
_LIB_OPS_ROOT_SOURCED=1

# Pure walk-up. Recognises BOTH the v2 .apexyard-fork marker AND the
# legacy v1 (onboarding.yaml + apexyard.projects.yaml) pair. Never
# touches the pin.
resolve_ops_root_walk() {
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

# Validate that a candidate path satisfies one of the ops-root anchor
# conditions. Returns 0 if valid, 1 otherwise. Used to re-check a
# pinned path before trusting it.
_ops_root_anchor_valid() {
  local r="$1"
  [ -n "$r" ] || return 1
  [ -d "$r" ] || return 1
  if [ -f "$r/.apexyard-fork" ]; then
    return 0
  fi
  if [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ]; then
    return 0
  fi
  return 1
}

# Pin-first resolver. Tries the pin file (when available + valid),
# falls back to walk-up. See header for the full strategy.
resolve_ops_root() {
  local start="${1:-$PWD}"

  # Pin check — only when the session id is available and the escape
  # hatch isn't set. Any failure here silently falls through to walk-up.
  if [ -z "${APEXYARD_OPS_DISABLE_PIN:-}" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    local pin_dir="${APEXYARD_OPS_PIN_DIR:-$HOME/.apexyard/pins}"
    local pin_file="$pin_dir/ops-root-${CLAUDE_CODE_SESSION_ID}"
    if [ -f "$pin_file" ]; then
      local pinned=""
      # Read one line preserving spaces. IFS= so leading/trailing
      # whitespace inside the path survives; -r so backslashes are
      # literal. The single read is the whole file; we ignore any
      # subsequent lines (defensive against future format expansion).
      IFS= read -r pinned < "$pin_file" || pinned=""
      if [ -n "$pinned" ] && _ops_root_anchor_valid "$pinned"; then
        printf '%s' "$pinned"
        return 0
      fi
      # Pin present but stale (path no longer satisfies anchors).
      # Fall through to walk-up — self-healing.
    fi
  fi

  resolve_ops_root_walk "$start"
}
