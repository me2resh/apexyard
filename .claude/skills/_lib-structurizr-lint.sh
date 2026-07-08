#!/usr/bin/env bash
# _lib-structurizr-lint.sh
#
# Validate a Structurizr DSL workspace file (the /c4 --dsl escape hatch
# output). Unlike _lib-mermaid-lint.sh, this lib does NOT shell out to a
# new runtime dependency by default — the design goal of the Structurizr
# escape hatch (AgDR-0085) is a dependency-free text artifact, so the
# default check is a STRUCTURAL lint: no Java, no Docker, no npx.
#
# Structural checks (always run):
#   1. File is non-empty
#   2. A top-level `workspace` block exists
#   3. Braces are balanced (never goes negative scanning forward, and
#      the total open/close count matches) — comments stripped first
#   4. A `model { ... }` block exists inside the workspace
#   5. A `views { ... }` block exists inside the workspace
#   6. No duplicate identifier assignments
#      (`<id> = person|softwareSystem|container|component|deploymentEnvironment ...`)
#
# This is intentionally NOT a full DSL parser — it catches the mistakes
# most likely from hand-editing a generated file (unbalanced braces,
# copy-pasted identifiers, a missing model/views block), not every
# Structurizr language rule.
#
# Optional full-parser mode: if `structurizr-cli` is on PATH (adopter
# installed it separately — Java required), this lib ALSO runs
# `structurizr-cli export -format json` against the file as a real parse
# check. A Java/runtime-missing failure from structurizr-cli degrades
# back to the structural-only result (never hard-fails on a missing
# optional tool); an actual parse error from a present structurizr-cli
# DOES fail the lint (exit 1) — real signal, not a graceful degrade.
#
# Usage:
#   _lib-structurizr-lint.sh <file.dsl> [--skip-lint]
#
# Exit codes:
#   0 — structural (and, if available, full) validation passed, OR
#       --skip-lint was passed
#   1 — one or more checks failed (details on stderr)
#   2 — bad input (file missing, unknown flag)
#
# Per-skill wrapper: .claude/skills/c4/lint-dsl.sh

set -uo pipefail

FILE=""
SKIP_LINT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-lint)
      SKIP_LINT=1
      shift
      ;;
    --help|-h)
      sed -n '2,45p' "$0"
      exit 0
      ;;
    -*)
      echo "_lib-structurizr-lint.sh: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [ -z "$FILE" ]; then
        FILE="$1"
      else
        echo "_lib-structurizr-lint.sh: unexpected positional arg: $1" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [ "$SKIP_LINT" = "1" ]; then
  echo "_lib-structurizr-lint.sh: --skip-lint set, exit 0"
  exit 0
fi

if [ -z "$FILE" ]; then
  echo "_lib-structurizr-lint.sh: DSL file path is required" >&2
  exit 2
fi

if [ ! -f "$FILE" ]; then
  echo "_lib-structurizr-lint.sh: file not found: $FILE" >&2
  exit 2
fi

if [ ! -s "$FILE" ]; then
  echo "_lib-structurizr-lint.sh: file is empty: $FILE" >&2
  exit 1
fi

WORK=$(mktemp -d -t structurizr-lint-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Strip `//` line comments before structural analysis so a brace mentioned
# in a comment doesn't skew the balance count.
STRIPPED="$WORK/stripped.dsl"
sed -E 's#//.*$##' "$FILE" > "$STRIPPED"

FAILED=0
ERRORS="$WORK/errors.log"
: > "$ERRORS"

# --- 1. Top-level `workspace` block ------------------------------------
if ! grep -qE '^[[:space:]]*workspace([[:space:]]|\{)' "$STRIPPED"; then
  echo "missing top-level 'workspace' block" >> "$ERRORS"
  FAILED=$((FAILED + 1))
fi

# --- 2. Balanced braces --------------------------------------------------
# awk scans char-by-char, tracking depth. Depth must never go negative
# (stray '}') and must return to exactly 0 at EOF (unclosed '{').
BRACE_RESULT=$(awk '
  {
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c == "{") depth++
      else if (c == "}") {
        depth--
        if (depth < 0) { print "negative"; went_negative = 1; exit }
      }
    }
  }
  END {
    if (went_negative) exit
    if (depth != 0) print "unbalanced:" depth; else print "ok"
  }
' "$STRIPPED")

case "$BRACE_RESULT" in
  ok) : ;;
  negative)
    echo "unbalanced braces — a closing '}' appears with no matching '{'" >> "$ERRORS"
    FAILED=$((FAILED + 1))
    ;;
  unbalanced:*)
    delta="${BRACE_RESULT#unbalanced:}"
    echo "unbalanced braces — $delta unclosed '{' block(s) at end of file" >> "$ERRORS"
    FAILED=$((FAILED + 1))
    ;;
esac

# --- 3. `model { ... }` block exists -------------------------------------
if ! grep -qE '^[[:space:]]*model[[:space:]]*\{' "$STRIPPED"; then
  echo "missing 'model { ... }' block" >> "$ERRORS"
  FAILED=$((FAILED + 1))
fi

# --- 4. `views { ... }` block exists -------------------------------------
if ! grep -qE '^[[:space:]]*views[[:space:]]*\{' "$STRIPPED"; then
  echo "missing 'views { ... }' block" >> "$ERRORS"
  FAILED=$((FAILED + 1))
fi

# --- 5. No duplicate identifier assignments ------------------------------
# Matches lines like: `api = softwareSystem "API" "..."` or
# `authController = component "Auth Controller" ...`.
DUPES=$(grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*(person|softwareSystem|container|component|deploymentEnvironment|deploymentNode|infrastructureNode|softwareSystemInstance|containerInstance)\b' "$STRIPPED" \
  | sed -E 's/^[[:space:]]*//; s/[[:space:]]*=.*$//' \
  | sort | uniq -d)

if [ -n "$DUPES" ]; then
  echo "duplicate identifier assignment(s):" >> "$ERRORS"
  echo "$DUPES" | sed 's/^/  - /' >> "$ERRORS"
  FAILED=$((FAILED + 1))
fi

if [ "$FAILED" -gt 0 ]; then
  echo "_lib-structurizr-lint.sh: structural check FAILED for $FILE:" >&2
  cat "$ERRORS" >&2
  exit 1
fi

echo "_lib-structurizr-lint.sh: structural check OK (workspace/model/views present, braces balanced, no duplicate ids)"

# --- Optional: real parse via structurizr-cli, if the adopter has it ----
if command -v structurizr-cli >/dev/null 2>&1; then
  CLI_LOG="$WORK/cli.log"
  if structurizr-cli export -workspace "$FILE" -format json -output "$WORK" > "$CLI_LOG" 2>&1; then
    echo "_lib-structurizr-lint.sh: structurizr-cli parsed the workspace cleanly (full validation)"
  else
    if grep -qiE 'command not found|no java|unable to locate|JAVA_HOME|is not recognized' "$CLI_LOG"; then
      echo "_lib-structurizr-lint.sh: structurizr-cli present but its Java runtime is unavailable — structural check stands, full parse skipped" >&2
    else
      echo "_lib-structurizr-lint.sh: structurizr-cli found a parse error:" >&2
      cat "$CLI_LOG" >&2
      exit 1
    fi
  fi
else
  echo "_lib-structurizr-lint.sh: structurizr-cli not on PATH — structural-only check ran (this is expected; no runtime dependency required). Install structurizr-cli for a full parse, or render at https://structurizr.com/dsl to validate visually."
fi

exit 0
