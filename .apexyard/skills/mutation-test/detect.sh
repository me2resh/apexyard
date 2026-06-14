#!/usr/bin/env bash
# /mutation-test detect.sh — language detection + runner-availability check.
#
# Two responsibilities, shared between the full skill invocation and the
# --check-only mode:
#
#   1. detect_language <project-dir>
#        Echoes one of: ts, js, python, go, ruby, unknown
#        Decision: file-count heuristic across the project tree, excluding
#        node_modules / .venv / vendor / dist / build / .next.
#        TS files contribute to "ts" (a TS-dominant project that also has
#        sibling .js files reports "ts"); pure-JS reports "js".
#
#   2. check_runner <runner-name>
#        Returns 0 if the runner is on PATH, 3 if not.
#        Recognised runners: stryker, mutpy, go-mutesting, mutant.
#
# Also exposes print_install_advisory to keep the install one-liners in
# one place (consumed by both detect.sh in --check-only and SKILL.md
# Step 4 in the full flow).
#
# Usage:
#   detect.sh --detect <project-dir>
#   detect.sh --check <runner-name>
#   detect.sh --check-only [<project-dir>]
#   detect.sh --advisory
#
# Exit codes:
#   0 — happy path (detection succeeded, runner present, advisory printed)
#   2 — bad input / unsupported flag
#   3 — no runner installed (graceful-degrade signal)

set -uo pipefail

# ---------------------------------------------------------------------------
# detect_language <project-dir>
# ---------------------------------------------------------------------------
detect_language() {
  local dir="${1:-$PWD}"
  if [ ! -d "$dir" ]; then
    echo "detect.sh: project dir not found: $dir" >&2
    return 2
  fi

  # Excludes match the well-known build / vendor dirs. Keeping the prune
  # list short and explicit is more predictable than a chained -prune that
  # tries to capture every framework's cache dir.
  local prune='-not -path */node_modules/* -not -path */.venv/* -not -path */vendor/* -not -path */dist/* -not -path */build/* -not -path */.next/* -not -path */__pycache__/* -not -path */.git/*'

  local ts_count js_count py_count go_count rb_count
  # shellcheck disable=SC2086
  ts_count=$(find "$dir" -type f \( -name '*.ts' -o -name '*.tsx' \) $prune 2>/dev/null | wc -l | tr -d ' ')
  # shellcheck disable=SC2086
  js_count=$(find "$dir" -type f \( -name '*.js' -o -name '*.jsx' -o -name '*.mjs' \) $prune 2>/dev/null | wc -l | tr -d ' ')
  # shellcheck disable=SC2086
  py_count=$(find "$dir" -type f -name '*.py' $prune 2>/dev/null | wc -l | tr -d ' ')
  # shellcheck disable=SC2086
  go_count=$(find "$dir" -type f -name '*.go' $prune 2>/dev/null | wc -l | tr -d ' ')
  # shellcheck disable=SC2086
  rb_count=$(find "$dir" -type f -name '*.rb' $prune 2>/dev/null | wc -l | tr -d ' ')

  # Pick the language with the highest count. TS wins over JS when both
  # are present; otherwise prefer the larger.
  local max=0 winner="unknown"
  if [ "$ts_count" -gt "$max" ]; then max="$ts_count"; winner="ts"; fi
  if [ "$js_count" -gt "$max" ]; then max="$js_count"; winner="js"; fi
  if [ "$py_count" -gt "$max" ]; then max="$py_count"; winner="python"; fi
  if [ "$go_count" -gt "$max" ]; then max="$go_count"; winner="go"; fi
  if [ "$rb_count" -gt "$max" ]; then max="$rb_count"; winner="ruby"; fi

  # If TS and JS coexist and TS has any files, prefer TS even when JS
  # numerically dominates (a TS project with compiled JS in src/ shouldn't
  # report js). The check is "TS present" not "TS dominant".
  if [ "$winner" = "js" ] && [ "$ts_count" -gt 0 ]; then
    winner="ts"
  fi

  if [ "$max" -eq 0 ]; then
    echo "unknown"
    return 0
  fi

  echo "$winner"
}

# ---------------------------------------------------------------------------
# check_runner <runner-name>
# ---------------------------------------------------------------------------
check_runner() {
  local runner="${1:-}"
  case "$runner" in
    stryker)
      if command -v stryker >/dev/null 2>&1; then return 0; fi
      # Stryker is commonly run via npx, so accept npx + a local install.
      if command -v npx >/dev/null 2>&1 && [ -f "node_modules/.bin/stryker" ]; then return 0; fi
      return 3
      ;;
    mutpy)
      command -v mut.py >/dev/null 2>&1 && return 0
      return 3
      ;;
    go-mutesting)
      command -v go-mutesting >/dev/null 2>&1 && return 0
      return 3
      ;;
    mutant)
      command -v mutant >/dev/null 2>&1 && return 0
      return 3
      ;;
    "")
      echo "detect.sh: --check requires a runner name (stryker|mutpy|go-mutesting|mutant)" >&2
      return 2
      ;;
    *)
      echo "detect.sh: unknown runner: $runner (recognised: stryker, mutpy, go-mutesting, mutant)" >&2
      return 2
      ;;
  esac
}

# ---------------------------------------------------------------------------
# print_install_advisory
# ---------------------------------------------------------------------------
print_install_advisory() {
  cat >&2 <<'MSG'
✗ No mutation tester installed.

Per-language install one-liners:
  TS / JS  — npm install --save-dev @stryker-mutator/core
              (then add stryker.conf.json — see https://stryker-mutator.io/docs/stryker-js/)
  Python   — pip install mutpy
              (https://github.com/mutpy/mutpy)
  Go       — go install github.com/zimmski/go-mutesting/cmd/go-mutesting@latest
              (https://github.com/zimmski/go-mutesting)
  Ruby     — gem install mutant-rspec   (or mutant-minitest)
              (https://github.com/mbj/mutant)

Install the runner for your project's language and re-run /mutation-test.
This skill never bundles a mutation runner — same graceful-degrade shape
as /pdf and /process.
MSG
}

# ---------------------------------------------------------------------------
# CLI dispatch (when invoked directly, not sourced)
# ---------------------------------------------------------------------------
# Sourced-mode detection: when BASH_SOURCE differs from $0 (or the test
# explicitly sources this file), skip the CLI dispatch and just expose
# the functions.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-}" in
    --detect)
      shift
      detect_language "${1:-$PWD}"
      ;;
    --check)
      shift
      check_runner "${1:-}"
      ;;
    --check-only)
      shift
      DIR="${1:-$PWD}"
      LANG=$(detect_language "$DIR")
      echo "detect.sh: language detected: $LANG"
      echo "detect.sh: runner availability:"
      any=0
      for r in stryker mutpy go-mutesting mutant; do
        if check_runner "$r" >/dev/null 2>&1; then
          echo "  $r: yes"
          any=1
        else
          echo "  $r: no"
        fi
      done
      if [ "$any" -eq 0 ]; then
        print_install_advisory
        exit 3
      fi
      exit 0
      ;;
    --advisory)
      print_install_advisory
      ;;
    --help|-h|"")
      sed -n '1,32p' "$0" >&2
      [ -z "${1:-}" ] && exit 2 || exit 0
      ;;
    *)
      echo "detect.sh: unknown flag: $1" >&2
      exit 2
      ;;
  esac
fi
