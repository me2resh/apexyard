#!/usr/bin/env bash
# Refresh provenance after a branch update. Preserve status and scope.
set -euo pipefail
orbit_root=""; base=""; pr=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || exit 20
  case "$1" in
    --orbit-root) orbit_root="$2" ;;
    --base) base="$2" ;;
    --pr) pr="$2" ;;
    *) exit 20 ;;
  esac
  shift 2
done
[ -d "$orbit_root" ] && [ -n "$base" ] && [[ "$pr" =~ ^[0-9]+$ ]] || exit 20
root=$(git -C "$orbit_root" rev-parse --show-toplevel)
root=$(cd "$root" && pwd -P)
orbit_root=$(cd "$orbit_root" && pwd -P)
mb=$(git -C "$root" merge-base "$base" HEAD)
tmp=$(mktemp -d)
cleanup() {
  git -C "$root" worktree remove --force "$tmp/tree" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
records=$( { git -C "$root" diff --name-only "$mb"; git -C "$root" ls-files --others --exclude-standard; } | sort -u)
rec=""
while IFS= read -r f; do
  case "$f" in docs/orbit/reconciliations/*.json)
    [ -f "$root/$f" ] || continue
    if jq -e --arg prefix "Slice PR: #$pr;" 'any(.observations[]?; startswith($prefix))' "$root/$f" >/dev/null; then
      [ -z "$rec" ] || { echo 'Refresh needs one PR Reconciliation.' >&2; exit 19; }
      rec="$root/$f"
    fi ;;
  esac
done <<< "$records"
[ -n "$rec" ] || exit 19
old_snapshot=$(jq -r '.projectSnapshotId' "$rec")
plan=$(jq -r '.planId' "$rec")
project=""
for f in "$orbit_root"/plans/*.json; do
  if jq -e --arg plan "$plan" 'select(.id == $plan)' "$f" >/dev/null; then project=$(jq -r '.project.id' "$f"); fi
done
[ -n "$project" ] || exit 19
# Keep the repository ID of the old snapshot, so slice basedOn keys still match.
repository="$project"
for f in "$orbit_root"/snapshots/*.json; do
  if [ "$(jq -r '.id' "$f")" = "$old_snapshot" ]; then
    repository=$(jq -r --arg d "$project" '.repositories[0].repositoryId // $d' "$f")
  fi
done
git -C "$root" worktree add --detach "$tmp/tree" "$mb" >/dev/null
"${ORBIT_BIN:-orbit}" snapshot --project "$project" --repository "$repository" --path "$tmp/tree" --output "$tmp/snapshot.json"
new_snapshot=$(jq -er '.id' "$tmp/snapshot.json")
cp "$tmp/snapshot.json" "$orbit_root/snapshots/$new_snapshot.json"
jq --arg mb "$mb" --arg pr "$pr" --arg snapshot "$new_snapshot" --arg at "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '
  .projectSnapshotId=$snapshot | .reconciledAt=$at | .observations |= map(
    if startswith("Slice PR:") then "Slice PR: #" + $pr + "; dev merge-base " + $mb + "."
    elif test("merge-base"; "i") then gsub("(?<prefix>merge-base )[0-9a-fA-F]{40}"; "\(.prefix)\($mb)"; "i")
    else . end)' "$rec" > "$tmp/rec.json"
cp "$tmp/rec.json" "$rec"
for f in "$orbit_root"/snapshots/*.json; do
  [ "$(jq -r '.id' "$f")" = "$old_snapshot" ] || continue
  [ "$old_snapshot" != "$new_snapshot" ] || continue
  rel=${f#"$root/"}
  git -C "$root" cat-file -e "$mb:$rel" 2>/dev/null || rm "$f"
done
while IFS= read -r f; do
  case "$f" in docs/orbit/slices/*.json)
    [ -f "$root/$f" ] || continue
    git -C "$root" cat-file -e "$mb:$f" 2>/dev/null && continue
    jq --slurpfile rec "$rec" --slurpfile snapshot "$tmp/snapshot.json" --arg plan "$plan" '
      if .planId == $plan then
        .basedOn.planRevision=$rec[0].planRevision | .basedOn.reconciliationId=$rec[0].id
        | .basedOn.repositories=($snapshot[0].repositories | map({key:.repositoryId,value:.commit}) | from_entries)
      else . end' "$root/$f" > "$tmp/slice.json"
    cp "$tmp/slice.json" "$root/$f" ;;
  esac
done <<< "$records"
echo 'Refresh complete. Status and scope are unchanged.'
