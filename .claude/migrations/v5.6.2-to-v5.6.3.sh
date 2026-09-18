#!/bin/bash
# v5.6.2 → v5.6.3 migration
#
# v5.6.3 ships no per-adopter file move. Cursor adopters who still have a
# full generated ~/.cursor/hooks.json copy can lock the IDE. This script
# prints the reinstall command. It does not write files under $HOME.

set -u

QUIET="${APEXYARD_MIGRATION_QUIET:-0}"
info() { [ "$QUIET" = "1" ] || echo "$@"; }

info "migration v5.6.2→v5.6.3: no file or config move."
info "If Cursor Shell and Write calls fail closed, a leftover full hooks.json is the usual cause."
info "Run: bin/install-cursor-adapter.sh --uninstall"
info "Then run: bin/install-cursor-adapter.sh --user"
info "Enable Settings → Rules, Skills, Subagents → Include third-party Plugins, Skills, and other configs."
exit 0
