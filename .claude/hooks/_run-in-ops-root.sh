#!/bin/bash
# Wrapper for Codex/Claude hook config entries.
#
# Given a hook script name, resolve the ops root using the shared
# resolver and exec the matching hook from the framework's
# `.claude/hooks/` directory. This keeps the Codex hook config short
# while reusing the existing shell enforcement layer.

set -u

HOOK_NAME="${1:-}"
shift || true

if [ -z "$HOOK_NAME" ]; then
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-ops-root.sh"

ROOT="$(resolve_ops_root "$PWD")"
if [ -z "$ROOT" ] || [ ! -d "$ROOT/.claude/hooks" ]; then
  exit 0
fi

exec "$ROOT/.claude/hooks/$HOOK_NAME" "$@"
