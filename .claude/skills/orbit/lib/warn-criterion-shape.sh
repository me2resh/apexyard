#!/usr/bin/env bash
# Print advisory warnings for criterion statements and assessment explanations.
# Warnings exit 0. Usage and record errors exit 1.

set -u
set -o pipefail
LC_COLLATE=C
export LC_COLLATE

orbit_root=""
plan_file=""
reconciliation_file=""

error() {
  echo "ORBIT criterion shape check failed: $*." >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --orbit-root|--plan|--reconciliation)
      key="$1"
      [ "$#" -ge 2 ] && [ -n "$2" ] || error "$key needs a value"
      case "$key" in
        --orbit-root) orbit_root="$2" ;;
        --plan) plan_file="$2" ;;
        --reconciliation) reconciliation_file="$2" ;;
      esac
      shift 2
      ;;
    *) error "unknown option $1" ;;
  esac
done

[ -n "$orbit_root" ] && [ -d "$orbit_root" ] || error "record directory is missing"
command -v jq >/dev/null 2>&1 || error "jq is unavailable"

# Record-set mode checks all records in the active directories, not history.
if [ -n "$plan_file" ]; then
  plans=("$plan_file")
  [ -f "$plan_file" ] || error "Plan record is missing: $plan_file"
else
  plans=("$orbit_root"/plans/*.json)
fi
if [ -n "$reconciliation_file" ]; then
  reconciliations=("$reconciliation_file")
  [ -f "$reconciliation_file" ] || error "Reconciliation record is missing: $reconciliation_file"
else
  reconciliations=("$orbit_root"/reconciliations/*.json)
fi

for current_plan in "${plans[@]}"; do
  [ -f "$current_plan" ] || continue
  jq -e 'type == "object" and (.id | type == "string") and
    (.revision | type == "number") and (.acceptanceCriteria | type == "array") and
    all(.acceptanceCriteria[]; (.id | type == "string") and (.statement | type == "string"))' \
    "$current_plan" >/dev/null 2>&1 || error "invalid Plan record: $current_plan"
  warnings=$(jq -r '
    . as $plan | .acceptanceCriteria[] |
    (.statement | [scan("\\S+")] | length) as $words |
    " (Plan \($plan.id) revision \($plan.revision))." as $context |
    (if $words > 50 then
      "WARNING: ORBIT criterion \(.id) statement has \($words) words; limit is 50" + $context
    else empty end),
    (if (.statement | contains("Shown by:")) then
      "WARNING: ORBIT criterion \(.id) statement contains Shown by:" + $context
    else empty end)
  ' "$current_plan") || error "cannot read Plan record: $current_plan"
  [ -z "$warnings" ] || printf '%s\n' "$warnings" >&2
done

for current_reconciliation in "${reconciliations[@]}"; do
  [ -f "$current_reconciliation" ] || continue
  jq -e 'type == "object" and (.planId | type == "string") and
    (.planRevision | type == "number") and (.criterionAssessments | type == "array") and
    all(.criterionAssessments[]; (.criterionId | type == "string") and
      (.status | type == "string") and ((.explanation // "") | type == "string"))' \
    "$current_reconciliation" >/dev/null 2>&1 || error "invalid Reconciliation record: $current_reconciliation"
  warnings=$(jq -r '
    . as $reconciliation | .criterionAssessments[] |
    select(.status != "achieved") |
    select((.explanation // "" | startswith("Missing:")) | not) |
    "WARNING: ORBIT criterion \(.criterionId) \(.status) explanation does not start with Missing: (Plan \($reconciliation.planId) revision \($reconciliation.planRevision))."
  ' "$current_reconciliation") || error "cannot read Reconciliation record: $current_reconciliation"
  [ -z "$warnings" ] || printf '%s\n' "$warnings" >&2
done

exit 0
