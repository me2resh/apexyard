#!/bin/bash
# v5.6.3 → v5.7.0 migration
#
# v5.7.0 ships no per-adopter file move. /approve-merge now stops a merge
# when the PR is behind its base branch (#1406). This script prints how to
# turn that check off. It does not write any file.

set -u

QUIET="${APEXYARD_MIGRATION_QUIET:-0}"
info() { [ "$QUIET" = "1" ] || echo "$@"; }

info "migration v5.6.3→v5.7.0: no file or config move."
info "/approve-merge now stops when a PR is behind its base branch. The check is on by default."
info "To turn it off, set merge.require_up_to_date to false in .claude/project-config.json."
exit 0
