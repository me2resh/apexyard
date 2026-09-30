#!/bin/bash
# Static + dash regression pins for libraries that must source under POSIX
# shells (me2resh/apexyard#1403 remainder, AgDR-0183).
#
# PR #1419 closed the merge-gate fail-open. This file covers the two
# follow-up items left open on #1403:
#
#   1. A static check that fails when a POSIX-sourced library contains
#      the bash-only process-substitution redirect `< <(` in non-comment
#      code. Runtime tests 7a/7b in test_config_warn_dropped_defaults.sh
#      may miss a reintroduced `< <(` on bash 5.1+ where POSIX mode can
#      allow process substitution.
#   2. The dash gap at `_lib-read-config.sh` (unguarded
#      `${BASH_SOURCE[0]:-}` at top-level load). Linux CI uses dash as
#      `/bin/sh`. Dash rejects that array expansion and aborts the
#      source before `config_get` is defined.
#
# Cases:
#   1. Every hook library is free of non-comment `< <(`.
#   2. The checker rejects a synthetic fixture that plants `< <(`.
#   3. `_lib-read-config.sh` top-level BASH_SOURCE expansion is behind a
#      BASH_VERSION guard (static pin for the dash fix).
#   4. Under dash, sourcing `_lib-read-config.sh` defines `config_get`.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOKS="${HOOKS_OVERRIDE:-$SRC_ROOT/.claude/hooks}"
LIB_READ_CONFIG="$HOOKS/_lib-read-config.sh"

# Check the full hook-library set. This includes every library that a hook
# can source in bash POSIX mode, including the write detector, push-ref
# extractor, and multi-repo trace helper. The superset avoids a manual list
# drifting when a hook starts sourcing another library.

PASS=0
FAIL=0
record_pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
record_fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && echo "  $2" >&2; }

# check_no_process_sub FILE
# Exit 0 when FILE has no non-comment `< <(`. Exit 1 when it does.
# Full-line comments are stripped so a doc example of the forbidden form
# does not fail the check.
check_no_process_sub() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "missing: $file" >&2
    return 1
  fi
  # Strip full-line comments only. A code line that still holds `< <(`
  # must fail even when a trailing comment follows on the same line.
  if grep -v '^[[:space:]]*#' "$file" | grep -qE '<[[:space:]]*<\('; then
    return 1
  fi
  return 0
}

if [ ! -f "$LIB_READ_CONFIG" ]; then
  echo "FAIL: required source missing: $LIB_READ_CONFIG" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Every hook library is free of non-comment `< <(`.
# ---------------------------------------------------------------------------
for path in "$HOOKS"/_lib-*.sh; do
  lib=${path##*/}
  if [ ! -f "$path" ]; then
    record_fail "1: $lib exists for the POSIX-sourced list" "missing $path"
    continue
  fi
  if check_no_process_sub "$path"; then
    record_pass "1: $lib has no non-comment < <( process substitution"
  else
    hits=$(grep -nE '<[[:space:]]*<\(' "$path" | grep -v '^[[:space:]]*[[:digit:]]*:[[:space:]]*#' || true)
    record_fail "1: $lib has no non-comment < <( process substitution" "hits: $hits"
  fi
done

# ---------------------------------------------------------------------------
# 2. The checker rejects a synthetic fixture that plants `< <(`.
#    This is the fail-before proof for the static check itself: the real
#    library is already clean (process sub removed in #1397). A planted
#    copy must still trip the checker.
# ---------------------------------------------------------------------------
sb=$(mktemp -d)
planted="$sb/planted-posix-lib.sh"
cat > "$planted" <<'PLANT'
#!/bin/bash
# synthetic fixture for me2resh/apexyard#1403 static check
_config_warn_dropped_defaults() {
  local finding
  while IFS= read -r finding; do
    echo "$finding"
  done < <(printf '%s\n' 'x')
}
PLANT
if ! check_no_process_sub "$planted"; then
  record_pass "2: checker rejects a fixture that plants < <("
else
  record_fail "2: checker rejects a fixture that plants < <(" \
    "checker returned clean for planted process substitution"
fi
rm -rf "$sb"

# ---------------------------------------------------------------------------
# 3. Static pin: top-level BASH_SOURCE array expansion in
#    `_lib-read-config.sh` sits behind a BASH_VERSION guard so dash never
#    evaluates it (me2resh/apexyard#1403 dash gap).
# ---------------------------------------------------------------------------
# Take code lines only, up to the first function definition. Require that
# any BASH_SOURCE[0] expansion in that region is preceded (earlier in the
# region) by a BASH_VERSION test.
top_code=$(awk '
  /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { exit }
  /^[[:space:]]*#/ { next }
  { print }
' "$LIB_READ_CONFIG")

if printf '%s\n' "$top_code" | grep -q 'BASH_SOURCE\[0\]'; then
  if printf '%s\n' "$top_code" | grep -q 'BASH_VERSION'; then
    record_pass "3: top-level BASH_SOURCE expansion is behind a BASH_VERSION guard"
  else
    record_fail "3: top-level BASH_SOURCE expansion is behind a BASH_VERSION guard" \
      "BASH_SOURCE[0] appears in top-level code with no BASH_VERSION guard"
  fi
else
  # No top-level BASH_SOURCE at all also closes the dash gap.
  record_pass "3: top-level BASH_SOURCE expansion is behind a BASH_VERSION guard"
fi

# ---------------------------------------------------------------------------
# 4. Under dash, sourcing `_lib-read-config.sh` defines config_get.
#    Prefer an explicit `dash` binary. Fall back to `/bin/sh` only when
#    that shell is not bash (Linux CI: `/bin/sh` is dash).
# ---------------------------------------------------------------------------
DASH_BIN=""
if command -v dash >/dev/null 2>&1; then
  DASH_BIN=$(command -v dash)
elif [ -x /bin/dash ]; then
  DASH_BIN=/bin/dash
elif [ -x /bin/sh ] && ! /bin/sh -c 'echo "${BASH_VERSION:-}"' | grep -q .; then
  DASH_BIN=/bin/sh
fi

if [ -z "$DASH_BIN" ]; then
  record_fail "4: dash is available to run the dash-gap runtime pin" \
    "no dash binary and /bin/sh is bash — install dash or run on Linux CI"
else
  out=$(
    "$DASH_BIN" -c "
      . '$LIB_READ_CONFIG'
      if command -v config_get >/dev/null 2>&1; then
        echo config_get_defined
      else
        echo config_get_missing
      fi
    " 2>&1
  )
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | tail -1)" = "config_get_defined" ]; then
    record_pass "4: sources cleanly under dash ($DASH_BIN), config_get defined"
  else
    record_fail "4: sources cleanly under dash ($DASH_BIN), config_get defined" \
      "rc=$rc output: $out"
  fi
fi

echo
echo "===== test_posix_sourced_libs.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
