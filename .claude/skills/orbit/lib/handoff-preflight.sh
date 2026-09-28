#!/usr/bin/env bash
# handoff-preflight.sh — mechanical checks for /orbit handoff (apexyard#1446).
#
# Resolves the Plan, Snapshot and Reconciliation that a slice's `basedOn`
# points to, runs `orbit validate --all`, refuses when an open issue in the
# target repo already carries the exact slice ID, runs
# `orbit sync github --dry-run`, then scrubs the rendered preview for a
# private-portfolio leak. Prints the scrubbed preview JSON on stdout only
# after all five checks pass.
#
# This script never asks for confirmation and never runs the real sync. The
# /orbit handoff flow in SKILL.md shows this script's stdout to the operator,
# asks for a "yes", and only then runs the real `orbit sync github` call
# itself (without --dry-run).
#
# Exit codes:
#   0  the scrubbed preview is printed on stdout
#   10 the ORBIT CLI is absent (ac1-4)
#   11 `orbit validate` failed (ac1-3)
#   12 an open issue in the target repo already carries the exact slice-ID
#      token (a shared word or a prefix does not count)
#   13 a usage error, a Plan/Snapshot/Reconciliation record could not be
#      resolved from the slice's `basedOn`, the dry-run sync failed, or the
#      duplicate-issue search could not be verified (it errored, or did not
#      return a JSON array) — a failed search is never treated as "no
#      duplicate found"
#   14 the leak scrub blocked the rendered preview (ac1-6)
#
# Requires: jq, gh. No network calls other than the read-only
# `gh issue list` duplicate check.

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
    --slice)
      [ $# -ge 2 ] || usage
      slice_file="$2"
      shift 2
      ;;
    --repo)
      [ $# -ge 2 ] || usage
      repo="$2"
      shift 2
      ;;
    --orbit-root)
      [ $# -ge 2 ] || usage
      orbit_root="$2"
      shift 2
      ;;
    *)
      usage
      ;;
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

# Resolve where the leak scrub lives, relative to this script's own location
# (.claude/skills/orbit/lib/handoff-preflight.sh -> .claude/hooks/), so a
# sandboxed copy of both files finds the sandboxed scrub, not a real fork's.
script_dir="$(cd "$(dirname "$0")" && pwd)"
hooks_dir="$script_dir/../../../hooks"
if [ ! -d "$hooks_dir" ]; then
  echo "Cannot find .claude/hooks relative to this helper (expected at $hooks_dir)." >&2
  exit 13
fi
hooks_dir="$(cd "$hooks_dir" && pwd)"
leak_scrub="$hooks_dir/check-private-refs-runtime.sh"
[ -f "$leak_scrub" ] || { echo "Cannot find the leak scrub at $leak_scrub." >&2; exit 13; }

slice_id=$(jq -r '.id // empty' "$slice_file")
plan_id=$(jq -r '.planId // empty' "$slice_file")
plan_revision=$(jq -r '.basedOn.planRevision // empty' "$slice_file")
reconciliation_id=$(jq -r '.basedOn.reconciliationId // empty' "$slice_file")

[ -n "$slice_id" ] || { echo "Slice record $slice_file has no id." >&2; exit 13; }
# Byte-level check, not `grep -E '^...$'`: grep -q matches if ANY line of a
# multi-line value matches, so a slice id containing a newline could carry
# one clean line (passing the anchored regex) and one hostile line (e.g. a
# quote or a search qualifier) on a second line, and still pass. `tr -d`
# deletes every byte in [A-Za-z0-9._-] from the whole value in one pass,
# including across embedded newlines; anything left over is disallowed.
# LC_ALL=C so the class means exactly those 64 bytes in every locale.
if [ -z "$slice_id" ] || [ -n "$(printf '%s' "$slice_id" | LC_ALL=C tr -d 'A-Za-z0-9._-')" ]; then
  echo "Slice id '$slice_id' contains characters outside [A-Za-z0-9._-]; refusing to build a search query from it." >&2
  exit 13
fi
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
[ -n "$snapshot_id" ] || { echo "Reconciliation record $reconciliation_file has no projectSnapshotId." >&2; exit 13; }

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

# 1 (CLI check) already passed above (command -v "$ORBIT_BIN").

# 2. Validate.
validate_output=$("$ORBIT_BIN" validate --all --root "$orbit_root" 2>&1)
validate_rc=$?
if [ "$validate_rc" -ne 0 ]; then
  echo "orbit validate failed: $validate_output" >&2
  exit 11
fi

# 3. Duplicate check — exact backtick-quoted slice-ID token, fail closed.
dup_stderr=$(mktemp "${TMPDIR:-/tmp}/orbit-handoff-dup.XXXXXX") || {
  echo "Cannot create a temp file for the duplicate-issue check." >&2
  exit 13
}
duplicates_json=$(gh issue list --repo "$repo" --state open --search "\"$slice_id\" in:body" --limit 200 --json number,body 2>"$dup_stderr")
dup_rc=$?
dup_err=$(cat "$dup_stderr" 2>/dev/null)
rm -f "$dup_stderr"
if [ "$dup_rc" -ne 0 ]; then
  echo "Cannot verify whether an open issue in $repo already carries slice ID $slice_id: gh issue list failed: $dup_err" >&2
  exit 13
fi
if ! printf '%s' "$duplicates_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "Cannot verify whether an open issue in $repo already carries slice ID $slice_id: gh issue list did not return a JSON array." >&2
  exit 13
fi
raw_count=$(printf '%s' "$duplicates_json" | jq 'length' 2>/dev/null)
if [ "$raw_count" = "200" ]; then
  echo "Cannot verify whether an open issue in $repo already carries slice ID $slice_id: the search returned 200 results, its configured limit, and may be cut off." >&2
  exit 13
fi
token='`'"$slice_id"'`'
dup_count=$(printf '%s' "$duplicates_json" | jq --arg tok "$token" '[.[] | select((.body // "") | contains($tok))] | length' 2>/dev/null)
if [ -z "$dup_count" ]; then
  echo "Cannot verify whether an open issue in $repo already carries slice ID $slice_id: could not parse the search result." >&2
  exit 13
fi
if [ "$dup_count" != "0" ]; then
  echo "An open issue in $repo already carries slice ID $slice_id (exact token match). Refusing to file a duplicate." >&2
  exit 12
fi

# 4. Dry-run preview. Stderr is left to inherit (not captured), so a CLI
# warning cannot land inside $preview and corrupt the JSON.
preview=$("$ORBIT_BIN" sync github --dry-run \
  --plan "$plan_file" --snapshot "$snapshot_file" \
  --reconciliation "$reconciliation_file" --slice "$slice_file" \
  --repo "$repo")
preview_rc=$?
if [ "$preview_rc" -ne 0 ]; then
  echo "orbit sync github --dry-run failed (see the CLI's own error above)." >&2
  exit 13
fi

title=$(printf '%s' "$preview" | jq -r '.title // empty')
body=$(printf '%s' "$preview" | jq -r '.body // empty')
if [ -z "$title" ] && [ -z "$body" ]; then
  echo "orbit sync github --dry-run returned neither a title nor a body to scrub." >&2
  exit 13
fi

# 5. Leak scrub. Scrub the PLAIN-TEXT title/body (via jq -r), not the raw
# JSON: in JSON a newline is the two characters \n, so a name at the start
# of a body line is preceded by "n", not a real newline, and the scrub's
# word-boundary rule misses it.
body_file=$(mktemp "${TMPDIR:-/tmp}/orbit-handoff-body.XXXXXX") || {
  echo "Cannot create a temp file for the leak scrub." >&2
  exit 13
}
printf '%s\n' "$body" > "$body_file"

scrub_output=$("$leak_scrub" "$repo" "$title" "$body_file" 2>&1)
scrub_rc=$?
rm -f "$body_file"
if [ "$scrub_rc" -ne 0 ]; then
  printf '%s\n' "$scrub_output" >&2
  echo "The leak scrub blocked the handoff preview for slice $slice_id." >&2
  exit 14
fi

printf '%s\n' "$preview"
