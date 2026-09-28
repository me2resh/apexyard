#!/usr/bin/env bash
# handoff-preflight.sh — mechanical checks for /orbit handoff (apexyard#1446).
#
# Resolves the Plan, Snapshot and Reconciliation that a slice's `basedOn`
# points to, runs `orbit validate --all`, refuses when an open issue in the
# target repo already carries the slice ID, then runs
# `orbit sync github --dry-run` and prints the preview JSON on stdout.
#
# This script never asks for confirmation and never runs the real sync. The
# /orbit handoff flow in SKILL.md runs the leak scrub against this script's
# stdout, asks the operator to confirm, and only then runs the real
# `orbit sync github` call itself.
#
# Exit codes:
#   0  preview printed on stdout
#   10 the ORBIT CLI is absent (ac1-4)
#   11 `orbit validate` failed (ac1-3)
#   12 an open issue in the target repo already carries this slice ID
#   13 usage error, or a Plan/Snapshot/Reconciliation record could not be
#      resolved from the slice's `basedOn`
#
# Requires: jq, gh. No network calls other than `gh issue list` (read-only).

set -u

usage() {
  echo "Usage: handoff-preflight.sh --slice <file> --repo <owner/name> --orbit-root <dir>" >&2
  exit 13
}

slice_file=""
repo=""
orbit_root=""

while [ $# -gt 0 ]; do
  case "$1" in
    --slice) slice_file="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --orbit-root) orbit_root="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$slice_file" ] && [ -n "$repo" ] && [ -n "$orbit_root" ] || usage
[ -f "$slice_file" ] || { echo "Slice record not found: $slice_file" >&2; exit 13; }

ORBIT_BIN="${ORBIT_BIN:-orbit}"
if ! command -v "$ORBIT_BIN" >/dev/null 2>&1; then
  echo "ORBIT CLI not found. Install orbit-spec (https://github.com/me2resh/orbit-spec) or set ORBIT_BIN to the CLI path." >&2
  exit 10
fi

command -v jq >/dev/null 2>&1 || { echo "jq is required to run the handoff preflight." >&2; exit 13; }
command -v gh >/dev/null 2>&1 || { echo "gh is required to check for a duplicate issue." >&2; exit 13; }

slice_id=$(jq -r '.id // empty' "$slice_file")
plan_id=$(jq -r '.planId // empty' "$slice_file")
plan_revision=$(jq -r '.basedOn.planRevision // empty' "$slice_file")
reconciliation_id=$(jq -r '.basedOn.reconciliationId // empty' "$slice_file")

[ -n "$slice_id" ] || { echo "Slice record $slice_file has no id." >&2; exit 13; }
[ -n "$plan_id" ] && [ -n "$plan_revision" ] || { echo "Slice record $slice_file has no basedOn.planRevision for $plan_id." >&2; exit 13; }
[ -n "$reconciliation_id" ] || { echo "Slice record $slice_file has no basedOn.reconciliationId." >&2; exit 13; }

plan_file=""
for candidate in "$orbit_root"/plans/*.json; do
  [ -f "$candidate" ] || continue
  cid=$(jq -r '.id // empty' "$candidate" 2>/dev/null)
  crev=$(jq -r '.revision // empty' "$candidate" 2>/dev/null)
  if [ "$cid" = "$plan_id" ] && [ "$crev" = "$plan_revision" ]; then
    plan_file="$candidate"
    break
  fi
done
[ -n "$plan_file" ] || { echo "No Plan record matches $plan_id revision $plan_revision under $orbit_root/plans." >&2; exit 13; }

reconciliation_file=""
for candidate in "$orbit_root"/reconciliations/*.json; do
  [ -f "$candidate" ] || continue
  cid=$(jq -r '.id // empty' "$candidate" 2>/dev/null)
  if [ "$cid" = "$reconciliation_id" ]; then
    reconciliation_file="$candidate"
    break
  fi
done
[ -n "$reconciliation_file" ] || { echo "No Reconciliation record matches $reconciliation_id under $orbit_root/reconciliations." >&2; exit 13; }

snapshot_id=$(jq -r '.projectSnapshotId // empty' "$reconciliation_file")
snapshot_file=""
for candidate in "$orbit_root"/snapshots/*.json; do
  [ -f "$candidate" ] || continue
  cid=$(jq -r '.id // empty' "$candidate" 2>/dev/null)
  if [ "$cid" = "$snapshot_id" ]; then
    snapshot_file="$candidate"
    break
  fi
done
[ -n "$snapshot_file" ] || { echo "No Snapshot record matches $snapshot_id under $orbit_root/snapshots." >&2; exit 13; }

validate_output=$("$ORBIT_BIN" validate --all --root "$orbit_root" 2>&1)
validate_rc=$?
if [ "$validate_rc" -ne 0 ]; then
  echo "orbit validate failed: $validate_output" >&2
  exit 11
fi

duplicates=$(gh issue list --repo "$repo" --state open --search "$slice_id" --json number 2>/dev/null)
dup_count=$(printf '%s' "$duplicates" | jq 'length' 2>/dev/null)
if [ -n "$dup_count" ] && [ "$dup_count" != "0" ] && [ "$dup_count" != "null" ]; then
  echo "An open issue in $repo already carries slice ID $slice_id. Refusing to file a duplicate." >&2
  exit 12
fi

preview=$("$ORBIT_BIN" sync github --dry-run \
  --plan "$plan_file" --snapshot "$snapshot_file" \
  --reconciliation "$reconciliation_file" --slice "$slice_file" \
  --repo "$repo" 2>&1)
preview_rc=$?
if [ "$preview_rc" -ne 0 ]; then
  echo "orbit sync github --dry-run failed: $preview" >&2
  exit 13
fi

printf '%s\n' "$preview"
