#!/usr/bin/env bash
# Print advisory warnings for unfinished Plan outcomes without a slice.
# A missing assessment is not evidence that a criterion was achieved.
# This helper never changes the exit status of an ORBIT CLI operation.

set -u
set -o pipefail
LC_COLLATE=C
export LC_COLLATE

orbit_root=""
plan_file=""
reconciliation_file=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --orbit-root|--plan|--reconciliation)
      key="$1"
      if [ "$#" -lt 2 ]; then
        echo "ORBIT coverage check skipped: $key needs a value." >&2
        exit 0
      fi
      case "$key" in
        --orbit-root) orbit_root="$2" ;;
        --plan) plan_file="$2" ;;
        --reconciliation) reconciliation_file="$2" ;;
      esac
      shift 2
      ;;
    *)
      echo "ORBIT coverage check skipped: unknown option $1." >&2
      exit 0
      ;;
  esac
done

if [ -z "$orbit_root" ] || [ ! -d "$orbit_root" ]; then
  echo "ORBIT coverage check skipped: record directory is missing." >&2
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ORBIT coverage check skipped: jq is unavailable." >&2
  exit 0
fi

if [ -n "$plan_file" ]; then
  plans=("$plan_file")
else
  plans=("$orbit_root"/plans/*.json)
fi
if [ ! -f "${plans[0]}" ]; then
  echo "ORBIT coverage check skipped: no Plan record found." >&2
  exit 0
fi

selected_plans=()
selected_ids=()
selected_revisions=()
selected_ties=()
for candidate_plan in "${plans[@]}"; do
  if ! jq -e '(.id | type == "string") and (.revision | type == "number") and
    (.outcomes | type == "array") and (.acceptanceCriteria | type == "array") and
    all(.outcomes[]; .id | type == "string") and
    all(.acceptanceCriteria[]; (.id | type == "string") and (.outcomeId | type == "string"))' \
    "$candidate_plan" >/dev/null 2>&1; then
    echo "ORBIT coverage check skipped: invalid Plan record: $candidate_plan." >&2
    continue
  fi

  candidate_id=$(jq -r '.id' "$candidate_plan")
  candidate_revision=$(jq -r '.revision' "$candidate_plan")
  selected_index=${#selected_plans[@]}
  for ((index=0; index<${#selected_plans[@]}; index++)); do
    if [ "${selected_ids[index]}" = "$candidate_id" ]; then
      selected_index=$index
      break
    fi
  done
  if [ "$selected_index" -eq "${#selected_plans[@]}" ]; then
    selected_plans+=("$candidate_plan")
    selected_ids+=("$candidate_id")
    selected_revisions+=("$candidate_revision")
    selected_ties+=(0)
  elif [ -z "$plan_file" ]; then
    if jq -n -e --argjson candidate "$candidate_revision" \
      --argjson selected "${selected_revisions[selected_index]}" \
      '$candidate >= $selected' >/dev/null; then
      if [ "$candidate_revision" = "${selected_revisions[selected_index]}" ]; then
        selected_ties[selected_index]=1
      else
        selected_ties[selected_index]=0
      fi
      selected_plans[selected_index]="$candidate_plan"
      selected_revisions[selected_index]="$candidate_revision"
    fi
  fi
done

for ((index=0; index<${#selected_plans[@]}; index++)); do
  if [ "${selected_ties[index]}" -eq 1 ]; then
    echo "ORBIT coverage check: tied Plan ${selected_ids[index]} revision ${selected_revisions[index]}; using ${selected_plans[index]} (filename order)." >&2
  fi
done

# Validate each slice once so one bad file cannot suppress another slice.
# Keep one empty element: Bash 3.2 treats an empty array as unset under set -u.
valid_slices=("")
for current_slice in "$orbit_root"/slices/*.json; do
  [ -f "$current_slice" ] || continue
  if jq -e 'type == "object" and (.planId | type == "string") and
    (.basedOn.planRevision | type == "number") and
    ((.contributesTo // [] | type) as $type | $type == "array" or $type == "string")' \
    "$current_slice" >/dev/null 2>&1; then
    valid_slices+=("$current_slice")
  else
    echo "ORBIT coverage check skipped invalid slice record: $current_slice." >&2
  fi
done

for current_plan in "${selected_plans[@]}"; do

  if [ -n "$reconciliation_file" ]; then
    current_reconciliation="$reconciliation_file"
  else
    current_reconciliation=""
    latest_seconds=""
    latest_fraction=""
    tied_latest=0
    for candidate in "$orbit_root"/reconciliations/*.json; do
      [ -f "$candidate" ] || continue
      if jq -e --slurpfile plan "$current_plan" \
        '.planId == $plan[0].id and .planRevision == $plan[0].revision' \
        "$candidate" >/dev/null 2>&1; then
        candidate_timestamp=$(jq -r '
          (.reconciledAt // "") as $timestamp |
          if ($timestamp | type) == "string" then
            try ($timestamp | capture(
              "^(?<date>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.(?<fraction>[0-9]+))?(?<zone>Z|[+-][0-9]{2}:[0-9]{2})$"
            ) | . as $parts |
              (($parts.date + "Z" | fromdateiso8601) -
              (if $parts.zone == "Z" then 0 else
                ($parts.zone[1:3] | tonumber) * 3600 +
                ($parts.zone[4:6] | tonumber) * 60 |
                if $parts.zone[0:1] == "+" then . else -. end
              end) | tostring) + " " +
              (($parts.fraction // "") | sub("0+$"; ""))
            ) catch ""
          else "" end
        ' "$candidate" 2>/dev/null)
        candidate_seconds=${candidate_timestamp%% *}
        candidate_fraction=${candidate_timestamp#* }
        if [ -z "$current_reconciliation" ] || \
           { [ -n "$candidate_timestamp" ] && \
             { [ -z "$latest_seconds" ] || [ "$candidate_seconds" -gt "$latest_seconds" ] || \
               { [ "$candidate_seconds" -eq "$latest_seconds" ] && \
                 [[ "$candidate_fraction" > "$latest_fraction" ]]; }; }; }; then
          current_reconciliation="$candidate"
          latest_seconds="$candidate_seconds"
          latest_fraction="$candidate_fraction"
          tied_latest=0
        elif [ "$candidate_timestamp" = "$latest_seconds $latest_fraction" ] || \
             { [ -z "$candidate_timestamp" ] && [ -z "$latest_seconds" ]; }; then
          if [ -n "$candidate_timestamp" ]; then
            tied_latest=1
          fi
          # The glob is in filename order; the last equal-time file wins.
          current_reconciliation="$candidate"
        fi
      fi
    done
    if [ "$tied_latest" -eq 1 ]; then
      echo "ORBIT coverage check: tied Reconciliations at $latest_seconds.$latest_fraction for $current_plan; using $current_reconciliation (filename order)." >&2
    fi
  fi
  if [ ! -f "$current_reconciliation" ]; then
    echo "ORBIT coverage check skipped: no Reconciliation for $current_plan." >&2
    continue
  fi
  if ! jq -e --slurpfile plan "$current_plan" \
    '.planId == $plan[0].id and .planRevision == $plan[0].revision and
    (.criterionAssessments | type == "array") and
    all(.criterionAssessments[]; (.criterionId | type == "string") and (.status | type == "string"))' \
    "$current_reconciliation" >/dev/null 2>&1; then
    echo "ORBIT coverage check skipped: invalid Reconciliation: $current_reconciliation." >&2
    continue
  fi

  if ! warnings=$({
    cat "$current_plan" "$current_reconciliation" || exit 1
    for current_slice in "${valid_slices[@]}"; do
      [ -n "$current_slice" ] || continue
      cat "$current_slice" || exit 1
    done
  } | jq -r -s '
    .[0] as $plan | .[1] as $reconciliation | .[2:] as $slices |
    def achieved($id): any($reconciliation.criterionAssessments[];
      .criterionId == $id and .status == "achieved");
    $plan.outcomes[] as $outcome |
    [$plan.acceptanceCriteria[] | select(.outcomeId == $outcome.id)] as $criteria |
    select(any($criteria[]; achieved(.id) | not)) |
    select(any($slices[];
      .planId == $plan.id and .basedOn.planRevision == $plan.revision and
      ((.contributesTo // []) as $refs |
        (if ($refs | type) == "string" then [$refs] else $refs end) as $ids |
        (($ids | index($outcome.id)) != null or
         any($criteria[]; .id as $id | ($ids | index($id)) != null)))) | not) |
    "WARNING: ORBIT outcome \($outcome.id) has unmet criteria and no slice (Plan \($plan.id) revision \($plan.revision))."
  ' 2>/dev/null); then
    echo "ORBIT coverage check skipped: invalid slice record or unreadable records under $orbit_root." >&2
    continue
  fi
  [ -z "$warnings" ] || printf '%s\n' "$warnings" >&2
done

exit 0
