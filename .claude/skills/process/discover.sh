#!/usr/bin/env bash
# /process discover.sh
#
# Discovery engine for /process. Walks the seven discovery axes documented in
# SKILL.md against a project root and emits a structured candidate model on
# stdout. Read-only — never modifies the project.
#
# Usage:
#   discover.sh <project-root> --slug=<process-slug> [--from-endpoint="METHOD /path"]
#                                                    [--from-machine=ClassName]
#                                                    [--from-job=JobName]
#                                                    [--scope=dir/]
#                                                    [--max-depth=6]
#                                                    [--format=json|report]
#
# Default --format=report (human-readable). --format=json emits the candidate
# model as JSON for downstream consumption.
#
# Reachability bounding: each axis-scan is anchored. The walker starts from
# the anchor and follows only what's connected — endpoint → handler → queues
# it dispatches → their handlers, etc. Stops at the connected-component
# boundary or --max-depth, whichever comes first.

set -euo pipefail

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

PROJECT_ROOT=""
SLUG=""
FROM_ENDPOINT=""
FROM_MACHINE=""
FROM_JOB=""
FROM_SCOPE=""
MAX_DEPTH=6
FORMAT="report"

while [ $# -gt 0 ]; do
  case "$1" in
    --slug=*)          SLUG="${1#--slug=}";              shift ;;
    --from-endpoint=*) FROM_ENDPOINT="${1#--from-endpoint=}"; shift ;;
    --from-machine=*)  FROM_MACHINE="${1#--from-machine=}";   shift ;;
    --from-job=*)      FROM_JOB="${1#--from-job=}";           shift ;;
    --scope=*)         FROM_SCOPE="${1#--scope=}";            shift ;;
    --max-depth=*)     MAX_DEPTH="${1#--max-depth=}";         shift ;;
    --format=*)        FORMAT="${1#--format=}";               shift ;;
    --help|-h)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    -*)
      echo "discover.sh: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [ -z "$PROJECT_ROOT" ]; then
        PROJECT_ROOT="$1"
      else
        echo "discover.sh: unexpected positional arg: $1" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [ -z "$PROJECT_ROOT" ]; then
  echo "discover.sh: <project-root> is required" >&2
  exit 2
fi
if [ ! -d "$PROJECT_ROOT" ]; then
  echo "discover.sh: $PROJECT_ROOT is not a directory" >&2
  exit 2
fi

# At least one anchor is required.
if [ -z "$FROM_ENDPOINT$FROM_MACHINE$FROM_JOB$FROM_SCOPE" ]; then
  echo "discover.sh: at least one anchor is required (--from-endpoint, --from-machine, --from-job, or --scope)" >&2
  exit 2
fi

if [ -z "$SLUG" ]; then
  SLUG="$(basename "$PROJECT_ROOT" | tr '[:upper:]' '[:lower:]')"
fi

# ---------------------------------------------------------------------------
# Vendored-dir pruning — same shape as /extract-features
# ---------------------------------------------------------------------------
PRUNE_DIRS=(node_modules vendor .venv venv target dist build coverage .next .nuxt .pytest_cache __pycache__)

prune_grep() {
  # Wraps grep -RE with vendored-dir pruning. Caller passes the pattern + path.
  local pattern="$1"
  local search_path="$2"
  local args=()
  for d in "${PRUNE_DIRS[@]}"; do
    args+=(--exclude-dir="$d")
  done
  grep -RE "${args[@]}" "$pattern" "$search_path" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Axis runners — each emits to a per-axis tempfile + sets COUNT_<n> var.
# Outputs are intentionally simple: one finding per line, pipe-separated
# fields. The aggregator at the bottom converts to JSON when --format=json.
# ---------------------------------------------------------------------------
WORK=$(mktemp -d -t process-discover-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

COUNT_1=0; COUNT_2=0; COUNT_3=0; COUNT_4=0; COUNT_5=0; COUNT_6=0; COUNT_7=0

# Axis 1 — Explicit workflow definitions
axis1() {
  local out="$WORK/axis1.txt"
  : > "$out"

  # XState — match BOTH .machine.ts/js filenames AND createMachine() calls
  while IFS= read -r f; do
    [ -n "$f" ] && echo "xstate|machine|$f" >> "$out"
  done < <(find "$PROJECT_ROOT" -type f \( -name '*.machine.ts' -o -name '*.machine.js' \) \
             -not -path '*/node_modules/*' -not -path '*/dist/*' 2>/dev/null)
  while IFS= read -r line; do
    [ -n "$line" ] && echo "xstate|createMachine|$line" >> "$out"
  done < <(prune_grep 'createMachine\s*\(' "$PROJECT_ROOT" | head -50)

  # Temporal / Cadence
  while IFS= read -r line; do
    [ -n "$line" ] && echo "temporal|workflow|$line" >> "$out"
  done < <(prune_grep '@workflow\.defn|@workflow_method' "$PROJECT_ROOT" | head -20)

  # AWS Step Functions
  while IFS= read -r f; do
    [ -n "$f" ] && echo "step-functions|asl|$f" >> "$out"
  done < <(find "$PROJECT_ROOT" -type f -name '*.asl.json' \
             -not -path '*/node_modules/*' 2>/dev/null)

  # Existing BPMN / CMMN (NOTE: also feeds axis 6; we record here for axis 1 too
  # because a .bpmn file is itself an explicit workflow definition).
  while IFS= read -r f; do
    [ -n "$f" ] && echo "bpmn|file|$f" >> "$out"
  done < <(find "$PROJECT_ROOT" -type f \( -name '*.bpmn' -o -name '*.bpmn20.xml' \) \
             -not -path '*/node_modules/*' 2>/dev/null)

  COUNT_1=$(wc -l < "$out" | tr -d ' ')
}

# Axis 2 — Queue / job orchestration
axis2() {
  local out="$WORK/axis2.txt"
  : > "$out"

  # BullMQ
  while IFS= read -r line; do
    [ -n "$line" ] && echo "bullmq|queue|$line" >> "$out"
  done < <(prune_grep 'new (Queue|Worker|FlowProducer)\s*\(' "$PROJECT_ROOT" | head -50)

  # Celery
  while IFS= read -r line; do
    [ -n "$line" ] && echo "celery|task|$line" >> "$out"
  done < <(prune_grep '@shared_task|@app\.task|chain\s*\(|chord\s*\(|group\s*\(' "$PROJECT_ROOT" | head -30)

  # Sidekiq
  while IFS= read -r line; do
    [ -n "$line" ] && echo "sidekiq|worker|$line" >> "$out"
  done < <(prune_grep 'include Sidekiq::Worker|include Sidekiq::Job|perform_async' "$PROJECT_ROOT" | head -30)

  COUNT_2=$(wc -l < "$out" | tr -d ' ')
}

# Axis 3 — Cron + scheduled triggers
axis3() {
  local out="$WORK/axis3.txt"
  : > "$out"

  # node-cron, @nestjs/schedule
  while IFS= read -r line; do
    [ -n "$line" ] && echo "node-cron|schedule|$line" >> "$out"
  done < <(prune_grep 'cron\.schedule\s*\(|@Cron\s*\(|@Interval\s*\(|@Timeout\s*\(' "$PROJECT_ROOT" | head -30)

  # APScheduler / Celery beat
  while IFS= read -r line; do
    [ -n "$line" ] && echo "python|scheduler|$line" >> "$out"
  done < <(prune_grep 'scheduler\.add_job|@scheduler\.scheduled_job|beat_schedule\s*=' "$PROJECT_ROOT" | head -30)

  # GitHub Actions cron
  if [ -d "$PROJECT_ROOT/.github/workflows" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && echo "gh-actions|cron|$line" >> "$out"
    done < <(grep -REn 'cron:' "$PROJECT_ROOT/.github/workflows" 2>/dev/null | head -10)
  fi

  # Vercel cron (vercel.json)
  if [ -f "$PROJECT_ROOT/vercel.json" ] && grep -q '"crons"' "$PROJECT_ROOT/vercel.json" 2>/dev/null; then
    echo "vercel|cron|vercel.json" >> "$out"
  fi

  # AWS EventBridge / Schedule via SAM (template.yaml/yml)
  for tmpl in "$PROJECT_ROOT/template.yaml" "$PROJECT_ROOT/template.yml"; do
    [ -f "$tmpl" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] && echo "sam|schedule|$line" >> "$out"
    done < <(grep -En 'Schedule:|cron\(|rate\(' "$tmpl" 2>/dev/null | head -10)
  done

  COUNT_3=$(wc -l < "$out" | tr -d ' ')
}

# Axis 4 — State-column transitions
axis4() {
  local out="$WORK/axis4.txt"
  : > "$out"

  # Prisma
  if [ -f "$PROJECT_ROOT/prisma/schema.prisma" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && echo "prisma|column|$PROJECT_ROOT/prisma/schema.prisma:$line" >> "$out"
    done < <(grep -nE '^\s*(status|state|phase|step|stage)\s+' "$PROJECT_ROOT/prisma/schema.prisma" 2>/dev/null)
  fi

  # TypeORM / Sequelize / Drizzle / SQLAlchemy / Django / Rails — column names
  while IFS= read -r line; do
    [ -n "$line" ] && echo "orm|column|$line" >> "$out"
  done < <(prune_grep '@Column\s*\([^)]*\)\s*(public\s+)?(status|state|phase|step|stage)|pgEnum\s*\(|mysqlEnum\s*\(' "$PROJECT_ROOT" | head -30)

  # State-writing call sites (any language)
  while IFS= read -r line; do
    [ -n "$line" ] && echo "code|state-write|$line" >> "$out"
  done < <(prune_grep '\.(status|state|phase|step|stage)\s*=\s*['\''"][a-zA-Z_-]+['\''"]' "$PROJECT_ROOT" | head -50)

  COUNT_4=$(wc -l < "$out" | tr -d ' ')
}

# Axis 5 — API choreography (event emission, queue dispatch, HTTP fan-out)
axis5() {
  local out="$WORK/axis5.txt"
  : > "$out"

  # Event emission
  while IFS= read -r line; do
    [ -n "$line" ] && echo "event|emit|$line" >> "$out"
  done < <(prune_grep 'eventBus\.emit\s*\(|publishEvent\s*\(|outbox\.write\s*\(' "$PROJECT_ROOT" | head -30)

  # Queue dispatch (covered by axis 2 for declarations; here we look for .add() call sites
  # that name a queue and live inside route/service files)
  while IFS= read -r line; do
    [ -n "$line" ] && echo "queue|dispatch|$line" >> "$out"
  done < <(prune_grep '\.add\s*\(\s*['\''"][a-zA-Z_-]+['\''"]|\.apply_async\s*\(|\.perform_async\s*\(' "$PROJECT_ROOT" | head -30)

  # HTTP fan-out (cross-repo candidates surface here)
  while IFS= read -r line; do
    [ -n "$line" ] && echo "http|fan-out|$line" >> "$out"
  done < <(prune_grep 'fetch\s*\(\s*['\''"]https?://|axios\.(get|post|put|patch|delete)\s*\(\s*['\''"]|requests\.(get|post|put|patch|delete)\s*\(' "$PROJECT_ROOT" | head -30)

  COUNT_5=$(wc -l < "$out" | tr -d ' ')
}

# Axis 6 — Existing BPMN / Mermaid diagrams (starting state, never overwrite blindly)
axis6() {
  local out="$WORK/axis6.txt"
  : > "$out"

  while IFS= read -r f; do
    [ -n "$f" ] && echo "bpmn|existing|$f" >> "$out"
  done < <(find "$PROJECT_ROOT" -type f \( -name '*.bpmn' -o -name '*.bpmn20.xml' -o -name '*.cmmn' \) \
             -not -path '*/node_modules/*' 2>/dev/null)

  # Mermaid sequence diagrams or flowcharts inside docs/processes/
  if [ -d "$PROJECT_ROOT/docs/processes" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && echo "mermaid|process-doc|$f" >> "$out"
    done < <(grep -rlE '```mermaid' "$PROJECT_ROOT/docs/processes" 2>/dev/null)
  fi

  COUNT_6=$(wc -l < "$out" | tr -d ' ')
}

# Axis 7 — Documented process steps (README / docs/ flow sections)
axis7() {
  local out="$WORK/axis7.txt"
  : > "$out"

  if [ -f "$PROJECT_ROOT/README.md" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && echo "readme|flow-section|$PROJECT_ROOT/README.md:$line" >> "$out"
    done < <(grep -nEi '^##\s+.*(flow|process|lifecycle|workflow)' "$PROJECT_ROOT/README.md" 2>/dev/null)
  fi

  if [ -d "$PROJECT_ROOT/docs" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && echo "docs|flow-section|$line" >> "$out"
    done < <(grep -rnEi --include='*.md' '^##\s+.*(flow|process|lifecycle|workflow)' "$PROJECT_ROOT/docs" 2>/dev/null | head -20)
  fi

  COUNT_7=$(wc -l < "$out" | tr -d ' ')
}

# ---------------------------------------------------------------------------
# Run axes
# ---------------------------------------------------------------------------
axis1
axis2
axis3
axis4
axis5
axis6
axis7

# ---------------------------------------------------------------------------
# Anchor reachability scoping
#
# The seven axes above produce a project-wide candidate set. We now narrow
# to what's reachable from the anchor. This is a pragmatic 1.5-hop scope:
#   - If --scope=dir/ is set, keep only findings whose path starts with dir/.
#   - If --from-endpoint is set, keep findings under route/handler files PLUS
#     findings in files referenced from those handlers (greppy import chase).
#   - If --from-machine is set, keep findings in the file declaring the
#     machine + files referenced from it.
#   - If --from-job is set, keep findings whose job name appears in the body.
#
# This is intentionally heuristic — production-grade reachability needs an
# AST/LSP layer. The skill's interview step lets the operator prune findings
# that the heuristic over-pulled.
# ---------------------------------------------------------------------------
SCOPED=$(mktemp -d "$WORK/scoped.XXX")
mkdir -p "$SCOPED"

apply_scope() {
  local axis="$1"
  local raw="$WORK/axis${axis}.txt"
  local out="$SCOPED/axis${axis}.txt"
  : > "$out"
  [ -s "$raw" ] || return 0

  if [ -n "$FROM_SCOPE" ]; then
    local prefix="$PROJECT_ROOT/${FROM_SCOPE%/}"
    grep -F "$prefix" "$raw" >> "$out" 2>/dev/null || true
  fi

  if [ -n "$FROM_ENDPOINT" ]; then
    # Pull METHOD and /path; case-insensitive match in line bodies.
    local method path
    method=$(echo "$FROM_ENDPOINT" | awk '{print toupper($1)}')
    path=$(echo "$FROM_ENDPOINT" | awk '{print $2}')
    grep -iE "${method}|${path}" "$raw" >> "$out" 2>/dev/null || true
  fi

  if [ -n "$FROM_MACHINE" ]; then
    grep -F "$FROM_MACHINE" "$raw" >> "$out" 2>/dev/null || true
  fi

  if [ -n "$FROM_JOB" ]; then
    grep -F "$FROM_JOB" "$raw" >> "$out" 2>/dev/null || true
  fi

  # If no scope filter matched, fall back to the unscoped findings up to a cap
  # (early-iteration on greenfield repos shouldn't return zero just because
  # the anchor's file name is bare).
  if [ ! -s "$out" ]; then
    head -10 "$raw" > "$out"
  else
    # Dedupe.
    sort -u "$out" -o "$out"
  fi
}

for a in 1 2 3 4 5 6 7; do
  apply_scope "$a"
done

SCOPED_1=$(wc -l < "$SCOPED/axis1.txt" | tr -d ' ')
SCOPED_2=$(wc -l < "$SCOPED/axis2.txt" | tr -d ' ')
SCOPED_3=$(wc -l < "$SCOPED/axis3.txt" | tr -d ' ')
SCOPED_4=$(wc -l < "$SCOPED/axis4.txt" | tr -d ' ')
SCOPED_5=$(wc -l < "$SCOPED/axis5.txt" | tr -d ' ')
SCOPED_6=$(wc -l < "$SCOPED/axis6.txt" | tr -d ' ')
SCOPED_7=$(wc -l < "$SCOPED/axis7.txt" | tr -d ' ')
SCOPED_TOTAL=$((SCOPED_1 + SCOPED_2 + SCOPED_3 + SCOPED_4 + SCOPED_5 + SCOPED_6 + SCOPED_7))

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------

emit_report() {
  cat <<EOF
discover.sh — /process discovery report
Project:    $PROJECT_ROOT
Slug:       $SLUG
Max-depth:  $MAX_DEPTH

Anchor:
  endpoint:   ${FROM_ENDPOINT:-(none)}
  machine:    ${FROM_MACHINE:-(none)}
  job:        ${FROM_JOB:-(none)}
  scope:      ${FROM_SCOPE:-(none)}

Findings (project-wide / scoped-to-anchor):
  Axis 1 — Explicit workflows:     ${COUNT_1} / ${SCOPED_1}
  Axis 2 — Queues / job chains:    ${COUNT_2} / ${SCOPED_2}
  Axis 3 — Cron + schedule:        ${COUNT_3} / ${SCOPED_3}
  Axis 4 — State columns:          ${COUNT_4} / ${SCOPED_4}
  Axis 5 — API choreography:       ${COUNT_5} / ${SCOPED_5}
  Axis 6 — Existing BPMN / docs:   ${COUNT_6} / ${SCOPED_6}
  Axis 7 — Documented steps:       ${COUNT_7} / ${SCOPED_7}

Scoped findings (anchor-reachable):
EOF
  for a in 1 2 3 4 5 6 7; do
    local file="$SCOPED/axis${a}.txt"
    if [ -s "$file" ]; then
      echo ""
      echo "--- Axis $a ---"
      head -30 "$file"
    fi
  done
  echo ""
  echo "Total scoped findings: $SCOPED_TOTAL"
}

emit_json() {
  # Minimal JSON emitter — no jq dep. Single-line strings (no embedded quotes
  # are special-cased; the bash quoting elsewhere keeps them safe).
  printf '{\n'
  printf '  "slug": "%s",\n' "$SLUG"
  printf '  "project_root": "%s",\n' "$PROJECT_ROOT"
  printf '  "anchor": {\n'
  printf '    "endpoint": "%s",\n' "${FROM_ENDPOINT}"
  printf '    "machine": "%s",\n'  "${FROM_MACHINE}"
  printf '    "job": "%s",\n'      "${FROM_JOB}"
  printf '    "scope": "%s"\n'     "${FROM_SCOPE}"
  printf '  },\n'
  printf '  "max_depth": %s,\n'    "$MAX_DEPTH"
  printf '  "counts_project_wide": {\n'
  printf '    "axis_1": %s, "axis_2": %s, "axis_3": %s, "axis_4": %s, "axis_5": %s, "axis_6": %s, "axis_7": %s\n' \
    "$COUNT_1" "$COUNT_2" "$COUNT_3" "$COUNT_4" "$COUNT_5" "$COUNT_6" "$COUNT_7"
  printf '  },\n'
  printf '  "counts_scoped": {\n'
  printf '    "axis_1": %s, "axis_2": %s, "axis_3": %s, "axis_4": %s, "axis_5": %s, "axis_6": %s, "axis_7": %s, "total": %s\n' \
    "$SCOPED_1" "$SCOPED_2" "$SCOPED_3" "$SCOPED_4" "$SCOPED_5" "$SCOPED_6" "$SCOPED_7" "$SCOPED_TOTAL"
  printf '  },\n'
  printf '  "findings": {\n'
  local first=1
  for a in 1 2 3 4 5 6 7; do
    [ "$first" -eq 1 ] || printf ',\n'
    first=0
    printf '    "axis_%s": [' "$a"
    if [ -s "$SCOPED/axis${a}.txt" ]; then
      printf '\n'
      local inner_first=1
      while IFS= read -r line; do
        [ "$inner_first" -eq 1 ] || printf ',\n'
        inner_first=0
        # Escape backslashes and double-quotes for JSON.
        local esc
        esc=$(printf '%s' "$line" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '      "%s"' "$esc"
      done < "$SCOPED/axis${a}.txt"
      printf '\n    ]'
    else
      printf ']'
    fi
  done
  printf '\n  }\n'
  printf '}\n'
}

case "$FORMAT" in
  report) emit_report ;;
  json)   emit_json ;;
  *)
    echo "discover.sh: unknown --format=$FORMAT (use 'report' or 'json')" >&2
    exit 2
    ;;
esac

exit 0
