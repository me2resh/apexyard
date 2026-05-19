#!/bin/bash
# _lib-migration-chain.sh — detect the current framework version anchor,
# discover the chain of intermediate-release migrations needed to reach
# a target version, and shell out to each per-pair migration script.
#
# Source this library from /update (and from the smoke test).
#
# Usage:
#   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-migration-chain.sh"
#   current=$(migration_current_version)        # e.g. v1.2.0 or "unknown"
#   tags=$(migration_known_versions)            # newline-separated, ascending
#   chain=$(migration_chain "$current" "v1.4.0")  # newline-separated pairs
#                                                  # e.g. v1.2.0-to-v1.3.0
#                                                  #      v1.3.0-to-v1.4.0
#   migration_write_anchor "v1.4.0"             # persist the new version
#
# Version anchor lives at <ops_fork_root>/.claude/framework-version.
# Single-line "vMAJOR.MINOR.PATCH". Written by /update on every successful
# sync. See AgDR-0032.
#
# Design notes (kept here so the rationale travels with the code):
#   - The anchor is a separate file (not a git-derived signal) because
#     adopters routinely rewrite history (squash-merge, rebase) and an
#     anchor that depends on tag presence would silently drift.
#   - We treat semver-tagged versions as the discrete units. Pre-release
#     suffixes (v1.4.0-rc1) and dev branches are deliberately out of
#     scope — /update --from-dev keeps its own pre-release shape.
#   - Chain ordering is strictly ascending. Out-of-order replay is
#     refused by migration_chain — it returns the empty string if the
#     ordering is wrong.

# ---------------------------------------------------------------------------
# _migration_ops_root — same walk as _lib-portfolio-paths.sh but inlined so
# we don't take a dependency on that helper just to find a file. Callers
# can override by passing OPS_ROOT in the env.
# ---------------------------------------------------------------------------
_migration_ops_root() {
  if [ -n "${OPS_ROOT:-}" ]; then
    echo "$OPS_ROOT"
    return 0
  fi
  local r
  r=$(git rev-parse --show-toplevel 2>/dev/null) || r=""
  [ -n "$r" ] || return 0
  local cur="$r"
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    if [ -f "$cur/.apexyard-fork" ]; then
      echo "$cur"
      return 0
    fi
    if [ -f "$cur/onboarding.yaml" ] && [ -f "$cur/apexyard.projects.yaml" ]; then
      echo "$cur"
      return 0
    fi
    cur=$(dirname "$cur")
  done
  echo "$r"
}

# ---------------------------------------------------------------------------
# migration_anchor_path — absolute path to the version anchor file.
# ---------------------------------------------------------------------------
migration_anchor_path() {
  local root
  root=$(_migration_ops_root)
  [ -n "$root" ] || return 1
  echo "$root/.claude/framework-version"
}

# ---------------------------------------------------------------------------
# migration_current_version — read the anchor. Returns:
#   - the recorded version (e.g. "v1.2.0")
#   - "unknown" if the anchor is missing OR malformed
# Prints nothing to stderr — callers decide how to surface "unknown".
# ---------------------------------------------------------------------------
migration_current_version() {
  local p
  p=$(migration_anchor_path) || { echo "unknown"; return 0; }
  if [ ! -f "$p" ]; then
    echo "unknown"
    return 0
  fi
  local raw
  raw=$(head -n 1 "$p" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$raw" ]; then
    echo "unknown"
    return 0
  fi
  # Accept vX.Y.Z (semver core, no pre-release suffix).
  if echo "$raw" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "$raw"
  else
    echo "unknown"
  fi
}

# ---------------------------------------------------------------------------
# migration_write_anchor <version> — persist the version anchor.
# Idempotent: same value → no-op. Different value → overwrite.
# ---------------------------------------------------------------------------
migration_write_anchor() {
  local v="$1"
  if [ -z "$v" ]; then
    echo "migration_write_anchor: missing version arg" >&2
    return 1
  fi
  if ! echo "$v" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "migration_write_anchor: invalid version '$v' (want vMAJOR.MINOR.PATCH)" >&2
    return 1
  fi
  local p
  p=$(migration_anchor_path) || return 1
  mkdir -p "$(dirname "$p")"
  printf '%s\n' "$v" > "$p"
}

# ---------------------------------------------------------------------------
# migration_known_versions — every version that has a migration script
# attached. Source of truth is the filenames in .claude/migrations/.
# Output: ascending semver order, newline-separated. Includes both the
# "from" and "to" sides of every pair (deduped).
# ---------------------------------------------------------------------------
migration_known_versions() {
  local root
  root=$(_migration_ops_root)
  [ -n "$root" ] || return 1
  local dir="$root/.claude/migrations"
  [ -d "$dir" ] || return 0

  # Filenames look like v1.2.0-to-v1.3.0.sh. Extract both sides.
  local f base from to
  for f in "$dir"/v*-to-v*.sh; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .sh)
    from=$(echo "$base" | sed -E 's/^(v[0-9]+\.[0-9]+\.[0-9]+)-to-v[0-9]+\.[0-9]+\.[0-9]+$/\1/')
    to=$(echo "$base"   | sed -E 's/^v[0-9]+\.[0-9]+\.[0-9]+-to-(v[0-9]+\.[0-9]+\.[0-9]+)$/\1/')
    [ -n "$from" ] && echo "$from"
    [ -n "$to" ] && echo "$to"
  done | sort -u -V
}

# ---------------------------------------------------------------------------
# _migration_semver_gt <a> <b> — return 0 if a > b in semver order, else 1.
# Used for ordering checks in migration_chain. Stripped of the leading 'v'.
# ---------------------------------------------------------------------------
_migration_semver_gt() {
  local a="${1#v}" b="${2#v}"
  # sort -V puts a < b on top. If a > b, a appears AFTER b in the sorted output.
  local top
  top=$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n 1)
  if [ "$top" = "$b" ] && [ "$a" != "$b" ]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# migration_chain <from> <to> — produce the ordered chain of migration
# pair names needed to go from <from> to <to>. Output is newline-separated,
# each line a pair-name (e.g. "v1.2.0-to-v1.3.0").
#
# Returns:
#   - empty output if from == to OR from > to OR from == "unknown" (caller
#     handles "unknown" branch separately)
#   - empty output if any expected pair in the chain is missing on disk
#     (we refuse to skip a step silently)
# Exits non-zero on argument errors.
# ---------------------------------------------------------------------------
migration_chain() {
  local from="$1" to="$2"
  if [ -z "$from" ] || [ -z "$to" ]; then
    echo "migration_chain: need <from> <to>" >&2
    return 1
  fi
  if [ "$from" = "unknown" ]; then
    return 0
  fi
  if [ "$from" = "$to" ]; then
    return 0
  fi
  if _migration_semver_gt "$from" "$to"; then
    # Going backwards — refuse.
    return 0
  fi

  local root dir
  root=$(_migration_ops_root)
  [ -n "$root" ] || return 1
  dir="$root/.claude/migrations"
  [ -d "$dir" ] || return 0

  # Collect all "from" sides of pair files; sort ascending.
  local pairs
  pairs=$(find "$dir" -maxdepth 1 -name 'v*-to-v*.sh' -exec basename {} \; 2>/dev/null \
          | sed 's/\.sh$//' | sort -V)

  if [ -z "$pairs" ]; then
    return 0
  fi

  # Greedy walk: start at $from. For each step, find a pair whose left side
  # equals the current marker; advance to its right side. Stop when we hit
  # $to. If we can't find the next step, emit nothing (the caller's "missing
  # link" branch fires).
  local current="$from"
  local chain=""
  local guard=0
  while [ "$current" != "$to" ]; do
    guard=$((guard+1))
    if [ "$guard" -gt 50 ]; then
      echo "migration_chain: walked >50 steps, aborting (cycle or runaway)" >&2
      return 1
    fi
    # Find the pair starting at $current.
    local match
    match=$(echo "$pairs" | grep -E "^${current}-to-v[0-9]+\.[0-9]+\.[0-9]+\$" | head -n 1)
    if [ -z "$match" ]; then
      # Missing link — bail.
      return 0
    fi
    chain="${chain}${match}
"
    # Advance current to the right-hand version.
    current=$(echo "$match" | sed -E 's/^v[0-9]+\.[0-9]+\.[0-9]+-to-(v[0-9]+\.[0-9]+\.[0-9]+)$/\1/')
    # Safety: if we've overshot $to (chain has versions newer than $to),
    # stop. The caller asked for from→to, so we don't apply newer pairs.
    if _migration_semver_gt "$current" "$to"; then
      return 0
    fi
  done
  # Trim trailing newline.
  printf '%s' "${chain%$'\n'}"
}

# ---------------------------------------------------------------------------
# migration_script_path <pair-name> — absolute path to the .sh script for
# a pair (e.g. v1.2.0-to-v1.3.0). Doesn't check existence; the caller does.
# ---------------------------------------------------------------------------
migration_script_path() {
  local pair="$1"
  local root
  root=$(_migration_ops_root)
  [ -n "$root" ] || return 1
  echo "$root/.claude/migrations/${pair}.sh"
}

# ---------------------------------------------------------------------------
# migration_run <pair-name> — execute the migration script with bash.
# The script is expected to:
#   - be idempotent (safe to re-run)
#   - stage changes via git add but NOT commit
#   - exit 0 (applied OR skipped — nothing to do is fine)
#   - exit 1 (conflict requires operator action)
#   - exit 2 (hard error)
# ---------------------------------------------------------------------------
migration_run() {
  local pair="$1"
  local script
  script=$(migration_script_path "$pair") || return 2
  if [ ! -f "$script" ]; then
    echo "migration_run: $pair missing at $script" >&2
    return 2
  fi
  bash "$script"
}
