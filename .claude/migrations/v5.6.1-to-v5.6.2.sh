#!/bin/bash
# v5.6.1 → v5.6.2 migration: PLACEHOLDER (no-op)
#
# v5.6.2 ships no per-adopter file or configuration migration. This script
# keeps the migration chain continuous for adopters upgrading from v5.6.1.
#
# Backfilled by #1298 after v5.6.2 shipped without a pair script.

set -u

QUIET="${APEXYARD_MIGRATION_QUIET:-0}"
info() { [ "$QUIET" = "1" ] || echo "$@"; }

info "migration v5.6.1→v5.6.2: placeholder (no adopter-facing migration for this release)."
exit 0
