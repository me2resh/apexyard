#!/usr/bin/env bash
# record-check.sh — write a reconciliation only on a status change (AgDR-0225, ac8-3).
#
# Compares a candidate Reconciliation with the previous one. If any criterion
# status differs, or a criterion is added or removed, prints "changed: <ids>"
# and keeps the candidate. Otherwise prints "unchanged", deletes the candidate
# and appends one dated line to the "## Checks" section of the plan notes.
#
# Usage: record-check.sh --previous <file> --candidate <file> --notes <file> --commit <sha> [--date YYYY-MM-DD]
# Exit: 0 either way; 20 usage or bad input; 21 previous and candidate are the same file.

set -u
previous=""; candidate=""; notes=""; commit=""; date_str=""
usage() { echo "Usage: record-check.sh --previous <file> --candidate <file> --notes <file> --commit <sha> [--date YYYY-MM-DD]" >&2; exit 20; }
while [ $# -gt 0 ]; do
  case "$1" in
    --previous) [ $# -ge 2 ] || usage; previous="$2"; shift 2 ;;
    --candidate) [ $# -ge 2 ] || usage; candidate="$2"; shift 2 ;;
    --notes) [ $# -ge 2 ] || usage; notes="$2"; shift 2 ;;
    --commit) [ $# -ge 2 ] || usage; commit="$2"; shift 2 ;;
    --date) [ $# -ge 2 ] || usage; date_str="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$previous" ] && [ -n "$candidate" ] && [ -n "$notes" ] && [ -n "$commit" ] || usage
for f in "$previous" "$candidate" "$notes"; do [ -f "$f" ] || { echo "record-check: file not found: $f" >&2; exit 20; }; done
command -v jq >/dev/null 2>&1 || { echo "record-check: jq is required." >&2; exit 20; }
[ -n "$date_str" ] || date_str=$(date -u +%Y-%m-%d)

# Refuse when both paths name one file: the unchanged branch deletes the candidate.
real_path() { printf '%s/%s' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"; }
if [ "$(real_path "$previous")" = "$(real_path "$candidate")" ] || [ "$previous" -ef "$candidate" ]; then
  echo "record-check: --previous and --candidate are the same file ($previous). Refusing: nothing was changed or deleted." >&2
  exit 21
fi

statuses() { jq -c '[.criterionAssessments[] | {(.criterionId): .status}] | add // {}' "$1"; }
prev=$(statuses "$previous") || { echo "record-check: cannot read $previous" >&2; exit 20; }
cand=$(statuses "$candidate") || { echo "record-check: cannot read $candidate" >&2; exit 20; }

changed=$(jq -rn --argjson a "$prev" --argjson b "$cand" \
  '[($a + $b | keys[]) | select($a[.] != $b[.])] | join(",")')

if [ -n "$changed" ]; then
  echo "changed: $changed"
  exit 0
fi

line="- $date_str, $commit: checked, no change."
if grep -qxF -- "$line" "$notes"; then
  rm -f "$candidate"
  echo "unchanged"
  exit 0
fi
grep -q '^## Checks[[:space:]]*$' "$notes" || printf '\n## Checks\n' >> "$notes"
# Insert after the last non-blank line of the Checks section.
tmp=$(mktemp "${TMPDIR:-/tmp}/record-check.XXXXXX") || exit 20
awk -v line="$line" '
  { lines[NR] = $0 }
  /^## Checks[[:space:]]*$/ { start = NR }
  END {
    end = NR
    for (i = start + 1; i <= NR; i++) if (lines[i] ~ /^## /) { end = i - 1; break }
    last = start
    for (i = start + 1; i <= end; i++) if (lines[i] !~ /^[[:space:]]*$/) last = i
    for (i = 1; i <= NR; i++) {
      print lines[i]
      if (i == last && last == start) {
        # An empty section gets one blank line under the heading.
        print ""
        print line
        # Separate the entry from a following line that is not blank.
        if (last < NR && lines[last + 1] !~ /^[[:space:]]*$/) print ""
      } else if (i == last) {
        if (lines[last] !~ /^- /) print ""
        print line
      }
    }
  }' "$notes" > "$tmp" && cat "$tmp" > "$notes"
rm -f "$tmp" "$candidate"
echo "unchanged"
