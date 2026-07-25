#!/usr/bin/env bash
# SessionStart hook: opportunistically refresh the apexyard-search index so an
# agent doesn't search a stale index and fall back to grep (apexyard-premium#371).
#
# It runs `apexyard-search reindex --incremental --if-stale=<threshold>`:
#   - --incremental: cheap manifest-mtime delta sync (only changed files).
#   - --if-stale:    the CLI no-ops when the index is still fresh, so the common
#                    case (just reindexed) costs essentially nothing.
#
# REACHABILITY, NOT JUST PRESENCE (me2resh/apexyard#929): before nudging a
# reindex, this hook now probes whether apexyard-search can actually RESPOND
# — `command -v apexyard-search` only proves the binary is on PATH, not that
# invoking it works. A binary that's present but broken (missing a runtime
# dependency, a stale venv, whatever) used to be treated identically to a
# healthy install: the reindex payload would run, silently fail, and an agent
# would assume search was live when it was quietly falling back to grep+Read
# the whole session. The probe closes that gap with a fast, bounded,
# side-effect-free `apexyard-search doctor` call (an index-health report that
# always exits 0 when it runs cleanly) via `premium_hook_probe`:
#   - REACHABLE      -> unchanged behaviour, opportunistic reindex runs.
#   - UNREACHABLE     -> one honest stderr line ("configured but not
#                        reachable — falling back to grep+Read") INSTEAD of
#                        the reindex nudge. Still exits 0 — advisory only.
#   - NOT_APPLICABLE  -> unchanged silent no-op (not configured / disabled).
#
# SAFE SHAPE: retrofitted onto the shared premium-hook harness
# (_lib-premium-hook.sh, me2resh/apexyard#890) — behaviour-preserving except
# for the #929 reachability branch above. This hook NEVER blocks session
# start and ALWAYS exits 0. Every failure mode is a silent no-op or an
# advisory line, never a block:
#   - apexyard-search not on PATH  (MCP not installed)         -> no-op
#   - index already fresh          (--if-stale short-circuits) -> no-op
#   - APEXYARD_OPS_ROOT / _PORTFOLIO_ROOT unset                -> no-op (CLI errs, swallowed)
#   - reindex slower than the timeout                          -> killed, no-op
#   - APEXYARD_SEARCH_REINDEX_DISABLE set                      -> no-op
#   - reachability probe fails or hangs past its own timeout   -> honest stderr note, no reindex nudge
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
#   APEXYARD_SEARCH_PROBE_TIMEOUT     max seconds for the reachability probe (default 5)
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

# Map this hook's own timeout tunables onto the harness's generic ones. Read
# by premium_hook_run / premium_hook_probe in _lib-premium-hook.sh (sourced
# above into this same shell, not a child process) — shellcheck can't see
# the cross-file read, so it flags these as unused; they aren't.
# shellcheck disable=SC2034
PREMIUM_HOOK_TIMEOUT_SECS="${APEXYARD_SEARCH_REINDEX_TIMEOUT:-25}"
# shellcheck disable=SC2034
PREMIUM_HOOK_PROBE_TIMEOUT_SECS="${APEXYARD_SEARCH_PROBE_TIMEOUT:-5}"

# (#929) Reachability probe BEFORE the reindex nudge. `apexyard-search
# doctor` is the right probe command: it's a fast, side-effect-free report
# (index-health JSON) that always exits 0 on a healthy CLI — so a non-zero
# exit or a hang here means the CLI itself can't respond, not that the index
# merely needs rebuilding.
premium_hook_probe "search" "command -v apexyard-search" "apexyard-search doctor >/dev/null 2>&1" "true"
case $? in
  0)
    # REACHABLE -> unchanged behaviour. Payload preserves the exact prior
    # command + redirection (discard stdout, and — same as before the
    # retrofit — stderr rides along into the same redirect since `2>&1`
    # dups onto the already-redirected stdout). Swallowing the exit code
    # and the timeout guard are the harness's job.
    PAYLOAD="apexyard-search reindex --incremental --if-stale=\"${STALE_AFTER}\" >/dev/null 2>&1"
    premium_hook_run "search" "command -v apexyard-search" "$PAYLOAD" "true"
    ;;
  1)
    # UNREACHABLE -> configured but can't respond right now. One honest
    # line instead of a reindex nudge that can't succeed; still advisory,
    # never blocks session start.
    echo "[apexyard-search] search is configured but not reachable right now — falling back to grep+Read for this session. (#929)" >&2
    ;;
  *)
    # NOT_APPLICABLE (2) -> not configured / disabled. Unchanged silent no-op.
    ;;
esac

exit 0
