#!/bin/bash
# _lib-gh-timeout.sh — per-call time limit for merge-gate `gh` calls (#1796).
#
# WHY: one stalled forge call held a merge gate for 120 s (inv-1770). The
# dispatcher budget is 60 s. A per-call limit ends that stall early and the
# gate fails closed. The limit wraps each `gh` invocation, not the gate
# process — so the AgDR-0256 PPID binding for PR metadata still holds.
#
# PUBLIC:
#   apexyard_gh [gh args...]
#       Runs `gh` under a time limit. Default 20 s
#       (APEXYARD_GH_CALL_TIMEOUT). Exit status is gh's status, or 124 when
#       the limit fires (GNU timeout convention). On timeout, prints one
#       BLOCKED line to stderr.
#
#   apexyard_gh_call_timeout_secs
#       Echoes the effective limit in seconds.
#
# Portable: prefers `timeout`, then `gtimeout`, then a bash-native watchdog.
# APEXYARD_GH_FORCE_WATCHDOG=1 forces the watchdog (tests only).

apexyard_gh_call_timeout_secs() {
  case "${APEXYARD_GH_CALL_TIMEOUT:-}" in
    ''|*[!0-9]*)
      printf '%s\n' 20
      ;;
    0)
      printf '%s\n' 20
      ;;
    *)
      printf '%s\n' "$APEXYARD_GH_CALL_TIMEOUT"
      ;;
  esac
}

# _apexyard_gh_watchdog <secs> <cmd...> — bash-native limit when timeout(1)
# is absent. Returns the command status, or 124 when killed for time.
_apexyard_gh_watchdog() {
  local secs="$1" out_f flag_f pid wd rc
  shift
  out_f=$(mktemp "${TMPDIR:-/tmp}/apexyard-gh.XXXXXX") || return 1
  flag_f=$(mktemp "${TMPDIR:-/tmp}/apexyard-gh-flag.XXXXXX") || {
    rm -f "$out_f"
    return 1
  }
  "$@" >"$out_f" &
  pid=$!
  (
    sleep "$secs"
    if kill -TERM "$pid" 2>/dev/null; then
      printf '1\n' >"$flag_f"
      sleep 1
      kill -KILL "$pid" 2>/dev/null
    fi
  ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid" 2>/dev/null
  rc=$?
  kill "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  if [ -s "$flag_f" ]; then
    rc=124
  fi
  cat "$out_f"
  rm -f "$out_f" "$flag_f"
  return "$rc"
}

apexyard_gh() {
  local secs rc
  secs=$(apexyard_gh_call_timeout_secs)

  if [ -z "${APEXYARD_GH_FORCE_WATCHDOG:-}" ]; then
    if command -v timeout >/dev/null 2>&1; then
      timeout -k 2 "$secs" gh "$@"
      rc=$?
      if [ "$rc" -eq 124 ]; then
        printf 'BLOCKED: forge call timed out after %ss. The merge gate fails closed. Retry when the forge responds.\n' "$secs" >&2
      fi
      return "$rc"
    fi
    if command -v gtimeout >/dev/null 2>&1; then
      gtimeout -k 2 "$secs" gh "$@"
      rc=$?
      if [ "$rc" -eq 124 ]; then
        printf 'BLOCKED: forge call timed out after %ss. The merge gate fails closed. Retry when the forge responds.\n' "$secs" >&2
      fi
      return "$rc"
    fi
  fi

  _apexyard_gh_watchdog "$secs" gh "$@"
  rc=$?
  if [ "$rc" -eq 124 ]; then
    printf 'BLOCKED: forge call timed out after %ss. The merge gate fails closed. Retry when the forge responds.\n' "$secs" >&2
  fi
  return "$rc"
}
