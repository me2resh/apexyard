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
  local filtered_records=""
  while IFS= read -r f; do
    case "$f" in docs/orbit/*)
      if [ -n "${upstream:-}" ] && skip_upstream_record "$f"; then continue; fi ;;
    esac
    filtered_records+="$f"$'\n'
  done <<< "$records"
  records="$filtered_records"
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
  local proposals=() proposal own_rec="" base_slice id outcome notes withdrawn
  while IFS= read -r f; do
    case "$f" in
      docs/orbit/reconciliations/*.json) [ ! -f "$root/$f" ] || own_rec="$root/$f" ;;
      docs/orbit/slices/*.json)
        [ -f "$root/$f" ] || continue
        git -C "$root" cat-file -e "$mb:$f" 2>/dev/null || proposals+=("$f") ;;
    esac
  done <<< "$records"
  if [ -f "$pr_body" ]; then
    if grep -Fxq "No next slice: every outcome is achieved." "$pr_body"; then
      [ "${#proposals[@]}" -eq 0 ] || fail 17 next-slice "" "The PR states No next slice but adds a slice record."
    elif ! grep -Eq "^## Proposed next slice[[:space:]]*$" "$pr_body"; then
      echo "records-lint: WARN [next-slice] Add a Proposed next slice heading or the No next slice line." >&2
    fi
  fi
  [ "${#proposals[@]}" -le 1 ] || fail 17 scope "" "The PR adds more than one slice record."
  for proposal in ${proposals[@]+"${proposals[@]}"}; do
    [ "$count" -eq 1 ] || fail 17 scope "$proposal" "A proposal needs one PR Reconciliation."
    jq -e --slurpfile rec "$own_rec" '
      .planId == $rec[0].planId and .basedOn.planRevision == $rec[0].planRevision
      and .basedOn.reconciliationId == $rec[0].id' "$root/$proposal" >/dev/null ||
      fail 17 scope "$proposal" "Proposal provenance differs from the PR Reconciliation."
    if [ -z "${tickets:-}" ]; then
      echo 'records-lint: WARN [scope] No --tickets file. Skip the open slice check.' >&2
      continue
    fi
    outcome=$(jq -r '.outcomeId' "$root/$proposal")
    notes=$(cat "$root/docs/orbit/plans/$plan.notes.md" 2>/dev/null) || notes=""
    withdrawn=0
    local withdrawn_ids=()
    while IFS= read -r line; do
      case "$line" in
        '## Withdrawn slices') withdrawn=1 ;;
        '## '*) withdrawn=0 ;;
        '- Withdrawn: '*) [ "$withdrawn" -ne 1 ] || withdrawn_ids+=("${line#- Withdrawn: }") ;;
      esac
    done <<< "$notes"
    while IFS= read -r f; do
      base_slice=$(git -C "$root" show "$base:$f") || fail 17 scope "$f" "Cannot read the base slice."
      [ "$(printf '%s' "$base_slice" | jq -r '.planId')" = "$plan" ] || continue
      [ "$(printf '%s' "$base_slice" | jq -r '.outcomeId')" = "$outcome" ] || continue
      id=$(printf '%s' "$base_slice" | jq -r '.id')
      [ "$id" != "$slice_id" ] || continue
      grep -Fxq -- "$id" "$tickets" && continue
      withdrawn=0
      for line in ${withdrawn_ids[@]+"${withdrawn_ids[@]}"}; do [ "$line" != "$id" ] || withdrawn=1; done
      [ "$withdrawn" -eq 1 ] || fail 17 scope "$proposal" "Outcome $outcome has an unfiled slice: $id"
    done < <(git -C "$root" ls-tree -r --name-only "$base" -- docs/orbit/slices/)
  done
  [ "$count" -gt 0 ] || echo 'records-lint: WARN [progress] The slice PR has no Reconciliation.' >&2
  return 0
}
