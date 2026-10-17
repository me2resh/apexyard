#!/usr/bin/env bash
# The slice helper reads the option variables.
# shellcheck disable=SC2034

# records-lint.sh — lint ORBIT records before a records PR (AgDR-0225, ac8-1).
#
# Runs the checks in order and stops on the first fault:
#   1. orbit validate --all
#   2. leak scrub (check-private-refs-runtime.sh) on record text
#   3. sentence check: at most 25 words in a sentence of a record text field
#   4. "Missing: ... Next:" rule for a non-achieved explanation
#   5. local-path check
#   6. Plan interview: six dated operator answers in the Plan notes
#   7. Slice PR: compare scope with the newest base record.
#   8. Slice PR: raised statuses need evidence from changed paths.
#   9. Slice PR: check the PR number and merge-base observation.
# A slice PR without a Reconciliation produces a warning.
# Checks 2 to 6 read the record files changed against --base (default
# origin/dev), or every record file with --all.
# By default, checks 3 and 4 read only the text that changed against the merge
# base. A JSON record is compared field by field. A notes file is compared line
# by line. A new file counts as fully changed. A file whose only change is
# "basedOn" has no changed text, so it gets the validate and leak-scrub checks
# but no sentence or Missing/Next check. --all checks all text.
#
# With --upstream, skip changed records whose HEAD blobs match the upstream ref.
# Reject an upstream ref that does not resolve.
#
# Usage: records-lint.sh --orbit-root <dir> [--repo <owner/name>] [--base <ref>] [--upstream <ref>] [--all]
# Exit: 0 clean; 10 validate; 11 leak scrub; 12 sentence; 13 Missing/Next;
#       14 local path; 15 initiative; 16 interview; 17 scope; 18 evidence;
#       19 provenance; 20 usage or missing tool.
# Slice options: --slice <id>, --pr-body <file>, --pr <number>, --tickets <file>.

set -u

MAX_WORDS=25
orbit_root=""
repo="me2resh/apexyard"
base="origin/dev"
check_all=0
upstream=""
slice_id=""; pr_body=""; pr_number=""; tickets=""

usage() {
  echo "Usage: records-lint.sh --orbit-root <dir> [--repo <owner/name>] [--base <ref>] [--upstream <ref>] [--all]" >&2
  exit 20
}

while [ $# -gt 0 ]; do
  case "$1" in
    --orbit-root) [ $# -ge 2 ] || usage; orbit_root="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || usage; repo="$2"; shift 2 ;;
    --upstream) [ $# -ge 2 ] || usage; upstream="$2"; shift 2 ;;
    --base) [ $# -ge 2 ] || usage; base="$2"; shift 2 ;;
    --tickets) [ $# -ge 2 ] || usage; tickets="$2"; [ -f "$tickets" ] || usage; shift 2 ;;
    --all) check_all=1; shift ;;
    --slice) [ $# -ge 2 ] || usage; slice_id="$2"; shift 2 ;;
    --pr-body) [ $# -ge 2 ] || usage; pr_body="$2"; shift 2 ;;
    --pr) [ $# -ge 2 ] || usage; pr_number="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -d "$orbit_root" ] || { echo "records-lint: record directory not found: $orbit_root" >&2; exit 20; }
command -v jq >/dev/null 2>&1 || { echo "records-lint: jq is required." >&2; exit 20; }

ORBIT_BIN="${ORBIT_BIN:-orbit}"
command -v "$ORBIT_BIN" >/dev/null 2>&1 || {
  echo "records-lint: ORBIT CLI not found. Install orbit-spec or set ORBIT_BIN." >&2
  exit 20
}
script_dir="$(cd "$(dirname "$0")" && pwd)"
leak_scrub="$script_dir/../../../hooks/check-private-refs-runtime.sh"
[ -f "$leak_scrub" ] || { echo "records-lint: leak scrub not found at $leak_scrub" >&2; exit 20; }

fail() { # code check file message
  echo "records-lint: FAIL [$2] ${3:+$3: }$4" >&2
  exit "$1"
}

# Compare committed blobs at the same path. Keep files absent from either ref.
upstream_skipped=()
if [ -n "$upstream" ]; then
  upstream_top=$(git -C "$orbit_root" rev-parse --show-toplevel) ||
    fail 20 upstream "" "Cannot resolve the repository."
  upstream_top=$(cd "$upstream_top" && pwd -P)
  upstream=$(git -C "$upstream_top" rev-parse --verify --end-of-options "$upstream^{commit}" 2>/dev/null) ||
    fail 20 upstream "" "Cannot resolve the upstream ref."
  trap 'echo "records-lint: notice: skipped ${#upstream_skipped[@]} upstream record(s)." >&2' EXIT
fi

skip_upstream_record() {
  [ -n "$upstream" ] || return 1
  local path="$1" head_blob upstream_blob seen
  case "$path" in
    /*) path="$(cd "$(dirname "$path")" && pwd -P)/${path##*/}" ;;
  esac
  path="${path#"$upstream_top"/}"
  head_blob=$(git -C "$upstream_top" rev-parse --verify "HEAD:$path" 2>/dev/null) || return 1
  upstream_blob=$(git -C "$upstream_top" rev-parse --verify "$upstream:$path" 2>/dev/null) || return 1
  [ "$head_blob" = "$upstream_blob" ] || return 1
  for seen in ${upstream_skipped[@]+"${upstream_skipped[@]}"}; do
    [ "$seen" != "$path" ] || return 0
  done
  upstream_skipped+=("$path")
  return 0
}

# 1. Validate.
if ! out=$("$ORBIT_BIN" validate --all --root "$orbit_root" 2>&1); then
  fail 10 validate "" "orbit validate --all failed: $out"
fi

# Initiative scope is checked even with --all, including deleted records and history.
branch=$(git -C "$orbit_root" branch --show-current 2>/dev/null) || branch=""
case "$branch" in orbit/*)
  # shellcheck source=../../../hooks/_lib-orbit-records.sh
  . "$script_dir/../../../hooks/_lib-orbit-records.sh"
  orbit_records_branch_shape "$branch" && orbit_records_initiative "$orbit_root" "$branch" ||
    fail 15 initiative "" "No matching plan record exists for the branch initiative."
  plan_id="plan-$ORBIT_INITIATIVE"
  scope_top=$(git -C "$orbit_root" rev-parse --show-toplevel)
  scope_base=$(git -C "$orbit_root" merge-base "$base" HEAD) ||
    fail 15 initiative "" "Cannot resolve the initiative comparison base."
  scope_files=()
  while IFS= read -r -d '' f; do scope_files+=("$f"); done < <(
    { git -C "$scope_top" diff --name-only --no-renames -z "$scope_base" -- docs/orbit/
      git -C "$scope_top" ls-files --others --exclude-standard -z -- docs/orbit/; })
  kept_scope_files=()
  for f in ${scope_files[@]+"${scope_files[@]}"}; do
    skip_upstream_record "$f" || kept_scope_files+=("$f")
  done
  scope_files=(${kept_scope_files[@]+"${kept_scope_files[@]}"})
  snapshots=()
  for f in ${scope_files[@]+"${scope_files[@]}"}; do
    case "$f" in docs/orbit/reconciliations/*.json)
      if [ -f "$scope_top/$f" ]; then
        snap=$(jq -er --arg p "$plan_id" 'select(.planId == $p) | .projectSnapshotId' "$scope_top/$f") ||
          fail 15 initiative "$f" "Record belongs to another initiative."
        snapshots+=("$snap")
      fi ;;
    esac
  done
  for f in ${scope_files[@]+"${scope_files[@]}"}; do
    case "$f" in
      docs/orbit/plans/*.notes.md)
        [ "${f##*/}" = "$plan_id.notes.md" ] || fail 15 initiative "$f" "Notes belong to another initiative."
        continue ;;
      *.json) ;;
      *) fail 15 initiative "$f" "Cannot establish record initiative." ;;
    esac
    if [ -f "$scope_top/$f" ]; then record=$(cat "$scope_top/$f")
    else record=$(git -C "$scope_top" show "$scope_base:$f") || fail 15 initiative "$f" "Cannot read deleted record."; fi
    case "$f" in
      docs/orbit/plans/*) owner=$(printf '%s' "$record" | jq -er '.id') ;;
      # A history file is a superseded plan (owner in .id) or reconciliation (owner in .planId).
      docs/orbit/history/*) owner=$(printf '%s' "$record" | jq -er '.planId // .id') ;;
      docs/orbit/slices/*|docs/orbit/reconciliations/*) owner=$(printf '%s' "$record" | jq -er '.planId') ;;
      docs/orbit/snapshots/*)
        id=$(printf '%s' "$record" | jq -er '.id') || fail 15 initiative "$f" "Cannot read snapshot ID."
        found=0
        for snap in ${snapshots[@]+"${snapshots[@]}"}; do [ "$snap" != "$id" ] || found=1; done
        [ "$found" -eq 1 ] || fail 15 initiative "$f" "Snapshot is not referenced by a changed reconciliation."
        continue ;;
      *) fail 15 initiative "$f" "Cannot establish record initiative." ;;
    esac
    [ "$owner" = "$plan_id" ] || fail 15 initiative "$f" "Record belongs to another initiative."
  done
;; esac

# Slice checks use the base tip to prevent lost statuses.
case "$branch" in orbit/*) ;; *)
  if [ -n "$slice_id" ] || [ -n "$pr_body" ]; then
  # shellcheck source=./slice-pr-lint.sh
  . "$script_dir/slice-pr-lint.sh"
  slice_pr_lint
  fi
;; esac

# Select the files for checks 2 to 6.
files=()
use_diff=0
if [ "$check_all" -eq 0 ]; then
  if git -C "$orbit_root" rev-parse --verify -q "$base" >/dev/null 2>&1; then
    use_diff=1
  else
    echo "records-lint: notice: base ref $base not found, so the lint checks every record file." >&2
  fi
fi
if [ "$use_diff" -eq 1 ]; then
  top=$(git -C "$orbit_root" rev-parse --show-toplevel)
  # Diff against the merge base, not the tip of the base ref.
  mb=$(git -C "$orbit_root" merge-base "$base" HEAD 2>/dev/null) || mb="$base"
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$top/$f" ] && files+=("$top/$f")
  done < <({ git -C "$orbit_root" diff --name-only "$mb" -- .
             git -C "$orbit_root" ls-files --others --exclude-standard --full-name -- .; } | sort -u)
else
  while IFS= read -r f; do files+=("$f"); done < <(find "$orbit_root" -type f \( -name '*.json' -o -name '*.md' \) | sort)
fi
# Keep records and notes, drop everything else.
sel=()
for f in ${files[@]+"${files[@]}"}; do
  skip_upstream_record "$f" && continue
  case "$f" in */history/*) continue ;; esac  # frozen Plan revisions
  case "$f" in *.json|*.md) sel+=("$f") ;; esac
done
if [ "${#sel[@]}" -eq 0 ]; then
  echo "records-lint: OK (validate passed; no changed record files)"
  exit 0
fi

# Filter for both field readers: a text path, not an identifier or date.
SKIP_RE='^(id|specVersion|status|basedOn|repositories|repositoryId|commit|branch|url|observedAt|reconciledAt|outcomeId|criterionId|planId|planRevision|projectSnapshotId|contributesTo)$|Id$'

# Text fields of a record: every string except identifiers, provenance and dates.
text_fields() {
  jq -r --arg skip "$SKIP_RE" '
    . as $r
    | [paths(type == "string")]
    | .[]
    | select(all(.[]; tostring | test($skip) | not))
    | . as $p | $r | getpath($p)
  ' "$1" 2>/dev/null
}

# old_copy <file>: write the merge-base copy of a tracked file to a temp file
# and print its path. Print nothing when the lint checks all text or the file
# is new.
old_copy() {
  [ "$use_diff" -eq 1 ] || return 0
  local rel tmp
  rel="${1#"$top"/}"
  tmp=$(mktemp "${TMPDIR:-/tmp}/records-lint-old.XXXXXX") || return 0
  if git -C "$top" show "$mb:$rel" > "$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
    echo "$tmp"
  else
    rm -f "$tmp"
  fi
}

# changed_text <file>: the text that checks 3 needs. Text fields whose value
# differs from the merge base (JSON), or added and changed lines (notes).
changed_text() {
  local f="$1" old
  case "$f" in
    *.json)
      old=$(old_copy "$f")
      if [ -z "$old" ]; then text_fields "$f"; return 0; fi
      jq -r --slurpfile old "$old" --arg skip "$SKIP_RE" '
        . as $r | $old[0] as $o
        | [paths(type == "string")] | .[]
        | select(all(.[]; tostring | test($skip) | not))
        | . as $p
        | select((try ($o | getpath($p)) catch null) != ($r | getpath($p)))
        | $r | getpath($p)
      ' "$f" 2>/dev/null
      rm -f "$old"
      ;;
    *)
      if [ "$use_diff" -eq 1 ] && git -C "$top" ls-files --error-unmatch "${f#"$top"/}" >/dev/null 2>&1 \
         && git -C "$top" cat-file -e "$mb:${f#"$top"/}" 2>/dev/null; then
        git -C "$top" diff -U0 "$mb" -- "${f#"$top"/}" | grep '^+' | grep -v '^+++' | sed 's/^+//'
      else
        cat "$f"
      fi
      ;;
  esac
}

# 2. Leak scrub, one pass per file over its text.
for f in "${sel[@]}"; do
  tmp=$(mktemp "${TMPDIR:-/tmp}/records-lint.XXXXXX") || fail 20 leak-scrub "$f" "cannot create a temp file"
  case "$f" in
    *.json) text_fields "$f" > "$tmp" ;;
    *) cp "$f" "$tmp" ;;
  esac
  if ! out=$("$leak_scrub" "$repo" "records" "$tmp" 2>&1); then
    rm -f "$tmp"
    fail 11 leak-scrub "$f" "the leak scrub blocked this text. $out"
  fi
  rm -f "$tmp"
done

# 3. Sentence length, record JSON only. Notes are prose, a person reads them.
for f in "${sel[@]}"; do
  case "$f" in *.json) ;; *) continue ;; esac
  long=$(changed_text "$f" | awk -v max="$MAX_WORDS" '
    { gsub(/[.!?]+[ \t]+/, "&\n"); n = split($0, parts, "\n")
      for (i = 1; i <= n; i++) { w = split(parts[i], words, /[ \t]+/); c = 0
        for (j = 1; j <= w; j++) if (words[j] != "") c++
        if (c > max) { print c ": " substr(parts[i], 1, 60) "..."; exit } } }')
  [ -z "$long" ] || fail 12 sentence "$f" "a sentence has more than $MAX_WORDS words ($long)"
done

# 4. Missing and Next rule, reconciliation records only.
for f in "${sel[@]}"; do
  case "$f" in *.json) ;; *) continue ;; esac
  [ "$(jq -r '.criterionAssessments | type' "$f" 2>/dev/null)" = "array" ] || continue
  old=$(old_copy "$f")
  if [ -n "$old" ]; then
    # Only an assessment whose explanation or status changed.
    bad=$(jq -r --slurpfile old "$old" '
      (($old[0].criterionAssessments // []) | if type == "array" then . else [] end) as $oa
      | .criterionAssessments[] | . as $a
      | select(($oa | map(select(.criterionId == $a.criterionId)) | .[0]) as $p
          | ($p.explanation // null) != ($a.explanation // null) or ($p.status // null) != ($a.status // null))
      | select(.status != "achieved")
      | select((.explanation // "") | test("^Missing: .+ Next: .+") | not)
      | .criterionId' "$f" | head -1)
    rm -f "$old"
  else
    bad=$(jq -r '.criterionAssessments[]
    | select(.status != "achieved")
    | select((.explanation // "") | test("^Missing: .+ Next: .+") | not)
    | .criterionId' "$f" | head -1)
  fi
  [ -z "$bad" ] || fail 13 missing-next "$f" "criterion $bad is not achieved. Its explanation must read \"Missing: <what>. Next: <action>.\""
done

# 5. Local paths, records and notes.
pattern='(/Users/|/home/[A-Za-z]|/private/tmp|/var/folders/|/tmp/|[A-Za-z]:\\\\|~/)'
for f in "${sel[@]}"; do
  hit=$(grep -nE "$pattern" "$f" | head -1)
  [ -z "$hit" ] || fail 14 local-path "$f" "a local path appears at line ${hit%%:*}. Use a repository-relative path."
done

# 6. Interview evidence for each new or changed Plan (all Plans with --all).
for f in "${sel[@]}"; do
  case "$f" in */plans/*.json) ;; *) continue ;; esac
  plan_id=$(jq -er '.id' "$f") || fail 16 interview "$f" "Cannot read Plan ID."
  notes="$(dirname "$f")/$plan_id.notes.md"
  [ -f "$notes" ] && grep -qE '^## Interview[[:space:]]*$' "$notes" ||
    fail 16 interview "$notes" "Missing ## Interview section."
  for question in q1-outcome q2-intent q3-outcomes q4-acceptance q5-constraints q6-save; do
    awk -v question="$question" '
      /^## Interview[[:space:]]*$/ { interview=1; next }
      /^#{1,2}[[:space:]]/ { interview=0 }
      interview && $0 ~ "^- [0-9]{4}-[0-9]{2}-[0-9]{2}, " question ":[[:space:]]*[^[:space:]]" { found=1 }
      END { exit !found }
    ' "$notes" || fail 16 interview "$notes" "Missing dated answer for $question in ## Interview."
  done
done

echo "records-lint: OK (${#sel[@]} file(s) checked)"
