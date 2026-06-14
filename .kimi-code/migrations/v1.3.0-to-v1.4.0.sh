#!/bin/bash
# v1.3.0 → v1.4.0 migration: PLACEHOLDER
#
# v1.4.0 is in active development. Tickets queued for this release that may
# introduce per-adopter migrations:
#
#   - templates/tickets/ reorg — move adopter overrides from
#     custom-templates/spike.md → custom-templates/tickets/spike.md
#     (will land via a separate v1.4.0-cycle ticket)
#
# Until those tickets land, this script is a no-op. Its existence keeps the
# chain shape in place so /update can detect that a v1.3.0 adopter has
# a one-step migration to v1.4.0 even when there's nothing yet to do.
#
# When the v1.4.0 reorg ticket lands, populate the body of this script and
# update docs/upgrading.md's "what each migration does" table.
#
# Exit codes:
#   0 — no-op (placeholder)
#   1 — conflict (reserved)
#   2 — hard error (reserved)

set -u

QUIET="${APEXYARD_MIGRATION_QUIET:-0}"
info() { [ "$QUIET" = "1" ] || echo "$@"; }

info "migration v1.3.0→v1.4.0: placeholder (no migrations queued yet for v1.4.0)."
exit 0
