#!/usr/bin/env bash
# SessionStart hook: opportunistically refresh the apexyard-search index so an
# agent doesn't search a stale index and fall back to grep (apexyard-premium#371).
#
# It runs `apexyard-search reindex --incremental --if-stale=<threshold>`:
#   - --incremental: cheap manifest-mtime delta sync (only changed files).
#   - --if-stale:    the CLI no-ops when the index is still fresh, so the common
#                    case (just reindexed) costs essentially nothing.
#
# SAFE SHAPE: retrofitted onto the shared premium-hook harness
# (_lib-premium-hook.sh, me2resh/apexyard#890) — behaviour-preserving, not a
# redesign. This hook NEVER blocks session start and ALWAYS exits 0. Every
# failure mode is a silent no-op:
#   - apexyard-search not on PATH  (MCP not installed)         -> no-op
#   - index already fresh          (--if-stale short-circuits) -> no-op
#   - APEXYARD_OPS_ROOT / _PORTFOLIO_ROOT unset                -> no-op (CLI errs, swallowed)
#   - reindex slower than the timeout                          -> killed, no-op
#   - APEXYARD_SEARCH_REINDEX_DISABLE set                      -> no-op
#
# Why "search" defaults enabled=true (see _lib-premium-hook.sh's
# `default_enabled` param): this hook historically gated ONLY on
# install-presence (`command -v apexyard-search`), with no features.yaml
# check at all. Routing it through the harness must not newly require a
# "search: enabled: true" block in features.yaml for adopters who already
# have apexyard-search on PATH and never configured that key — so the
# feature-flag gate here defaults to enabled when the key is absent, and
# only an explicit "search: / enabled: false" in features.yaml opts a
# session out without needing to uninstall the CLI. See AgDR-0095.
#
# Tunables (env):
#   APEXYARD_SEARCH_STALE_AFTER       staleness threshold in seconds (default 86400 = 24h)
#   APEXYARD_SEARCH_REINDEX_TIMEOUT   max seconds to spend before giving up (default 25)
#   APEXYARD_SEARCH_REINDEX_DISABLE   non-empty -> skip entirely

set -u

# Operator kill-switch. Hook-specific, so it stays a plain early-exit rather
# than routing through the harness's feature-flag gate.
if [ -n "${APEXYARD_SEARCH_REINDEX_DISABLE:-}" ]; then
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-premium-hook.sh"

STALE_AFTER="${APEXYARD_SEARCH_STALE_AFTER:-86400}"

# Map this hook's own timeout tunable onto the harness's generic one. Read
# by premium_hook_run in _lib-premium-hook.sh (sourced above into this same
# shell, not a child process) — shellcheck can't see the cross-file read, so
# it flags this as unused; it isn't.
# shellcheck disable=SC2034
PREMIUM_HOOK_TIMEOUT_SECS="${APEXYARD_SEARCH_REINDEX_TIMEOUT:-25}"

# Payload preserves the exact prior command + redirection (discard stdout,
# and — same as before the retrofit — stderr rides along into the same
# redirect since `2>&1` dups onto the already-redirected stdout). Swallowing
# the exit code and the timeout guard are the harness's job now.
PAYLOAD="apexyard-search reindex --incremental --if-stale=\"${STALE_AFTER}\" >/dev/null 2>&1"

premium_hook_run "search" "command -v apexyard-search" "$PAYLOAD" "true"

exit 0
