#!/bin/bash
# v5.5.0 → v5.5.1 migration: PLACEHOLDER (no-op)
#
# v5.5.1 ships no per-adopter file or configuration migration. This script
# keeps the migration chain continuous for adopters upgrading from v5.5.0.

set -u

QUIET="${APEXYARD_MIGRATION_QUIET:-0}"
info() { [ "$QUIET" = "1" ] || echo "$@"; }

info "migration v5.5.0→v5.5.1: placeholder (no adopter-facing migration for this release)."
exit 0
