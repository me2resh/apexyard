#!/usr/bin/env bash
# Per-clone memory exclusions. Advisory only: never block a session.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
warn() { printf '%s\n' 'WARN: rule excludes could not be updated; continuing with existing settings.' >&2; }
# shellcheck source=.claude/hooks/_lib-ops-root.sh
if ! source "$HOOK_DIR/_lib-ops-root.sh" 2>/dev/null; then warn; exit 0; fi
OPS_ROOT=$(resolve_ops_root "$PWD" 2>/dev/null)
if [ -z "$OPS_ROOT" ] || ! command -v jq >/dev/null || ! command -v python3 >/dev/null; then
  warn
  exit 0
fi
# The shared resolver normalizes linked worktrees for governance markers.
# Settings are clone-local: map back to this hook's anchored worktree only
# when it shares the resolved root's Git common directory. Unrelated resolved roots are refused.
CLONE_ROOT=$(cd "$HOOK_DIR/../.." && pwd -P)
RESOLVED_COMMON=$(git -C "$OPS_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
CLONE_COMMON=$(git -C "$CLONE_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -n "$RESOLVED_COMMON" ] && [ "$RESOLVED_COMMON" = "$CLONE_COMMON" ] && _ops_root_anchor_valid "$CLONE_ROOT"; then
  OPS_ROOT="$CLONE_ROOT"
elif [ "$OPS_ROOT" != "$CLONE_ROOT" ]; then
  exit 0
fi
# pwd -P resolves directory symlinks without relying on a GNU realpath binary.
OPS_ROOT=$(cd "$OPS_ROOT" 2>/dev/null && pwd -P) || { warn; exit 0; }
if ! git -C "$OPS_ROOT" check-ignore -q .claude/settings.local.json 2>/dev/null; then
  warn
  exit 0
fi
if ! git -C "$OPS_ROOT" check-ignore -q .claude/session/rule-excludes.owned 2>/dev/null; then
  warn
  exit 0
fi
if ! python3 "$HOOK_DIR/lib/rule-excludes.py" "$OPS_ROOT" "${HOME:-}" 2>/dev/null; then warn; fi
exit 0
