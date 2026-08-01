#!/bin/bash
# _lib-audit-history.sh — shared persistence + trend rendering for audit skills.
#
# Generalises the per-run JSON + per-run MD + opt-in commit marker
# convention that /launch-check has shipped since #183 (see AgDR-0014).
# Other audit skills (/threat-model, /security-review, /compliance-check,
# /accessibility-audit, /performance-audit, /seo-audit, /monitoring-audit,
# /docs-audit, /analytics-audit) consume this lib so their per-run
# artefacts share the same on-disk shape and the trend across runs is
# legible.
#
# Design + decision rationale:
#   docs/technical-designs/audit-artefact-persistence.md
#   docs/agdr/AgDR-0019-audit-artefact-persistence.md
#
# Functions (sourced; do not exec this file directly):
#   audit_resolve_dir <project_name> <dimension>
#       Echoes <projects_dir>/<project_name>/audits/<dimension>/. Creates
#       it if missing.
#
#   audit_run_persist <project_name> <dimension> <ts> <verdict> <score> <body_file>
#       Reads a JSON payload from stdin (must contain a findings[] array,
#       optionally a stats{} object). Writes two artefacts:
#         <dim_dir>/runs/<ts_safe>.json    (the stdin JSON, augmented with
#                                           top-level ts/dimension/verdict/score)
#         <dim_dir>/<ts_safe>.md           (skill-provided body prefixed with
#                                           generated YAML frontmatter)
#       Updates <dim_dir>/.gitignore based on .audit-history-tracked
#       marker presence.
#
#   audit_run_list <project_name> <dimension> [limit]
#       Prints filenames of last <limit> JSON runs (default 10), sorted
#       by ts ascending. Reads the canonical path AND the legacy
#       launch-check path (projects/<name>/launch-check/runs/) when
#       <dimension> is "launch-check" — non-destructive backward compat
#       per AgDR-0019.
#
#   audit_render_trend <project_name> <dimension> [window]
#       Loads the last <window> JSON runs (default 5), emits a markdown
#       trend block (heading + table + ASCII chart) to stdout. Silent
#       (exit 0) when fewer than 2 runs exist.
#
# Dependencies: jq, awk, sort, mkdir. No network calls.
# Sourced by audit-skill SKILL.md flows; never invoked as a standalone
# command.

# Don't run twice in the same shell.
[ -n "${_LIB_AUDIT_HISTORY_SOURCED:-}" ] && return 0
_LIB_AUDIT_HISTORY_SOURCED=1

# Locate the lib's own dir so we can source siblings (read-config, portfolio-paths).
# ${BASH_SOURCE[0]} is bash-only and unset under zsh (#1025) — the `:-` default
# avoids a hard "parameter not set" error, and the git-rev-parse fallback below
# is the actual portability fix (works under any shell, since it only depends
# on `git`, not on a bash-only parameter).
_AUDIT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)"
# me2resh/apexyard#1062: under a non-bash shell BASH_SOURCE is empty, so the resolution above
# degrades to the CALLER's cwd (dirname "" -> "."). Discard a cwd-derived path so the anchored
# git-root check below must validate it; a genuine BASH_SOURCE path is where this file lives and
# is kept as-is (#1061 only anchored the git-derived fallback, not this cwd-derived branch).
if [ -z "${BASH_SOURCE[0]:-}" ]; then _AUDIT_LIB_DIR=""; fi
if [ -z "$_AUDIT_LIB_DIR" ] || [ ! -f "$_AUDIT_LIB_DIR/_lib-read-config.sh" ]; then
  _audit_root="$(git rev-parse --show-toplevel 2>/dev/null)"
  # me2resh/apexyard#1033: only accept a git-derived root that is actually
  # an apexyard fork. Without this the fallback sources a trust-chain
  # library out of ANY repo the cwd happens to be inside -- a
  # workspace/<project> clone, or an unrelated checkout.
  #
  # This narrows an ACCIDENT surface. It is NOT an access-control boundary:
  # the anchors are unauthenticated presence-only files, and -f follows
  # symlinks, so anyone able to write to the candidate root can satisfy it.
  # What it prevents is a cwd-driven misresolution, not a hostile library.
  # Anchor pair per AgDR-0021 §A/§E -- the same test
  # resolve_ops_root_walk applies, evaluated against one candidate rather
  # than a walk. (resolve_ops_root itself is unusable here: three of these
  # sites are locating _lib-ops-root.sh, and its pin is session-scoped.)
  if [ -n "$_audit_root" ] && { [ -f "$_audit_root/.apexyard-fork" ] || { [ -f "$_audit_root/onboarding.yaml" ] && [ -f "$_audit_root/apexyard.projects.yaml" ]; }; } && [ -f "$_audit_root/.claude/hooks/_lib-read-config.sh" ]; then
    _AUDIT_LIB_DIR="$_audit_root/.claude/hooks"
  fi
  unset _audit_root
fi

if [ -n "$_AUDIT_LIB_DIR" ] && [ -f "$_AUDIT_LIB_DIR/_lib-read-config.sh" ]; then
  # shellcheck source=/dev/null
  . "$_AUDIT_LIB_DIR/_lib-read-config.sh"
fi
if [ -f "$_AUDIT_LIB_DIR/_lib-portfolio-paths.sh" ]; then
  # shellcheck source=/dev/null
  . "$_AUDIT_LIB_DIR/_lib-portfolio-paths.sh"
fi

# Render-trend.sh ships next to /launch-check; the trend rendering logic
# is currently launch-check-shaped. Until #218 absorbs render-trend.sh
# fully, we shell out to it for the launch-check dimension and use a
# generic findings-shaped renderer for everything else.
_AUDIT_RENDER_TREND_SH=""
if [ -n "$_AUDIT_LIB_DIR" ]; then
  _candidate="$(cd "$_AUDIT_LIB_DIR/.." 2>/dev/null && pwd)/skills/launch-check/render-trend.sh"
  [ -f "$_candidate" ] && _AUDIT_RENDER_TREND_SH="$_candidate"
fi

# ---------------------------------------------------------------------------
# audit_resolve_dir <project_name> <dimension>
# Echoes the canonical audit dir for the given project + dimension.
# Creates it if missing.
# ---------------------------------------------------------------------------
audit_resolve_dir() {
  local project_name="$1"
  local dimension="$2"
  if [ -z "$project_name" ] || [ -z "$dimension" ]; then
    echo "audit_resolve_dir: project_name and dimension required" >&2
    return 2
  fi

  local projects_dir
  if command -v portfolio_projects_dir >/dev/null 2>&1; then
    projects_dir=$(portfolio_projects_dir)
  else
    # Fallback: assume single-fork layout from the ops root.
    projects_dir="$(git rev-parse --show-toplevel 2>/dev/null)/projects"
  fi

  local dim_dir="$projects_dir/$project_name/audits/$dimension"
  mkdir -p "$dim_dir/runs"
  printf '%s' "$dim_dir"
}

# ---------------------------------------------------------------------------
# Internal: convert ISO-8601 ts to filesystem-safe form (colons → dashes).
# ---------------------------------------------------------------------------
_audit_ts_safe() {
  printf '%s' "$1" | tr ':' '-'
}

# ---------------------------------------------------------------------------
# Internal: write/refresh the dim's .gitignore based on opt-in marker.
# Marker present     → un-ignore *.json under runs/  (history committed)
# Marker absent      → ignore everything under runs/ (history local-only)
# ---------------------------------------------------------------------------
_audit_apply_marker() {
  local dim_dir="$1"
  local marker="$dim_dir/.audit-history-tracked"
  local gitignore="$dim_dir/.gitignore"
  if [ -f "$marker" ]; then
    cat > "$gitignore" <<'EOF'
# audit history is committed for this dimension
# (.audit-history-tracked marker is present)
!runs/
!runs/*.json
EOF
  else
    cat > "$gitignore" <<'EOF'
# audit history is local-only for this dimension
# (touch .audit-history-tracked to opt in to committed history)
runs/
EOF
  fi
}

# ---------------------------------------------------------------------------
# audit_run_persist <project_name> <dimension> <ts> <verdict> <score> <body_file>
# JSON payload from stdin. Writes JSON + MD pair.
# ---------------------------------------------------------------------------
audit_run_persist() {
  local project_name="$1"
  local dimension="$2"
  local ts="$3"
  local verdict="$4"
  local score="$5"
  local body_file="$6"

  if [ -z "$project_name" ] || [ -z "$dimension" ] || [ -z "$ts" ] \
     || [ -z "$verdict" ] || [ -z "$score" ] || [ -z "$body_file" ]; then
    echo "audit_run_persist: requires project_name, dimension, ts, verdict, score, body_file" >&2
    return 2
  fi
  if [ ! -f "$body_file" ]; then
    echo "audit_run_persist: body_file does not exist: $body_file" >&2
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "audit_run_persist: jq is required" >&2
    return 2
  fi

  local dim_dir
  dim_dir=$(audit_resolve_dir "$project_name" "$dimension") || return $?
  local ts_safe
  ts_safe=$(_audit_ts_safe "$ts")

  # Read stdin JSON. Augment with top-level metadata, derive stats from
  # findings[] if absent.
  #
  # Written to a scratch file in the SAME directory as the destination
  # first, then promoted with `mv` (atomic rename on one filesystem) only
  # if jq produced usable output. This is deliberately NOT just an
  # exit-status check: jq exits 0 on empty/absent stdin -- it reads no
  # input, emits no output, and reports success -- so a caller that
  # forgot to pipe a payload previously got a zero-byte run file promoted
  # AND a rc=0 "it worked" from this function (apexyard#1063). A reader
  # (`audit_run_list` / `audit_render_trend`) must never be able to
  # observe a partially-written or empty run file at json_path.
  local json_path="$dim_dir/runs/$ts_safe.json"
  local json_tmp
  json_tmp=$(mktemp "$dim_dir/runs/.audit-run-tmp.XXXXXX" 2>/dev/null) || {
    echo "audit_run_persist: mktemp failed while staging $json_path" >&2
    return 1
  }
  jq --arg ts "$ts" --arg dim "$dimension" --arg v "$verdict" --argjson s "$score" '
    . as $in
    | (.findings // []) as $f
    | (.stats // null) as $existing_stats
    | (
        $f
        | reduce .[] as $x ({"by_severity":{},"by_status":{}};
            .by_severity[$x.severity] = ((.by_severity[$x.severity] // 0) + 1)
            | .by_status[$x.status]   = ((.by_status[$x.status]   // 0) + 1)
          )
      ) as $derived_stats
    | $in
      + { ts: $ts, dimension: $dim, verdict: $v, score: $s,
          schema_version: ($in.schema_version // 1),
          stats: ($existing_stats // $derived_stats) }
  ' > "$json_tmp"
  local jq_rc=$?

  # Promotion gate: exit status alone is not enough (empty stdin exits 0
  # with zero bytes written) -- also require non-empty AND independently
  # re-parseable output before this run is allowed to exist on disk.
  if [ "$jq_rc" -ne 0 ] || [ ! -s "$json_tmp" ] || ! jq -e . "$json_tmp" >/dev/null 2>&1; then
    rm -f "$json_tmp"
    echo "audit_run_persist: jq produced no usable JSON for $json_path (rc=$jq_rc; empty or malformed stdin?)" >&2
    return 1
  fi

  mv "$json_tmp" "$json_path" || {
    rm -f "$json_tmp"
    echo "audit_run_persist: failed to move staged JSON into place at $json_path" >&2
    return 1
  }

  # Build frontmatter from the just-written JSON, then concatenate with
  # body -- staged the same way. Reaching this point means json_path
  # already holds a valid run, so an .md file can never be written
  # without a matching JSON run behind it (the orphan-.md defect also
  # reported in apexyard#1063).
  local md_path="$dim_dir/$ts_safe.md"
  local md_tmp
  md_tmp=$(mktemp "$dim_dir/.audit-run-tmp.XXXXXX" 2>/dev/null) || {
    echo "audit_run_persist: mktemp failed while staging $md_path" >&2
    return 1
  }
  local fm
  fm=$(jq -r '
    "---",
    "date: " + (.ts // "" | .[0:10]),
    "ts: " + (.ts // ""),
    "dimension: " + (.dimension // ""),
    "verdict: " + (.verdict // ""),
    "score: " + ((.score // 0) | tostring),
    "schema_version: " + ((.schema_version // 1) | tostring),
    "findings_summary:",
    "  critical: " + (((.stats // {}).by_severity.critical // 0) | tostring),
    "  high: "     + (((.stats // {}).by_severity.high     // 0) | tostring),
    "  medium: "   + (((.stats // {}).by_severity.medium   // 0) | tostring),
    "  low: "      + (((.stats // {}).by_severity.low      // 0) | tostring),
    "  info: "     + (((.stats // {}).by_severity.info     // 0) | tostring),
    "---",
    ""
  ' "$json_path") || {
    rm -f "$md_tmp"
    echo "audit_run_persist: jq failed building frontmatter for $md_path" >&2
    return 1
  }

  {
    printf '%s\n' "$fm"
    cat "$body_file"
  } > "$md_tmp" || {
    rm -f "$md_tmp"
    echo "audit_run_persist: failed writing staged MD for $md_path" >&2
    return 1
  }

  mv "$md_tmp" "$md_path" || {
    rm -f "$md_tmp"
    echo "audit_run_persist: failed to move staged MD into place at $md_path" >&2
    return 1
  }

  _audit_apply_marker "$dim_dir"
  return 0
}

# ---------------------------------------------------------------------------
# audit_run_list <project_name> <dimension> [limit]
# Prints up to <limit> JSON paths sorted by ts ascending (oldest → newest).
# For dimension=launch-check, ALSO reads the legacy
# projects/<name>/launch-check/runs/*.json path so adopters' existing
# trend history is not orphaned.
# ---------------------------------------------------------------------------
audit_run_list() {
  local project_name="$1"
  local dimension="$2"
  local limit="${3:-10}"

  if [ -z "$project_name" ] || [ -z "$dimension" ]; then
    echo "audit_run_list: project_name and dimension required" >&2
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "audit_run_list: jq required" >&2
    return 2
  fi

  local dim_dir
  dim_dir=$(audit_resolve_dir "$project_name" "$dimension") || return $?

  local projects_dir
  if command -v portfolio_projects_dir >/dev/null 2>&1; then
    projects_dir=$(portfolio_projects_dir)
  else
    projects_dir="$(git rev-parse --show-toplevel 2>/dev/null)/projects"
  fi

  # Candidate runs dirs: canonical, plus legacy launch-check path.
  local candidates=("$dim_dir/runs")
  if [ "$dimension" = "launch-check" ]; then
    local legacy="$projects_dir/$project_name/launch-check/runs"
    [ -d "$legacy" ] && candidates+=("$legacy")
  fi

  # Build tab-separated <ts>\t<path>, sort by ts ascending, take last <limit>.
  {
    for d in "${candidates[@]}"; do
      [ -d "$d" ] || continue
      for f in "$d"/*.json; do
        [ -f "$f" ] || continue
        # Defensive: skip zero-byte / orphaned run files that may already
        # be sitting on disk from before apexyard#1063's fix (or any other
        # source of a truncated write). The ts-empty check below already
        # incidentally catches this (jq on an empty/unparseable file emits
        # nothing), but make the intent explicit rather than relying on
        # that side effect.
        [ -s "$f" ] || continue
        local ts
        ts=$(jq -r '.ts // ""' "$f" 2>/dev/null) || ts=""
        [ -n "$ts" ] || continue
        printf '%s\t%s\n' "$ts" "$f"
      done
    done
  } | sort | tail -n "$limit" | awk -F '\t' '{print $2}'
}

# ---------------------------------------------------------------------------
# audit_render_trend <project_name> <dimension> [window]
# Renders the trend section to stdout. Silent when <2 runs.
#
# For dimension=launch-check, dispatch to the existing render-trend.sh
# (preserves byte-equal output for the regression test). For everything
# else, render a generic findings-based trend (table + ASCII chart of
# the .score field).
# ---------------------------------------------------------------------------
audit_render_trend() {
  local project_name="$1"
  local dimension="$2"
  local window="${3:-5}"

  if [ -z "$project_name" ] || [ -z "$dimension" ]; then
    echo "audit_render_trend: project_name and dimension required" >&2
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "audit_render_trend: jq required" >&2
    return 2
  fi

  # Collect runs (ts-sorted ascending paths).
  local runs
  runs=$(audit_run_list "$project_name" "$dimension" "$window")
  local n
  n=$(printf '%s\n' "$runs" | grep -c . || true)
  if [ "${n:-0}" -lt 2 ]; then
    return 0
  fi

  # launch-check dispatches to the legacy renderer for byte-equal output
  # of the existing chart (mean of scores.* on Y-axis). render-trend.sh
  # takes a single dir argument, but audit_run_list above already merged
  # old + new paths — so stage the merged file set into a tmp dir before
  # invoking it. This preserves adopters' existing history on first
  # post-refactor run, no manual `mv` required.
  if [ "$dimension" = "launch-check" ] && [ -n "$_AUDIT_RENDER_TREND_SH" ]; then
    local staged
    staged=$(mktemp -d)
    while IFS= read -r f; do
      [ -f "$f" ] && cp "$f" "$staged/" 2>/dev/null
    done <<< "$runs"
    "$_AUDIT_RENDER_TREND_SH" "$staged" "$window"
    local rc=$?
    rm -rf "$staged"
    return $rc
  fi

  # Generic renderer: parallel arrays of date / score / verdict.
  local dates=() scores=() verdicts=()
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    local ts date verdict score
    ts=$(jq -r '.ts // ""' "$path")
    date=$(printf '%s' "$ts" | cut -c1-10)
    verdict=$(jq -r '.verdict // "?"' "$path")
    score=$(jq -r '(.score // 0) | tostring' "$path")
    dates+=("$date")
    scores+=("$score")
    verdicts+=("$verdict")
  done <<< "$runs"

  echo "## Trend (last ${#dates[@]} runs)"
  echo ""
  echo "| Date       | Score | Verdict     |"
  echo "|------------|-------|-------------|"
  local i
  for ((i=0; i<${#dates[@]}; i++)); do
    printf '| %-10s | %5s | %-11s |\n' \
      "${dates[$i]}" "${scores[$i]}" "${verdicts[$i]}"
  done
  echo ""

  # ASCII chart, same shape as render-trend.sh (5 rows, 6 col-width).
  local min max y_lo y_hi range rows
  min=$(printf '%s\n' "${scores[@]}" | sort -n | head -1)
  max=$(printf '%s\n' "${scores[@]}" | sort -n | tail -1)
  y_lo=$(( min - 5 )); [ "$y_lo" -lt 0 ] && y_lo=0
  y_hi=$(( max + 5 )); [ "$y_hi" -gt 100 ] && y_hi=100
  [ "$y_hi" -le "$y_lo" ] && y_hi=$(( y_lo + 10 ))
  rows=5
  range=$(( y_hi - y_lo ))
  [ "$range" -le 0 ] && range=10

  echo "Score trend:"
  echo ""
  local r j
  for ((r = rows - 1; r >= 0; r--)); do
    local level line
    level=$(( y_lo + (range * r) / (rows - 1) ))
    line=$(printf '%3d |' "$level")
    for j in "${!scores[@]}"; do
      local s row_for_s
      s="${scores[$j]}"
      row_for_s=$(( ((s - y_lo) * (rows - 1) + range / 2) / range ))
      if [ "$row_for_s" -eq "$r" ]; then
        line="${line}   ●  "
      else
        line="${line}      "
      fi
    done
    echo "$line"
  done
  local xaxis="    +"
  for _ in "${!scores[@]}"; do xaxis="${xaxis}------"; done
  echo "$xaxis"
  local labels="     "
  local d
  for d in "${dates[@]}"; do
    labels="${labels}$(printf '%s' "$d" | cut -c6-) "
  done
  echo "$labels"
}
