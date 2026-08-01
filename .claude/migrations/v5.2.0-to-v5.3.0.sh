#!/bin/bash
# v5.2.0 → v5.3.0 migration: PLACEHOLDER (no-op)
#
# v5.3.0 shipped no per-adopter migration — no gitignored region moved, no
# default config key added, no marker file introduced, no directory renamed.
#
# This script exists so the migration chain (`.claude/migrations/`, walked
# by `.claude/hooks/_lib-migration-chain.sh` via `/update` step 8b) has an
# unbroken link at this hop. Per the contract in `.claude/migrations/README.md`:
# "If the new release has no per-adopter migration, still create the script
# as a no-op" — skipping a release here would make `migration_chain` refuse
# to walk past it, defeating the whole point of the chain.
#
# Backfilled retroactively by #1105 — see that issue for why the entire
# chain from v2.0.2 through v5.3.0 was missing these placeholders.
#
# Exit codes:
#   0 — no-op (placeholder)
#   1 — conflict (reserved)
#   2 — hard error (reserved)

set -u

QUIET="${APEXYARD_MIGRATION_QUIET:-0}"
info() { [ "$QUIET" = "1" ] || echo "$@"; }

info "migration v5.2.0→v5.3.0: placeholder (no adopter-facing migration for this release)."
exit 0
