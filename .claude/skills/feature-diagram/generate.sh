#!/usr/bin/env bash
# /feature-diagram generate.sh — emit a per-feature Mermaid sub-graph
# markdown for one feature row in the consolidated feature matrix at
# projects/<name>/feature-inventory.md.
#
# Usage:
#   generate.sh <inventory.md> <feature-slug> [project-name]
#
# Output: the per-feature markdown is printed on stdout. The skill (or
# test driver) is responsible for writing it to the right path.
#
# Exit codes:
#   0  — success, markdown emitted on stdout
#   2  — bad input (file missing, slug not found in inventory)
#   3  — internal error (could not parse a row)
#
# Inventory format expected (matches /extract-features SKILL.md § "Write
# the inventory"):
#
#   ## Consolidated feature matrix
#
#   | # | Feature | Surface | Status | Source | Notes |
#   |---|---------|---------|--------|--------|-------|
#   | 1 | Create order | API + UI | Active | route + test + UI | POST /api/orders |
#   ...
#
#   ## Per-axis findings
#
#   ### HTTP routes / entry points (N)
#   | Method | Path | Handler | File | Notes |
#   ...
#
#   ### Data models / DB schema (N)
#   | Model | Table | Fields | Relations | File |
#   ...
#
#   ### Async jobs / queue handlers (N)
#   | Job | Trigger | Handler | File |
#   ...
#
#   ### UI screens / forms / interactions (N)
#   | Route | Component | Fields | File |
#   ...
#
# This is the canonical grep-fallback path. The skill itself (run inside
# Claude Code) builds a richer model with LSP queries and call-graph
# walks; this helper is the deterministic baseline so the smoke test
# can exercise the emit logic without an LLM in the loop.

set -uo pipefail

INVENTORY="${1:-}"
SLUG="${2:-}"
PROJECT="${3:-unknown}"

if [ -z "$INVENTORY" ] || [ -z "$SLUG" ]; then
  echo "usage: generate.sh <inventory.md> <feature-slug> [project-name]" >&2
  exit 2
fi

if [ ! -f "$INVENTORY" ]; then
  echo "generate.sh: inventory file not found: $INVENTORY" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Find the matched row in the consolidated feature matrix.
# ---------------------------------------------------------------------------

# Kebab-case-ify a string: lowercase, alphanumerics + spaces only, spaces → -
kebab() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# Extract every row in the consolidated feature matrix (the table whose
# header includes "| Feature |"). Stop at the next "##" heading.
ROWS_FILE=$(mktemp -t fd-rows-XXXXXX)
trap 'rm -f "$ROWS_FILE"' EXIT

awk '
  /^##[[:space:]]+Consolidated feature matrix/ { in_section = 1; next }
  in_section && /^##[[:space:]]/ { in_section = 0; next }
  in_section && /^\|[[:space:]]*[0-9]+[[:space:]]*\|/ { print }
' "$INVENTORY" > "$ROWS_FILE"

if [ ! -s "$ROWS_FILE" ]; then
  echo "generate.sh: no consolidated feature matrix found in $INVENTORY" >&2
  exit 2
fi

# Build the slug → row map; collect available slugs for the error path.
MATCHED_ROW=""
AVAILABLE_SLUGS=()
while IFS= read -r row; do
  # Column 2 is the Feature column. Strip any existing markdown link wrapping.
  feature=$(echo "$row" | awk -F'|' '{print $3}' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
  # Remove [text](features/<slug>.md) wrapper if present, capturing the link text.
  feature_text=$(echo "$feature" | sed -E 's/^\[([^]]+)\]\(features\/[^)]+\)$/\1/')
  row_slug=$(kebab "$feature_text")
  AVAILABLE_SLUGS+=("$row_slug")
  if [ "$row_slug" = "$SLUG" ]; then
    MATCHED_ROW="$row"
  fi
done < "$ROWS_FILE"

if [ -z "$MATCHED_ROW" ]; then
  echo "generate.sh: no feature matches slug '$SLUG' in $INVENTORY" >&2
  echo "" >&2
  echo "Available slugs:" >&2
  for s in "${AVAILABLE_SLUGS[@]}"; do
    echo "  $s" >&2
  done
  echo "" >&2
  echo "Re-run with one of these, or check the inventory file." >&2
  exit 2
fi

# Parse the matched row's columns. Pipe layout is:
#   | # | Feature | Surface | Status | Source | Notes |
ROW_NUM=$(echo    "$MATCHED_ROW" | awk -F'|' '{print $2}' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
FEATURE=$(echo    "$MATCHED_ROW" | awk -F'|' '{print $3}' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^\[([^]]+)\]\(features\/[^)]+\)$/\1/')
SURFACE=$(echo    "$MATCHED_ROW" | awk -F'|' '{print $4}' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
STATUS_COL=$(echo "$MATCHED_ROW" | awk -F'|' '{print $5}' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
SOURCE=$(echo     "$MATCHED_ROW" | awk -F'|' '{print $6}' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
NOTES=$(echo      "$MATCHED_ROW" | awk -F'|' '{print $7}' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')

# ---------------------------------------------------------------------------
# Decide which axes are populated based on the Source column.
# ---------------------------------------------------------------------------

has_routes=0
has_models=0
has_jobs=0
has_screens=0

case "$SOURCE" in
  *route*)  has_routes=1 ;;
esac
case "$SOURCE" in
  *model*)  has_models=1 ;;
esac
case "$SOURCE" in
  *job*)    has_jobs=1 ;;
esac
case "$SOURCE" in
  *UI*|*ui*|*screen*) has_screens=1 ;;
esac

# ---------------------------------------------------------------------------
# Extract per-axis findings from the inventory.
#
# Strategy: for each `### <Axis name>` table, take every row whose
# Notes / File / Handler mentions a token from the feature title or the
# Notes column. Conservative: when in doubt, include — the human reviews
# the diagram.
# ---------------------------------------------------------------------------

extract_axis() {
  # extract_axis "axis-heading-regex" "inventory-file" "filter-token-regex"
  local heading_re="$1"
  local file="$2"
  local filter_re="$3"
  awk -v hre="$heading_re" -v fre="$filter_re" '
    $0 ~ hre { in_section = 1; header_seen = 0; next }
    in_section && /^##[[:space:]]/ { in_section = 0; next }
    in_section && /^###[[:space:]]/ { in_section = 0; next }
    in_section && /^\|[-:[:space:]|]+\|$/ { header_seen = 1; next }
    in_section && header_seen && /^\|/ {
      # Filter rows by the filter regex (case-insensitive).
      lower = tolower($0)
      lower_filter = tolower(fre)
      if (fre == "" || match(lower, lower_filter)) {
        print
      }
    }
  ' "$file"
}

# Build a filter token from the feature title + notes. Use the first
# significant word from the title and any HTTP path from the notes.
title_tokens=$(echo "$FEATURE" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9 \n' | awk '{for(i=1;i<=NF;i++) if(length($i)>3) print $i}' | head -3)
notes_paths=$(echo "$NOTES" | grep -oE '/[a-zA-Z0-9_/-]+' | head -3)

# Build the OR regex.
filter_terms=""
for t in $title_tokens; do
  if [ -n "$filter_terms" ]; then filter_terms="$filter_terms|"; fi
  filter_terms="${filter_terms}${t}"
done
for p in $notes_paths; do
  # Escape slashes for regex
  esc=$(echo "$p" | sed 's_/_\\/_g')
  if [ -n "$filter_terms" ]; then filter_terms="$filter_terms|"; fi
  filter_terms="${filter_terms}${esc}"
done

# Fall back to .* if nothing usable was extracted (so we don't lose all rows).
[ -z "$filter_terms" ] && filter_terms=".*"

ROUTES_FILE=$(mktemp -t fd-routes-XXXXXX)
MODELS_FILE=$(mktemp -t fd-models-XXXXXX)
JOBS_FILE=$(mktemp -t fd-jobs-XXXXXX)
SCREENS_FILE=$(mktemp -t fd-screens-XXXXXX)
trap 'rm -f "$ROWS_FILE" "$ROUTES_FILE" "$MODELS_FILE" "$JOBS_FILE" "$SCREENS_FILE"' EXIT

if [ "$has_routes" = "1" ]; then
  extract_axis "^###[[:space:]]+HTTP routes" "$INVENTORY" "$filter_terms" > "$ROUTES_FILE"
fi
if [ "$has_models" = "1" ]; then
  extract_axis "^###[[:space:]]+Data models" "$INVENTORY" "$filter_terms" > "$MODELS_FILE"
fi
if [ "$has_jobs" = "1" ]; then
  extract_axis "^###[[:space:]]+Async jobs"  "$INVENTORY" "$filter_terms" > "$JOBS_FILE"
fi
if [ "$has_screens" = "1" ]; then
  extract_axis "^###[[:space:]]+UI screens"  "$INVENTORY" "$filter_terms" > "$SCREENS_FILE"
fi

# Count rows safely — grep -c exits 1 when no matches, so wrap with `|| true`
# to avoid `|| echo 0` doubling output when the file exists but has 0 matches.
count_rows() {
  local f="$1"
  if [ ! -f "$f" ]; then
    echo 0
    return
  fi
  local c
  c=$(grep -c '^|' "$f" 2>/dev/null || true)
  # grep -c always prints exactly one number; default to 0 if grep returned empty.
  echo "${c:-0}"
}

ROUTES_COUNT=$(count_rows "$ROUTES_FILE")
MODELS_COUNT=$(count_rows "$MODELS_FILE")
JOBS_COUNT=$(count_rows "$JOBS_FILE")
SCREENS_COUNT=$(count_rows "$SCREENS_FILE")

# ---------------------------------------------------------------------------
# Emit the Mermaid flowchart + the surrounding markdown.
# ---------------------------------------------------------------------------

# kebab-case-ify and node-ID-safe a string
node_slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//' | cut -c1-40
}

today=$(date +%Y-%m-%d)

cat <<HEADER
# ${FEATURE}

> Per-feature architectural slice for **${FEATURE}**. Generated from the consolidated feature matrix in [\`../feature-inventory.md\`](../feature-inventory.md).

**Status**: ${STATUS_COL}
**Surface**: ${SURFACE}
**Source axes**: ${SOURCE}
**Notes**: ${NOTES}

## Diagram

\`\`\`mermaid
flowchart LR
HEADER

# Subgraph: Screens
echo "    subgraph Screens[\"UI Screens\"]"
if [ "$SCREENS_COUNT" -ge 1 ]; then
  i=0
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    component=$(echo "$row" | awk -F'|' '{print $3}' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
    file=$(echo "$row"     | awk -F'|' '{print $5}' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$component" ] && continue
    nid="screen_$(node_slug "$component")_${i}"
    echo "        ${nid}[\"${component}<br/>(${file})\"]"
    i=$((i + 1))
  done < "$SCREENS_FILE"
else
  echo "        Screens_empty[\"(none)\"]"
fi
echo "    end"

# Subgraph: Routes
echo "    subgraph Routes[\"HTTP Routes\"]"
if [ "$ROUTES_COUNT" -ge 1 ]; then
  i=0
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    method=$(echo "$row" | awk -F'|' '{print $2}' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
    path=$(echo "$row"   | awk -F'|' '{print $3}' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
    file=$(echo "$row"   | awk -F'|' '{print $5}' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$method" ] && continue
    nid="route_$(node_slug "${method}_${path}")_${i}"
    echo "        ${nid}[\"${method} ${path}<br/>(${file})\"]"
    i=$((i + 1))
  done < "$ROUTES_FILE"
else
  echo "        Routes_empty[\"(none)\"]"
fi
echo "    end"

# Subgraph: Models
echo "    subgraph Models[\"Data Models\"]"
if [ "$MODELS_COUNT" -ge 1 ]; then
  i=0
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    model=$(echo "$row" | awk -F'|' '{print $2}' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
    file=$(echo "$row"  | awk -F'|' '{print $6}' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$model" ] && continue
    nid="model_$(node_slug "$model")_${i}"
    echo "        ${nid}[\"${model}<br/>(${file})\"]"
    i=$((i + 1))
  done < "$MODELS_FILE"
else
  echo "        Models_empty[\"(none)\"]"
fi
echo "    end"

# Subgraph: Jobs
echo "    subgraph Jobs[\"Async Jobs\"]"
if [ "$JOBS_COUNT" -ge 1 ]; then
  i=0
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    job=$(echo "$row"  | awk -F'|' '{print $2}' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
    file=$(echo "$row" | awk -F'|' '{print $5}' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$job" ] && continue
    nid="job_$(node_slug "$job")_${i}"
    echo "        ${nid}[\"${job}<br/>(${file})\"]"
    i=$((i + 1))
  done < "$JOBS_FILE"
else
  echo "        Jobs_empty[\"(none)\"]"
fi
echo "    end"

# Edges — inferred from which axes are populated. The base helper draws
# canonical first-of-axis → first-of-axis arrows; the Claude-driven path
# refines these per-element.
echo ""
echo "    %% Edges inferred from inventory source axes: ${SOURCE}"
if [ "$SCREENS_COUNT" -ge 1 ] && [ "$ROUTES_COUNT" -ge 1 ]; then
  echo "    Screens -->|submits| Routes"
fi
if [ "$ROUTES_COUNT" -ge 1 ] && [ "$MODELS_COUNT" -ge 1 ]; then
  echo "    Routes -->|reads/writes| Models"
fi
if [ "$ROUTES_COUNT" -ge 1 ] && [ "$JOBS_COUNT" -ge 1 ]; then
  echo "    Routes -->|enqueues| Jobs"
fi
if [ "$JOBS_COUNT" -ge 1 ] && [ "$MODELS_COUNT" -ge 1 ]; then
  echo "    Jobs -->|reads/writes| Models"
fi

cat <<'CLOSE'
```

CLOSE

# Participating elements section
cat <<TABLES
## Participating elements

### HTTP Routes (${ROUTES_COUNT})

TABLES
if [ "$ROUTES_COUNT" -ge 1 ]; then
  echo "| Method | Path | Handler | File | Notes |"
  echo "|--------|------|---------|------|-------|"
  cat "$ROUTES_FILE"
else
  echo "_(none)_"
fi

cat <<TABLES

### Data Models (${MODELS_COUNT})

TABLES
if [ "$MODELS_COUNT" -ge 1 ]; then
  echo "| Model | Table | Fields | Relations | File |"
  echo "|-------|-------|--------|-----------|------|"
  cat "$MODELS_FILE"
else
  echo "_(none)_"
fi

cat <<TABLES

### Async Jobs (${JOBS_COUNT})

TABLES
if [ "$JOBS_COUNT" -ge 1 ]; then
  echo "| Job | Trigger | Handler | File |"
  echo "|-----|---------|---------|------|"
  cat "$JOBS_FILE"
else
  echo "_(none)_"
fi

cat <<TABLES

### UI Screens (${SCREENS_COUNT})

TABLES
if [ "$SCREENS_COUNT" -ge 1 ]; then
  echo "| Route | Component | Fields | File |"
  echo "|-------|-----------|--------|------|"
  cat "$SCREENS_FILE"
else
  echo "_(none)_"
fi

cat <<FOOTER

## Coverage gaps

The inventory's axes corroborate this feature as: \`${SOURCE}\`.
Anything not surfaced above (business rules, permission matrices,
implicit configuration-driven behaviour) requires human review of the
code — see [\`../feature-inventory.md\`](../feature-inventory.md) §
"Coverage gaps" for the full list.

---

_Generated by \`/feature-diagram\` on ${today}. Re-run when the feature's surfaces change._
FOOTER

exit 0
