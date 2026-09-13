#!/bin/bash
# v5.5.1 → v5.5.2 migration: PLACEHOLDER (no-op)
#
# v5.5.2 ships no per-adopter file or configuration migration. This script
# keeps the migration chain continuous for adopters upgrading from v5.5.1.

set -u

QUIET="${APEXYARD_MIGRATION_QUIET:-0}"
info() { [ "$QUIET" = "1" ] || echo "$@"; }

info "migration v5.5.1→v5.5.2: placeholder (no adopter-facing migration for this release)."
exit 0
