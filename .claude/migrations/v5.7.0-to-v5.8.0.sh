#!/bin/bash
# v5.7.0 -> v5.8.0 migration (AgDR-0223)
#
# v5.8.0 ships no per-adopter file move. It removes the optional search MCP
# integration (#1537), so any mcp_search keys in a fork's config are now
# unused. This script reports them. It does not write any file.

set -u

QUIET="${APEXYARD_MIGRATION_QUIET:-0}"
info() { [ "$QUIET" = "1" ] || echo "$@"; }

info "migration v5.7.0->v5.8.0: no file or config move."

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
found=0
for f in "$root"/.claude/project-config.json "$root"/.claude/project-config.*.json; do
  [ -f "$f" ] || continue
  case "$f" in *project-config.defaults.json) continue ;; esac
  if grep -q '"mcp_search"' "$f" 2>/dev/null; then
    if [ "$found" -eq 0 ]; then
      info "The optional search MCP integration is removed (#1537). These files still set mcp_search, which is now unused:"
    fi
    found=1
    info "  $f"
  fi
done
if [ "$found" -eq 1 ]; then
  info "You can delete the mcp_search block. Nothing reads it."
fi
info "Edits under .claude/worktrees/ now need an active ticket, like any other source edit (#1531)."
exit 0
