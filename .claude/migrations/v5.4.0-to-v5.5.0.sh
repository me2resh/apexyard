#!/bin/bash
# v5.4.0 → v5.5.0 migration: PLACEHOLDER (no-op)
#
# v5.5.0 ships no per-adopter file or configuration migration. This script
# keeps the migration chain continuous for adopters upgrading from v5.4.0.

set -u

QUIET="${APEXYARD_MIGRATION_QUIET:-0}"
info() { [ "$QUIET" = "1" ] || echo "$@"; }

info "migration v5.4.0→v5.5.0: placeholder (no adopter-facing migration for this release)."
exit 0
