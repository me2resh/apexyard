#!/usr/bin/env bash
# /process lint.sh
#
# Run bpmnlint against a BPMN 2.0 file with the framework's default rules.
# Reads ${PROJECT_ROOT}/.bpmnlintrc when present to allow per-project overrides.
#
# Usage:
#   lint.sh <output.bpmn> [--project-root=<dir>] [--max-warnings=0]
#
# Exit codes:
#   0 — clean (no errors, no warnings above --max-warnings)
#   1 — violations exist (run interactively to see them)
#   2 — bad input
#   3 — bpmnlint / npx not available (Node missing)

set -euo pipefail

FILE=""
PROJECT_ROOT=""
MAX_WARNINGS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project-root=*) PROJECT_ROOT="${1#--project-root=}"; shift ;;
    --max-warnings=*) MAX_WARNINGS="${1#--max-warnings=}"; shift ;;
    --help|-h)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    -*)
      echo "lint.sh: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [ -z "$FILE" ]; then
        FILE="$1"
      else
        echo "lint.sh: unexpected positional arg: $1" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [ -z "$FILE" ]; then
  echo "lint.sh: BPMN file path is required" >&2
  exit 2
fi
if [ ! -f "$FILE" ]; then
  echo "lint.sh: file not found: $FILE" >&2
  exit 2
fi

if ! command -v npx >/dev/null 2>&1; then
  cat >&2 <<MSG
lint.sh: npx not found — bpmnlint cannot run.

  Install Node + npm (https://nodejs.org), then re-run /process.
  To skip the lint gate, pass --skip-lint to the parent skill (the operator
  owns the consequences — a non-lint-clean BPMN may render badly in
  Camunda Modeler).
MSG
  exit 3
fi

# ---------------------------------------------------------------------------
# Resolve the .bpmnlintrc to use.
#   1. Use ${PROJECT_ROOT}/.bpmnlintrc if it exists.
#   2. Else write a tempfile with framework defaults and use that.
# ---------------------------------------------------------------------------
WORK=$(mktemp -d -t process-lint-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

RC="$WORK/.bpmnlintrc"
if [ -n "$PROJECT_ROOT" ] && [ -f "$PROJECT_ROOT/.bpmnlintrc" ]; then
  cp "$PROJECT_ROOT/.bpmnlintrc" "$RC"
else
  cat > "$RC" <<'JSON'
{
  "extends": "bpmnlint:recommended",
  "rules": {
    "label-required": "error",
    "no-disconnected": "error",
    "no-implicit-split": "warn"
  }
}
JSON
fi

# Run bpmnlint. Cache the npx package via -y so prompts are skipped.
# bpmnlint exits 0 on clean, 1 on violations, other on internal errors.
set +e
npx -y bpmnlint --config "$RC" "$FILE" > "$WORK/out.txt" 2>&1
RC_EXIT=$?
set -e

# Always print bpmnlint's output (whether it found issues or not).
cat "$WORK/out.txt"

if [ "$RC_EXIT" -eq 0 ]; then
  echo "lint.sh: bpmnlint clean"
  exit 0
fi

# Count warnings vs errors (bpmnlint's default summary format).
ERRORS=$(grep -cE '^\s*[0-9]+:[0-9]+\s+error' "$WORK/out.txt" 2>/dev/null || echo 0)
WARNS=$(grep -cE '^\s*[0-9]+:[0-9]+\s+warning' "$WORK/out.txt" 2>/dev/null || echo 0)

if [ "$ERRORS" -gt 0 ]; then
  echo "lint.sh: $ERRORS error(s), $WARNS warning(s) — fix or re-run /process with the auto-fix/re-interview/accept loop" >&2
  exit 1
fi

if [ "$WARNS" -gt "$MAX_WARNINGS" ]; then
  echo "lint.sh: $WARNS warning(s) exceeds --max-warnings=$MAX_WARNINGS — tighten or raise the threshold via .bpmnlintrc" >&2
  exit 1
fi

echo "lint.sh: bpmnlint clean (warnings within threshold)"
exit 0
