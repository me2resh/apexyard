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
# `${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-<SESSION_ID>`.
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

  # Case-insensitive-filesystem safety (me2resh/apexyard#1104): a literal
  # $start/$PWD string can carry a different case than the on-disk
  # directory name — bash's `cd`/`pwd -P` do NOT re-case (verified: `cd
  # lowercase-path && pwd -P` returns "lowercase-path" unchanged on both
  # GNU bash 5.x and macOS's stock /bin/bash 3.2), so whatever case the
  # operator typed or the harness launched with survives untouched.
  # `_lib-portfolio-paths.sh`'s `_portfolio_root()` anchors on `git
  # rev-parse --show-toplevel` instead, which resolves via the OS and
  # always returns the canonical on-disk case regardless of the case used
  # to invoke it. Anchor THIS walk on the exact same base so the two
  # independent ops-root resolvers can't disagree purely on case — when
  # they did, a case-only difference between a pinned/cwd-derived root
  # and a git-rev-parse-derived portfolio path got misread as "two
  # distinct repos" (a phantom split-portfolio banner on a plain
  # single-fork setup). Falls back to the raw (possibly non-canonical)
  # `start` unchanged when not inside a git repo — same contract as
  # before; there is nothing to canonicalize against in that case.
  local canon
  canon=$(cd "$start" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || canon=""
  [ -n "$canon" ] && start="$canon"

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
    parent=$(dirname "$r"); [ "$parent" = "$r" ] && break; r="$parent"
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

# ------------------------------------------------------------------------
# resolve_anchored_lib_dir RAW_BASH_SOURCE_0
# ------------------------------------------------------------------------
# THE single self-location entry point every _lib-*.sh sibling-sourcing call
# site should use, replacing the four independent spellings a #1100 security
# review found still in the wild (me2resh/apexyard#1102 / AgDR-0118):
#   - ${BASH_SOURCE[0]:-}          (no anchored fallback for the empty case)
#   - ${BASH_SOURCE[0]}            (no `:-` guard at all)
#   - ${BASH_SOURCE[0]:-$0}        (a FAKE fix -- $0 in a sourced file under
#                                    zsh is the sourcing path AS TYPED, not a
#                                    reliable self-location signal; it
#                                    inherits the exact same hazard)
#
# RAW_BASH_SOURCE_0 must be the CALLER's own ${BASH_SOURCE[0]:-} value,
# passed explicitly -- a function defined in a sourced lib cannot see the
# caller's own array slot 0 (BASH_SOURCE[0] *inside this function* refers to
# THIS file, not the caller's).
#
# The fix is a SINGLE fail-closed guard: when RAW_BASH_SOURCE_0 is empty
# (the zsh case -- BASH_SOURCE is unset under a non-bash sourcing shell),
# refuse to derive anything from it. `dirname ""` resolves to `.`, which
# silently substitutes the CALLER's $PWD for the script's own directory --
# exactly the hazard #1062/#1100 closed for nine other sites. This layer
# can never itself be centralized behind a sourced function: to source
# THIS file safely in the first place you must already have solved the
# exact problem this layer solves (you can't call a function in a file you
# haven't located yet). Every call site therefore still computes
# RAW_BASH_SOURCE_0 = ${BASH_SOURCE[0]:-} inline, once, before it can even
# reach this function -- see each site's own "SELF-LOCATION BOOTSTRAP"
# comment. What #1102 removes is the DRIFT: four different (two of them
# actively broken) spellings of this guard, collapsed into one function.
#
# NOT anchored to an ops-root marker (.apexyard-fork / onboarding.yaml +
# apexyard.projects.yaml) — deliberately. An earlier version of this fix
# added that as a second "defense in depth" layer, but three of the four
# #1102 call sites (_lib-protected-branches.sh, _lib-git-hooks-path.sh,
# _lib-extract-push-ref.sh) are hook libs deployed into EVERY project's own
# `.claude/hooks/`, including managed projects that are never the apexyard
# ops fork itself and correctly have neither marker. Requiring an ops-root
# anchor on those sites silently broke real usage (protected-branches
# config in a managed project resolved to the framework default instead of
# the project's own `.git.protected_branches[]`, caught by
# test_lib_protected_branches.sh) — over-strictness that fails in the
# UNSAFE direction for a security control (fail-closed-to-a-DIFFERENT-
# answer is not the same as fail-closed-to-blocked). Only
# _lib-read-config.sh's OWN portfolio-root resolution genuinely wants the
# ops-root anchor semantics, and it applies that anchor itself, inline,
# rather than through this shared function -- see its own "FALLBACK —
# ANCHORED BY DEFAULT" comment. The bootstrap guard alone (never substitute
# cwd for an unavailable BASH_SOURCE[0]) is what actually closes the
# reported bug; the ops-root anchor was scope creep beyond it.
#
# Echoes the verified directory and returns 0 on success. Returns 1 with
# nothing echoed when RAW_BASH_SOURCE_0 is empty or unresolvable -- callers
# MUST treat empty output as "self-location unavailable" (typically: this
# script was sourced under a non-bash shell) and skip sourcing the sibling
# they wanted, never fall back to raw cwd or $0. This trades a rare
# real-fork-under-zsh miss for closing a real cwd-substitution hole; the
# already-shipped `_lib-read-config.sh` zsh warning documents the same
# trade-off ("run these helpers under bash, not zsh").
resolve_anchored_lib_dir() {
  local raw="${1:-}"
  [ -n "$raw" ] || return 1

  local dir
  dir="$(cd "$(dirname "$raw")" 2>/dev/null && pwd)" || return 1
  [ -n "$dir" ] || return 1

  printf '%s' "$dir"
  return 0
}

# Pin-first resolver. Tries the pin file (when available + valid),
# falls back to walk-up. See header for the full strategy.
resolve_ops_root() {
  local start="${1:-$PWD}"

  # Pin check — only when the session id is available and the escape
  # hatch isn't set. Any failure here silently falls through to walk-up.
  if [ -z "${APEXYARD_OPS_DISABLE_PIN:-}" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    local pin_dir="${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}"
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
