#!/bin/bash
# Record one base check per ticket and starting commit. Bash 3.2.
baseline_check() (
  local tree=$1 dir note sha command mode limit result check work='' output='' rc=0
  dir=$(git -C "$tree" rev-parse --absolute-git-dir) || return 1
  note="$dir/apexyard-progress.md"
  sha=$(git -C "$tree" rev-parse --verify HEAD 2>/dev/null) || sha=unborn
  progress_note_create "$tree" || return 1
  # Scope the reader to this project, not the session's main checkout.
  # The reader consumes these variables through config_get_or.
  # shellcheck disable=SC2034
  local _CONFIG_ROOT_CACHE="$tree" _CONFIG_ROOT_CACHE_SET=1 _CONFIG_CACHE=''
  if [ ! -f "$tree/.claude/project-config.defaults.json" ] && [ -f "$tree/.claude/project-config.json" ]; then
    _CONFIG_CACHE=$(cat "$tree/.claude/project-config.json") || return 1
  fi
  mode=$(config_get_or '.checks.baseline_mode' warn)
  # Reuse evidence for this ticket, including a refused start.
  if grep -q 'base_sha=' "$note"; then
    if [ "$mode" = refuse ] && grep -Eq 'base_result=(fail|timed out)' "$note"; then return 1; fi
    return 0
  fi
  command=$(config_get_or '.checks.baseline_command' '')
  limit=$(config_get_or '.checks.baseline_timeout_seconds' 600)
  case "$limit" in ''|*[!0-9]*|0) limit=600 ;; esac
  result='not configured'
  check=''
  # shellcheck disable=SC2329
  cleanup_baseline() {
    [ -z "$work" ] || git -C "$tree" worktree remove --force "$work" >/dev/null 2>&1
    [ -z "$output" ] || rm -f "$output"
  }
  trap cleanup_baseline EXIT
  trap 'exit 1' HUP INT TERM
  if [ -n "$command" ]; then
    result=fail
    check='base setup'
    mkdir -p "$tree/.claude/worktrees" || return 1
    work=$(mktemp -d "$tree/.claude/worktrees/base.XXXXXX") || return 1
    output=$(mktemp) || return 1
    if git -C "$tree" worktree add --detach "$work" "$sha" >"$output" 2>&1; then
      # Stop the complete command group when the time limit expires.
      python3 - "$work" "$command" "$limit" >"$output" 2>&1 <<'PY' || rc=$?
import os
import signal
import subprocess
import sys
p = subprocess.Popen(['bash', '-o', 'pipefail', '-c', sys.argv[2]],
                     cwd=sys.argv[1], start_new_session=True)
try:
    code = p.wait(timeout=int(sys.argv[3]))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()
    sys.exit(124)
sys.exit(0 if code == 0 else 1)
PY
      case "$rc" in
        0) result=pass; check='' ;;
        124) result='timed out'; check='' ;;
        *)
          # Check commands report a named failure as FAIL <name> or FAIL: <name>.
          check=$(awk '/^FAIL[: ]+/ && !found {sub(/^FAIL[: ]+[[:space:]]*/, ""); print; found=1}' "$output")
          [ -n "$check" ] || check="$command"
          ;;
      esac
    fi
  fi
  progress_note_update "$tree" Completed "base_sha=$sha; base_result=$result${check:+; first_failing_check=$check}" || return 1
  case "$result" in
    fail) printf 'WARN: Base check failed: %s. Treat this failure as pre-existing.\n' "$check" >&2 ;;
    'timed out') printf 'WARN: Base check timed out after %s seconds. Treat this result as pre-existing.\n' "$limit" >&2 ;;
    *) printf 'Base check: %s.\n' "$result" ;;
  esac
  if [ "$mode" = refuse ]; then
    case "$result" in fail|'timed out') return 1 ;; esac
  fi
  return 0
)
