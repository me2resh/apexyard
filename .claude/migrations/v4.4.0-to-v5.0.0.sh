#!/bin/bash
# v4.4.0 → v5.0.0 migration: PLACEHOLDER (no-op)
#
# v5.0.0 shipped no per-adopter migration — the major bump was driven by
# breaking changes to the framework's own conventions and skills, not by
# any adopter-owned file, directory, or config key that needed moving.
#
# This script exists so the migration chain (`.claude/migrations/`, walked
# by `.claude/hooks/_lib-migration-chain.sh` via `/update` step 8b) has an
# unbroken link at this hop. Per the contract in `.claude/migrations/README.md`:
# "If the new release has no per-adopter migration, still create the script
# as a no-op" — skipping a release here would make `migration_chain` refuse
# to walk past it, defeating the whole point of the chain for every adopter
# jumping across the v4→v5 boundary.
#
# Backfilled retroactively by #1105 — this is a documentation/discipline
# gap fix, not evidence that v5.0.0 actually needed adopter action. If a
# genuine v4.4.0→v5.0.0 migration need surfaces later, populate this script
# and update docs/upgrading.md's "what each migration does" table.
#
# Exit codes:
#   0 — no-op (placeholder)
#   1 — conflict (reserved)
#   2 — hard error (reserved)

set -u

QUIET="${APEXYARD_MIGRATION_QUIET:-0}"
info() { [ "$QUIET" = "1" ] || echo "$@"; }

info "migration v4.4.0→v5.0.0: placeholder (no adopter-facing migration for this release)."
exit 0
