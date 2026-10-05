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

for current_plan in "${plans[@]}"; do
  if ! jq -e '(.id | type == "string") and (.revision | type == "number") and
    (.outcomes | type == "array") and (.acceptanceCriteria | type == "array") and
    all(.outcomes[]; .id | type == "string") and
    all(.acceptanceCriteria[]; (.id | type == "string") and (.outcomeId | type == "string"))' \
    "$current_plan" >/dev/null 2>&1; then
    echo "ORBIT coverage check skipped: invalid Plan record: $current_plan." >&2
    continue
  fi

  if [ -n "$reconciliation_file" ]; then
    current_reconciliation="$reconciliation_file"
  else
    current_reconciliation=""
    latest_timestamp=""
    tied_latest=0
    for candidate in "$orbit_root"/reconciliations/*.json; do
      [ -f "$candidate" ] || continue
      if jq -e --slurpfile plan "$current_plan" \
        '.planId == $plan[0].id and .planRevision == $plan[0].revision' \
        "$candidate" >/dev/null 2>&1; then
        candidate_timestamp=$(jq -r '
          (.reconciledAt // "") |
          if type == "string" and
            test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$")
          then sub("Z$"; "") | split(".") |
            .[0] + "." + (((.[1] // "") + "000000000")[0:9])
          else "" end
        ' "$candidate" 2>/dev/null)
        if [ -z "$current_reconciliation" ] || [[ "$candidate_timestamp" > "$latest_timestamp" ]]; then
          current_reconciliation="$candidate"
          latest_timestamp="$candidate_timestamp"
          tied_latest=0
        elif [ "$candidate_timestamp" = "$latest_timestamp" ]; then
          if [ -n "$candidate_timestamp" ]; then
            tied_latest=1
          fi
          # The glob is in filename order; the last equal-time file wins.
          current_reconciliation="$candidate"
        fi
      fi
    done
    if [ "$tied_latest" -eq 1 ]; then
      echo "ORBIT coverage check: tied Reconciliations at $latest_timestamp for $current_plan; using $current_reconciliation (filename order)." >&2
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
    for current_slice in "$orbit_root"/slices/*.json; do
      [ -f "$current_slice" ] || continue
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
        (($refs | index($outcome.id)) != null or
         any($criteria[]; .id as $id | ($refs | index($id)) != null)))) | not) |
    "WARNING: ORBIT outcome \($outcome.id) has unmet criteria and no slice."
  ' 2>/dev/null); then
    echo "ORBIT coverage check skipped: invalid slice record or unreadable records under $orbit_root." >&2
    continue
  fi
  [ -z "$warnings" ] || printf '%s\n' "$warnings" >&2
done

exit 0
