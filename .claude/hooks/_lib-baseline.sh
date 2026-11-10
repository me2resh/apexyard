#!/bin/bash
# Record one base check per ticket. Bash 3.2.
baseline_check() (
  local tree=$1 dir note sha command mode limit result check work='' output='' rc=0
  dir=$(git -C "$tree" rev-parse --absolute-git-dir) || { printf 'WARN: Base check could not run. The ticket is set.\n' >&2; return 0; }
  note="$dir/apexyard-progress.md"
  sha=$(git -C "$tree" rev-parse --verify HEAD 2>/dev/null) || sha=unborn
  # Resolve operator configuration independently of the ticket tree.
  # shellcheck source=/dev/null
  . "$(dirname "${BASH_SOURCE[0]}")/_lib-ops-root.sh"
  local ops_root
  ops_root=$(resolve_ops_root "$tree")
  # Never reuse a managed tree's config or the shared config cache.
  # shellcheck disable=SC2034
  local _CONFIG_ROOT_CACHE="$ops_root" _CONFIG_ROOT_CACHE_SET=1 _CONFIG_CACHE='{}' APEXYARD_DISABLE_RESOLUTION_CACHE=1
  [ -z "$ops_root" ] || _CONFIG_CACHE=''
  if ! progress_note_create "$tree" 2>/dev/null; then
    printf 'WARN: Base check evidence not recorded. The ticket is set.\n' >&2
    return 0
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
    [ -z "$work" ] || git -C "$tree" worktree remove --force "$work" >/dev/null 2>&1 || rmdir "$work" 2>/dev/null || true
    [ -z "$output" ] || rm -f "$output"
  }
  trap cleanup_baseline EXIT
  trap 'exit 1' HUP INT TERM
  if [ -n "$command" ]; then
    result='not run'
    check='base setup'
    mkdir -p "$tree/.claude/worktrees" || { printf 'WARN: Base check could not run. The ticket is set.\n' >&2; return 0; }
    work=$(mktemp -d "$tree/.claude/worktrees/base.XXXXXX") || { printf 'WARN: Base check could not run. The ticket is set.\n' >&2; return 0; }
    output=$(mktemp) || { printf 'WARN: Base check could not run. The ticket is set.\n' >&2; return 0; }
    if ! command -v python3 >/dev/null 2>&1; then
      result='not run'
      check='python3 unavailable'
    elif git -C "$tree" worktree add --detach "$work" "$sha" >"$output" 2>&1; then
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
          result=fail
          # Check commands report a named failure as FAIL <name> or FAIL: <name>.
          check=$(awk '/^FAIL[: ]+/ && !found {sub(/^FAIL[: ]+[[:space:]]*/, ""); print; found=1}' "$output")
          [ -n "$check" ] || check="$command"
          ;;
      esac
    fi
  fi
  if ! progress_note_update "$tree" Completed "base_sha=$sha; base_result=$result${check:+; first_failing_check=$check}" 2>/dev/null; then
    printf 'WARN: Base check evidence not recorded. The ticket is set.\n' >&2
    if [ "$mode" = refuse ]; then
      case "$result" in fail|'timed out') return 1 ;; esac
    fi
    return 0
  fi
  case "$result" in
    fail) printf 'WARN: Base check failed: %s. Treat this failure as pre-existing.\n' "$check" >&2 ;;
    'timed out') printf 'WARN: Base check timed out after %s seconds. Treat this result as pre-existing.\n' "$limit" >&2 ;;
    'not run') printf 'WARN: Base check not run: %s.\n' "$check" >&2 ;;
    *) printf 'Base check: %s.\n' "$result" ;;
  esac
  if [ "$mode" = refuse ]; then
    case "$result" in fail|'timed out') return 1 ;; esac
  fi
  return 0
)
