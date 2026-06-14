#!/bin/bash
# render-trend.sh — render the "Trend (last N runs)" section for /launch-check.
#
# Reads the runs directory (one JSON file per run, schema below), sorts by
# `ts`, takes the last N (default 5), and emits a markdown trend block:
#   - heading
#   - table (Date | Score | Verdict | Notes)
#   - ASCII chart of scores over the same window
#
# Auto-notes column is derived from the score-delta vs the previous run
# (e.g. "Security +12, Perf +5"). The most recent row notes "This run".
# Operator-supplied notes are v2 (apexyard#183 v1 scope).
#
# Usage:
#   render-trend.sh <runs_dir> [window]
#
# Behaviour:
#   - Window defaults to 5.
#   - With < 2 runs in the dir: prints nothing, exits 0. Callers (the
#     /launch-check skill) suppress the trend section when there's no
#     trend to show.
#   - With >= 2 runs: prints the trend markdown block to stdout.
#
# JSON schema per run file (apexyard#183):
#   {
#     "ts": "2026-05-08T19:30:00Z",      # ISO-8601 UTC, used for sort
#     "branch": "main",
#     "commit": "abc1234",
#     "scores": {
#       "security": 88, "accessibility": 94, "compliance": 76,
#       "analytics": 90, "seo": 87, "performance": 68,
#       "monitoring": 83, "docs": 91
#     },
#     "verdict": "go" | "go-with-warnings" | "conditional-go" | "no-go",
#     "top_risks": ["...", "..."]
#   }
#
# The headline score is the unweighted mean of scores.* — rounded to int.
# Forward-compatible: extra fields in the JSON are preserved as-is by
# /launch-check (the skill writes the file; this script only reads), so
# adopters with existing run files continue to work after framework upgrade.
#
# Dependencies: jq, sort, awk. No network calls.

set -u

RUNS_DIR="${1:-}"
WINDOW="${2:-5}"

if [ -z "$RUNS_DIR" ]; then
  echo "usage: render-trend.sh <runs_dir> [window]" >&2
  exit 2
fi

if [ ! -d "$RUNS_DIR" ]; then
  # No runs dir => no trend. Treat as "first run".
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "render-trend.sh: jq is required (install via brew install jq / apt install jq)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Collect run files, sort chronologically by `ts`.
# Tab-separated: <ts>\t<path>. Sort by first column.
# ---------------------------------------------------------------------------
runs_tsv=$(
  for f in "$RUNS_DIR"/*.json; do
    [ -f "$f" ] || continue
    ts=$(jq -r '.ts // ""' "$f" 2>/dev/null) || ts=""
    [ -n "$ts" ] || continue
    printf '%s\t%s\n' "$ts" "$f"
  done | sort
)

run_count=$(printf '%s' "$runs_tsv" | grep -c . || true)
if [ "${run_count:-0}" -lt 2 ]; then
  # Fewer than 2 runs => no trend section (matches AC: "if 2+ prior runs exist").
  exit 0
fi

# Take the last $WINDOW lines.
window_tsv=$(printf '%s\n' "$runs_tsv" | tail -n "$WINDOW")

# ---------------------------------------------------------------------------
# Compute the headline score per run = round(mean(scores.*)).
# Build parallel arrays: dates[], scores[], verdicts[], score_blobs[].
# ---------------------------------------------------------------------------
dates=()
scores=()
verdicts=()
score_blobs=()  # full scores object per run, for delta computation

while IFS=$'\t' read -r ts path; do
  [ -n "$ts" ] || continue
  date=$(printf '%s' "$ts" | cut -c1-10)  # YYYY-MM-DD
  verdict=$(jq -r '.verdict // "?"' "$path")
  blob=$(jq -c '.scores // {}' "$path")
  # Mean of the values in .scores. If empty, score = 0.
  mean=$(jq -r '
    (.scores // {}) as $s
    | ($s | to_entries | map(.value) ) as $v
    | if ($v | length) == 0 then 0
      else (($v | add) / ($v | length)) | round
      end
  ' "$path")
  dates+=("$date")
  scores+=("$mean")
  verdicts+=("$verdict")
  score_blobs+=("$blob")
done <<< "$window_tsv"

n=${#dates[@]}
if [ "$n" -lt 2 ]; then
  # Defensive — shouldn't happen given the count check above.
  exit 0
fi

# ---------------------------------------------------------------------------
# Per-row notes: diff this run's scores against the previous run's.
# Format: "Dim +N, Dim2 +M" for top 2 deltas by abs value. Negatives shown.
# Last row gets "This run" appended.
# ---------------------------------------------------------------------------
notes=()
for i in "${!dates[@]}"; do
  if [ "$i" -eq 0 ]; then
    notes+=("Initial baseline")
    continue
  fi
  prev="${score_blobs[$((i-1))]}"
  curr="${score_blobs[$i]}"
  # jq computes deltas, sorts by abs desc, takes top 2, formats "Dim +N".
  delta_str=$(jq -nr \
    --argjson prev "$prev" --argjson curr "$curr" '
    [ ($curr | to_entries[] )
      | { dim: .key,
          delta: (.value - ($prev[.key] // .value)) }
    ]
    | map(select(.delta != 0))
    | sort_by(-( .delta | if . < 0 then -. else . end ))
    | .[0:2]
    | map(
        ((.dim | .[0:1] | ascii_upcase) + (.dim | .[1:]))
        + " "
        + (if .delta > 0 then "+" else "" end)
        + (.delta | tostring)
      )
    | join(", ")
  ')
  if [ -z "$delta_str" ]; then
    delta_str="No change vs previous"
  fi
  if [ "$i" -eq $((n - 1)) ]; then
    delta_str="${delta_str} (this run)"
  fi
  notes+=("$delta_str")
done

# ---------------------------------------------------------------------------
# Render the trend section.
# ---------------------------------------------------------------------------
echo "## Trend (last ${n} runs)"
echo ""
echo "| Date       | Score | Verdict          | Notes |"
echo "|------------|-------|------------------|-------|"
for i in "${!dates[@]}"; do
  printf '| %-10s | %5s | %-16s | %s |\n' \
    "${dates[$i]}" "${scores[$i]}" "${verdicts[$i]}" "${notes[$i]}"
done
echo ""

# ---------------------------------------------------------------------------
# ASCII chart — score vs time.
# Y-axis: range derived from min/max scores in window, padded by 5.
# X-axis: dates labeled below.
# ---------------------------------------------------------------------------
min=$(printf '%s\n' "${scores[@]}" | sort -n | head -1)
max=$(printf '%s\n' "${scores[@]}" | sort -n | tail -1)
# Pad and clamp to [0, 100].
y_lo=$(( min - 5 )); [ "$y_lo" -lt 0 ] && y_lo=0
y_hi=$(( max + 5 )); [ "$y_hi" -gt 100 ] && y_hi=100
[ "$y_hi" -le "$y_lo" ] && y_hi=$(( y_lo + 10 ))

# 5 horizontal grid lines, evenly spaced across [y_lo, y_hi].
rows=5
range=$(( y_hi - y_lo ))

echo "Score trend:"
echo ""
# Column width = 6 chars per run (matches MM-DD label width + 1 space).
COL_W=6
for ((r = rows - 1; r >= 0; r--)); do
  level=$(( y_lo + (range * r) / (rows - 1) ))
  line=$(printf '%3d |' "$level")
  for j in "${!scores[@]}"; do
    s="${scores[$j]}"
    # Map s to a row index in [0, rows-1].
    row_for_s=$(( ((s - y_lo) * (rows - 1) + range / 2) / range ))
    if [ "$row_for_s" -eq "$r" ]; then
      line="${line}   ●  "  # 3 leading spaces + dot + 2 trailing = 6 cols
    else
      line="${line}      "
    fi
  done
  echo "$line"
done
# X axis line.
xaxis="    +"
for _ in "${!scores[@]}"; do xaxis="${xaxis}------"; done
echo "$xaxis"
# Date labels — abbreviated MM-DD, 6 chars each so labels don't collide.
labels="     "
for d in "${dates[@]}"; do
  short=$(printf '%s' "$d" | cut -c6-)  # MM-DD
  labels="${labels}${short} "
done
echo "$labels"
