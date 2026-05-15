#!/bin/bash
# _lib-ops-root.sh — shared OPS_ROOT discovery for hooks and skills.
#
# An "ops root" is the directory containing BOTH `onboarding.yaml` AND
# `apexyard.projects.yaml` — i.e. a configured ApexYard ops fork.
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
# This lib centralises the walk-up logic that 7+ existing hooks already
# duplicate inline (#229 + #230 fixed the merge-gate hooks; the others
# can be consolidated in a follow-up).
#
# Functions:
#   resolve_ops_root [start_dir]
#       Walks up from start_dir (default: $PWD) toward / looking for a
#       directory with both onboarding.yaml AND apexyard.projects.yaml.
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
    if [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ]; then
      printf '%s' "$r"
      return 0
    fi
    r=$(dirname "$r")
  done
  return 0
}
