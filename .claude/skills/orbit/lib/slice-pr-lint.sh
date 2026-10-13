#!/usr/bin/env bash
# Variables come from the caller or fixture functions.
# shellcheck disable=SC2154,SC2034

# Check slice scope, evidence, and provenance. Write no record.
slice_pr_lint() {
  local slice="" f root mb paths records latest='{}' at best='' record plan allowed bad line number sha
  if [ -z "$slice_id" ] && [ -f "$pr_body" ]; then
    slice_id=$(sed -nE 's/^.*ORBIT slice:[*[:space:]]*`?(slice-[a-z0-9-]+).*$/\1/p' "$pr_body" | head -1)
  fi
  [ -n "$slice_id" ] || return 0
  root=$(git -C "$orbit_root" rev-parse --show-toplevel) || fail 19 provenance "" "Cannot resolve the repository."
  # Read the slice from the base branch, so a PR cannot widen its own scope.
  while IFS= read -r f; do
    case "$f" in docs/orbit/slices/*.json) ;; *) continue ;; esac
    record=$(git -C "$root" show "$base:$f" 2>/dev/null) || continue
    [ "$(printf '%s' "$record" | jq -r '.id')" != "$slice_id" ] || slice="$record"
  done < <(git -C "$root" ls-tree -r --name-only "$base" -- docs/orbit/slices/)
  [ -n "$slice" ] || fail 17 scope "" "No slice record named $slice_id on $base."
  plan=$(printf '%s' "$slice" | jq -r '.planId')
  allowed=$(printf '%s' "$slice" | jq -c '.contributesTo')
  mb=$(git -C "$root" merge-base "$base" HEAD) || fail 19 provenance "" "Cannot resolve the merge base."
  paths=$(git -C "$root" diff --name-only --no-renames "$mb") || fail 18 evidence "" "Cannot read changed paths."
  records=$( { printf '%s\n' "$paths"; git -C "$root" ls-files --others --exclude-standard; } | sort -u)
  while IFS= read -r f; do
    case "$f" in docs/orbit/reconciliations/*.json) ;; *) continue ;; esac
    record=$(git -C "$root" show "$base:$f") || fail 17 scope "$f" "Cannot read the base record."
    [ "$(printf '%s' "$record" | jq -r '.planId')" = "$plan" ] || continue
    at=$(printf '%s' "$record" | jq -r '.reconciledAt')
    if [ -z "$best" ] || [[ "$at" > "$best" ]]; then latest="$record"; best="$at"; fi
  done < <(git -C "$root" ls-tree -r --name-only "$base" -- docs/orbit/reconciliations/)
  local count=0
  while IFS= read -r f; do
    case "$f" in docs/orbit/reconciliations/*.json) ;; *) continue ;; esac
    [ -f "$root/$f" ] || continue
    count=$((count + 1))
    [ "$(jq -r '.planId' "$root/$f")" = "$plan" ] || fail 17 scope "$f" "Record belongs to another plan."
    bad=$(jq -r --argjson old "$latest" --argjson allowed "$allowed" '
      (.criterionAssessments | map({key:.criterionId,value:.status}) | from_entries) as $new
      | (($old.criterionAssessments // []) | map({key:.criterionId,value:.status}) | from_entries) as $prev
      | ($new + $prev | keys[]) as $id
      | select(($allowed | index($id)) == null and $new[$id] != $prev[$id]) | $id' "$root/$f")
    [ -z "$bad" ] || fail 17 scope "$f" "Status changes outside contributesTo: $bad"
    bad=$(jq -r --argjson old "$latest" --arg paths "$paths" '
      def rank: if . == "achieved" then 2 elif . == "partially-verified" then 1 else 0 end;
      (($old.criterionAssessments // []) | map({key:.criterionId,value:.status}) | from_entries) as $prev
      | ($paths | split("\n") | map(select(length > 0 and (startswith("docs/orbit/") | not)))) as $paths
      | .criterionAssessments[] | . as $a
      | select((.status | rank) > ($prev[.criterionId] | rank))
      | select(any($a.evidence[]?; . as $e | any($paths[]; . as $p | $e | contains($p))) | not)
      | .criterionId' "$root/$f")
    [ -z "$bad" ] || fail 18 evidence "$f" "Raised status needs a changed path: $bad"
    line=$(jq -r '[.observations[]? | select(test("^Slice PR: #[0-9]+; dev merge-base [0-9a-fA-F]{40}\\.$"))] | if length == 1 then .[0] else empty end' "$root/$f")
    [ -n "$line" ] || fail 19 provenance "$f" "Add one Slice PR observation."
    number=${line#Slice PR: #}; number=${number%%;*}
    sha=${line##* }; sha=${sha%.}
    [ "$sha" = "$mb" ] || fail 19 provenance "$f" "The merge-base SHA does not match."
    [ -z "$pr_number" ] || [ "$number" = "$pr_number" ] || fail 19 provenance "$f" "The PR number does not match."
  done <<< "$records"
  [ "$count" -gt 0 ] || echo 'records-lint: WARN [progress] The slice PR has no Reconciliation.' >&2
  return 0
}
