#!/bin/bash
# v5.8.0 -> v5.9.0 migration (AgDR-0241)
#
# v5.9.0 ships no per-adopter file move. /start-ticket now writes a second
# marker into the git dir (#1576). The dispatcher and the ticket gate fail
# closed and need Claude Code 2.1.295 or later for onFailure (#1623).
# This script prints those notes. It does not write any file.

set -u

QUIET="${APEXYARD_MIGRATION_QUIET:-0}"
info() { [ "$QUIET" = "1" ] || echo "$@"; }

info "migration v5.8.0->v5.9.0: no file or config move."
info "/start-ticket now writes a second marker into the git dir. Each linked worktree needs its own /start-ticket (#1576)."
info "The dispatcher and the ticket gate are fail-closed. They need Claude Code 2.1.295 or later for onFailure (#1623)."
exit 0
