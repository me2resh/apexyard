#!/bin/bash
# Enforcement check (me2resh/apexyard#1549): every hook-invoking test suite
# under .claude/hooks/tests/ must source _test-session-isolation.sh so a
# direct `bash test_foo.sh` cannot overwrite the operator's live session pin
# or resolve-cache files.
#
# Opt-out: a file that deliberately exercises pin behaviour without sourcing
# the helper may place a sole-line hash comment whose body is exactly the
# OPT_OUT_MARKER string defined below. Opted-out files must still point
# APEXYARD_OPS_PIN_DIR at a temp directory (checked below).

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HELPER_NAME="_test-session-isolation.sh"
# Sole-line opt-out body (matched only as: ^# <marker>$).
OPT_OUT_MARKER='apexyard-test-session-isolation: opt-out'

PASS=0
FAIL=0
FAILED_CASES=""

mark_pass() { echo "  PASS $1"; PASS=$((PASS + 1)); }
mark_fail() {
  echo "  FAIL $1: $2" >&2
  FAIL=$((FAIL + 1))
  FAILED_CASES="${FAILED_CASES}${1}"$'\n'
}

# A suite "runs hooks" when it references a hook/lib path, common indirection
# vars (HOOK / HOOK_SRC / LIB / …), or a `_lib-*.sh` name. Variable-only
# invocations like `bash "$HOOK"` are covered via the assignment patterns.
runs_hooks() {
  local f="$1"
  grep -qE \
    'HOOK_DIR=|HOOK_SRC=|HOOKS_DIR=|(^|[^A-Za-z0-9_])HOOK=|(^|[^A-Za-z0-9_])LIB=|\.claude/hooks/[A-Za-z0-9_./-]+\.sh|_lib-[A-Za-z0-9_-]+\.sh' \
    "$f"
}

has_opt_out() {
  local f="$1"
  # Require a dedicated opt-out line so prose that names the marker does not match.
  grep -qE "^# ${OPT_OUT_MARKER}\$" "$f"
}

uses_temp_pin_dir() {
  local f="$1"
  # Must assign APEXYARD_OPS_PIN_DIR from mktemp (or a var clearly from mktemp).
  grep -qE 'APEXYARD_OPS_PIN_DIR=.*\$\(|APEXYARD_OPS_PIN_DIR="?\$[A-Za-z_][A-Za-z0-9_]*' "$f" \
    && grep -qE 'mktemp' "$f"
}

uses_bash_source_include() {
  local f="$1"
  grep -qF 'dirname "${BASH_SOURCE[0]:-$0}"' "$f" \
    && grep -qF "$HELPER_NAME" "$f"
}

missing=()
bad_include=()
opt_out_bad=()

while IFS= read -r f; do
  base=$(basename "$f")
  if has_opt_out "$f"; then
    if ! uses_temp_pin_dir "$f"; then
      opt_out_bad+=("$base")
    fi
    continue
  fi
  if runs_hooks "$f"; then
    if ! grep -qF "$HELPER_NAME" "$f"; then
      missing+=("$base")
    elif ! uses_bash_source_include "$f"; then
      bad_include+=("$base")
    fi
  fi
done < <(find "$TESTS_DIR" -maxdepth 1 -type f -name 'test_*.sh' | sort)

if [ "${#missing[@]}" -eq 0 ]; then
  mark_pass "all hook-invoking test_*.sh source $HELPER_NAME"
else
  mark_fail "hook-invoking suites missing $HELPER_NAME" \
    "$(printf '%s ' "${missing[@]}")"
fi

if [ "${#bad_include[@]}" -eq 0 ]; then
  mark_pass "hook-invoking suites resolve helper via BASH_SOURCE[0]"
else
  mark_fail "hook-invoking suites must use dirname \"\${BASH_SOURCE[0]:-\$0}\"" \
    "$(printf '%s ' "${bad_include[@]}")"
fi

if [ "${#opt_out_bad[@]}" -eq 0 ]; then
  mark_pass "opt-out suites (if any) use a temp APEXYARD_OPS_PIN_DIR"
else
  mark_fail "opt-out suites must mktemp APEXYARD_OPS_PIN_DIR" \
    "$(printf '%s ' "${opt_out_bad[@]}")"
fi

echo
echo "session-isolation helper-required: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed cases:\n%s' "$FAILED_CASES" >&2
  exit 1
fi
exit 0
