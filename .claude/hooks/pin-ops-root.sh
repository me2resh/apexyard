#!/bin/bash
# SessionStart hook: pin the ops-fork root for this session.
#
# Background: hooks and sub-agents that need to write or read
# framework session state (`.claude/session/*`) resolve the ops-fork
# root via `_lib-ops-root.sh::resolve_ops_root`. Pre-#381 that function
# only had a walk-up implementation — it climbed from `$PWD` looking
# for the `.apexyard-fork` v2 marker or the legacy
# `onboarding.yaml` + `apexyard.projects.yaml` v1 pair.
#
# The walk-up has a sharp edge: if a hook runs from a cwd that happens
# to sit inside an UNRELATED ops-fork-shaped tree (e.g. a /tmp clone of
# the fork made for PR review), the walk resolves to that throwaway
# tree rather than the operator's real fork. The motivating incident:
# the `code-reviewer` sub-agent (Rex) cloned a fork into /tmp for
# review purposes, then `cd`'d into the clone before resolving
# MARKER_HOME. The clone satisfies the anchor conditions, so Rex
# resolved MARKER_HOME to /tmp; the `<pr>-rex.approved` marker landed
# there; the merge gate (running from the real ops fork) couldn't see
# it. Operators had to mirror the marker locally as a workaround.
#
# This hook closes that gap by capturing the launch-cwd ops root at
# session start — BEFORE any sub-agent or skill has had a chance to
# `cd` somewhere unrelated — and writing it to a per-session pin file:
#
#   ${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-<SESSION_ID>
#
# `resolve_ops_root` then consults the pin BEFORE walking up. Stale
# pins self-heal because the pinned path is re-validated against the
# anchor conditions and framework hook directory on read.
#
# Silent no-ops:
#   - CLAUDE_CODE_SESSION_ID unset                    → exit 0 (no pin)
#   - walk-up from $PWD fails to find an ops root     → exit 0 (no pin)
#   - pin already exists with the same path           → exit 0 (no-op)
#
# The pin is written once per session id: at startup, resume or fork, and at
# clear (a new session id) from CLAUDE_PROJECT_DIR. compact never writes.
#
# Spaced-path safety: the path is written with `printf '%s\n' "$path"`
# so the corresponding `IFS= read -r` in `_lib-ops-root.sh` reads it
# back intact. No `tr -d '[:space:]'` shenanigans here or there.

set -u
INPUT=$(cat)
[ -n "$INPUT" ] || INPUT='{}'
source_kind=$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null) || exit 2
# startup, resume and fork resolve from the launch directory ($PWD).
# clear issues a new session id with no pin (AgDR-0261 capture P12b). At
# clear, $PWD can follow a Bash cd inside the project, so clear resolves
# only from CLAUDE_PROJECT_DIR, which stays at the launch directory.
# compact keeps its session id and pin, so it never writes.
case "$source_kind" in
  startup|resume|fork) resolve_from="$PWD" ;;
  clear) resolve_from="${CLAUDE_PROJECT_DIR:-}"; [ -n "$resolve_from" ] || exit 0 ;;
  *) exit 0 ;;
esac

# Locate the lib relative to this script. The settings.json wrapper
# walks up to the ops fork before exec'ing us, so $0 is always at
# .claude/hooks/pin-ops-root.sh inside the ops fork.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$HOOK_DIR/_lib-ops-root.sh"

# Defensive: if the lib is missing the hook can't do anything useful.
# Silent exit (no banner) — same shape as the rest of the SessionStart
# chain.
if [ ! -f "$LIB" ]; then
  exit 0
fi

# Source the lib to get resolve_ops_root_walk. Use the WALK variant
# (not resolve_ops_root) to avoid self-referential pin lookup at
# pin-write time.
# shellcheck source=/dev/null
. "$LIB"

# No session id → no per-session pin to write. Common in scripted /
# CI contexts; the walk-up fallback handles those just fine.
if [ -z "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  exit 0
fi

pin_dir="${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}"
pin_file="$pin_dir/ops-root-${CLAUDE_CODE_SESSION_ID}"
mkdir -p "$pin_dir" || exit 2
find -P "$pin_dir" -maxdepth 1 -type f \( -name 'ops-root-*' -o -name 'resolve-cache-*' \) -mtime +30 -delete 2>/dev/null || exit 2
[ ! -e "$pin_file" ] || exit 0

# Resolve ops root via the pure walk-up from the directory chosen above.
ops_root="$(resolve_ops_root_walk "$resolve_from")"
if [ -z "$ops_root" ]; then
  # No anchor found upward from $PWD. The current session isn't in an
  # ops-fork-shaped tree at launch time, so there's nothing to pin.
  exit 0
fi

# The legacy v1 anchor pair also exists in a split-portfolio data sibling.
# Only pin a directory that contains the framework hooks; otherwise a
# portfolio path can become the trusted ops root for the whole session.
if [ ! -d "$ops_root/.claude/hooks" ]; then
  exit 0
fi

pin_dir="${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}"
pin_file="$pin_dir/ops-root-${CLAUDE_CODE_SESSION_ID}"

# Create the pin directory if missing. mkdir -p is idempotent.
mkdir -p "$pin_dir" 2>/dev/null || exit 0

# Write the pin. printf '%s\n' preserves spaces in the path; the
# matching `IFS= read -r` in _lib-ops-root.sh reads it back intact.
( set -C; printf '%s\n' "$ops_root" > "$pin_file" ) 2>/dev/null || { [ -f "$pin_file" ] || exit 2; }

exit 0
