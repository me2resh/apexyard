#!/usr/bin/env bash
# status-live.sh — /orbit status (AgDR-0225, ac8-4). Read-only: writes no record.
#
# Prints the `orbit progress` output for a Plan, then the commits since the
# observed snapshot commit of the newest Reconciliation of that Plan.
# A Slice PR observation selects its squash commit on --base (origin/dev).
#
# Usage: status-live.sh --orbit-root <dir> --plan <plan-id> [--repo-path <dir>]
# Exit: the progress exit status; 20 usage or missing tool.

set -u
orbit_root=""; plan_id=""; repo_path=""; base="origin/dev"
usage() { echo "Usage: status-live.sh --orbit-root <dir> --plan <plan-id> [--repo-path <dir>]" >&2; exit 20; }
while [ $# -gt 0 ]; do
  case "$1" in
    --orbit-root) [ $# -ge 2 ] || usage; orbit_root="$2"; shift 2 ;;
    --plan) [ $# -ge 2 ] || usage; plan_id="$2"; shift 2 ;;
    --repo-path) [ $# -ge 2 ] || usage; repo_path="$2"; shift 2 ;;
    --base) [ $# -ge 2 ] || usage; base="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -d "$orbit_root" ] && [ -n "$plan_id" ] || usage
command -v jq >/dev/null 2>&1 || { echo "status-live: jq is required." >&2; exit 20; }
ORBIT_BIN="${ORBIT_BIN:-orbit}"
command -v "$ORBIT_BIN" >/dev/null 2>&1 || { echo "ORBIT CLI not found. Install orbit-spec or set ORBIT_BIN." >&2; exit 20; }
[ -n "$repo_path" ] || repo_path=$(git -C "$orbit_root" rev-parse --show-toplevel 2>/dev/null || true)

"$ORBIT_BIN" progress --root "$orbit_root" --plan "$plan_id"
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

# Newest Reconciliation of the Plan (ISO-8601 UTC strings sort as text).
rec=""; best=""
for f in "$orbit_root"/reconciliations/*.json; do
  [ -f "$f" ] || continue
  [ "$(jq -r '.planId // empty' "$f")" = "$plan_id" ] || continue
  at=$(jq -r '.reconciledAt // empty' "$f")
  if [ -z "$best" ] || [[ "$at" > "$best" ]]; then best="$at"; rec="$f"; fi
done
echo
if [ -z "$rec" ]; then
  echo "Commits since the observed snapshot: no Reconciliation found for $plan_id."
  exit 0
fi
pr=$(jq -r '.observations[]? | capture("^Slice PR: #(?<number>[0-9]+);").number' "$rec" | head -1)
if [ -n "$pr" ]; then
  commit=$(git -C "$repo_path" log "$base" --format='%H %s' --extended-regexp --grep="\\(#$pr\\)$" |
    awk -v suffix="(#$pr)" 'substr($0, length($0)-length(suffix)+1) == suffix {print $1; exit}')
  echo "Commits since slice PR #$pr:"
  if [ -z "$commit" ]; then
    echo "  cannot check: the squash commit is not on the base branch."
  else
    log=$(git -C "$repo_path" log --oneline "$commit..$base")
    if [ -n "$log" ]; then printf '%s\n' "$log"; else echo "  none"; fi
  fi
  exit 0
fi
snap_id=$(jq -r '.projectSnapshotId // empty' "$rec")
snap=""
for f in "$orbit_root"/snapshots/*.json; do
  [ -f "$f" ] && [ "$(jq -r '.id // empty' "$f")" = "$snap_id" ] && { snap="$f"; break; }
done
if [ -z "$snap" ]; then
  echo "Commits since the observed snapshot: snapshot $snap_id not found."
  exit 0
fi
while IFS=$'\t' read -r rid branch commit; do
  [ -n "$commit" ] || continue
  echo "Commits since snapshot $snap_id ($rid at ${commit:0:7}):"
  if [ -n "$repo_path" ] && git -C "$repo_path" cat-file -e "$commit^{commit}" 2>/dev/null; then
    ref="HEAD"
    git -C "$repo_path" rev-parse --verify -q "origin/$branch" >/dev/null && ref="origin/$branch"
    log=$(git -C "$repo_path" log --oneline "$commit..$ref")
    if [ -n "$log" ]; then printf '%s\n' "$log"; else echo "  none"; fi
  else
    echo "  cannot check: the commit is not in the local repository."
  fi
done < <(jq -r '.repositories[] | [.repositoryId, .branch, .commit] | @tsv' "$snap")
exit 0
