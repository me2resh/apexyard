#!/bin/bash
# _lib-premium-hook.sh — shared safe-fallback harness for PREMIUM hooks
# (me2resh/apexyard#890).
#
# THE PROBLEM THIS FIXES: every hook that touches a premium component
# (apexyard-search reindex, the #514 search self-heal, apexyard-premium's
# budget enforcer, future premium hooks not yet written) has hand-rolled the
# same "safe fallback" shape — gate on install-presence, timeout-guard the
# slow part, swallow non-zero exit, never block the session. Because it's
# copy-pasted per hook, every NEW premium hook is a fresh chance to get the
# safety wrong. This lib turns the convention into one audited primitive so
# premium hooks are safe-by-construction and CANNOT break free/framework
# users, by construction rather than by careful copy-paste.
#
# CONVENTION (see docs/agdr/AgDR-0095-premium-hook-safe-fallback-harness.md):
# any NEW premium-touching hook MUST route its premium-only work through
# `premium_hook_run` below instead of hand-rolling its own gate/timeout/
# swallow logic.
#
# SAFE SHAPE (mirrors reindex-on-session-start.sh / check-upstream-drift.sh):
# `premium_hook_run` NEVER blocks its caller and ALWAYS returns 0. Every
# failure mode is a silent no-op:
#   - the feature is disabled (or unconfigured, depending on the caller's
#     chosen default — see `premium_feature_enabled` below)     -> no-op
#   - the premium component isn't present (presence check fails) -> no-op
#   - the payload exits non-zero                                 -> swallowed
#   - the payload hangs past the timeout                         -> killed, swallowed
#   - jq/awk/timeout aren't installed                            -> degrades, never blocks
#
# THREE SAFETY PROPERTIES, CENTRALIZED (per the ticket):
#   1. GATE       — premium_feature_enabled(<feature_key>) AND a caller-
#                    supplied presence check both have to pass before the
#                    payload runs at all. Absent either -> zero output, zero
#                    latency (no timeout wrapper spun up, nothing execed).
#   2. FAIL-SAFE   — the payload runs inside a timeout-guarded child process
#                    (prefers GNU `timeout`, then macOS `gtimeout`; degrades
#                    to no wrapper if neither exists, same as
#                    reindex-on-session-start.sh); its exit code is swallowed.
#   3. ALWAYS 0    — premium_hook_run itself never returns non-zero. There is
#                    no code path in this file that propagates a failure to
#                    the caller.
#
# USAGE: source this file alone — it resolves _lib-read-config.sh /
# _lib-portfolio-paths.sh itself (relative to its own location) the first
# time it needs features.yaml, so callers don't have to pre-source them:
#
#   HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=/dev/null
#   . "$HOOK_DIR/_lib-premium-hook.sh"
#
#   premium_hook_run <feature_key> <presence_check_cmd> <payload_cmd> [default_enabled]
#
#     feature_key       Key looked up as a top-level block in features.yaml,
#                        e.g. "search" -> looks for:
#                          search:
#                            enabled: true
#     presence_check_cmd A shell command STRING; exit 0 means "the premium
#                        component is present" (e.g. "command -v apexyard-search").
#                        Pass "" to skip the presence check entirely (only the
#                        feature flag gates the payload).
#     payload_cmd        A shell command STRING — the actual premium work,
#                        including any redirection it wants (e.g.
#                        "apexyard-search reindex --incremental >/dev/null 2>&1").
#                        Executed via `bash -c` in a NEW child process so the
#                        timeout wrapper can kill it if it hangs — it does
#                        NOT inherit this shell's local functions/variables,
#                        so interpolate any values you need directly into the
#                        string before calling.
#     default_enabled     "true" (default) | "false" — what premium_feature_enabled
#                        should return when features.yaml (or the specific key)
#                        is entirely absent. Existing premium hooks that
#                        historically gated purely on install-presence (no
#                        features.yaml check at all, e.g. the pre-#890 shape
#                        of reindex-on-session-start.sh) should pass "true" so
#                        retrofitting introduces ZERO behaviour regression for
#                        adopters who never configured features.yaml. New
#                        premium hooks that want a stricter explicit-opt-in
#                        posture should pass "false".
#
#   Example (mirrors the reindex-on-session-start.sh retrofit):
#     premium_hook_run "search" "command -v apexyard-search" \
#       "apexyard-search reindex --incremental --if-stale=86400 >/dev/null 2>&1" \
#       "true"
#
# Tunables (env):
#   PREMIUM_HOOK_TIMEOUT_SECS   max seconds to spend before killing the
#                               payload (default 25, matches
#                               reindex-on-session-start.sh's own default)
#
# Also exposes (for callers that just want the gate without running
# anything, or want to build their own presence check):
#   premium_feature_enabled <feature_key> [default_enabled]
#       0 (true)  if features.yaml has "<feature_key>: / enabled: true"
#       1 (false) if it has "<feature_key>: / enabled: false"
#       otherwise falls back to [default_enabled] ("true" unless passed "false")
#   premium_bin_present <bin_name>
#       Convenience: `command -v <bin_name>` as a one-liner, for building a
#       presence_check_cmd string, e.g.:
#         premium_hook_run "search" "premium_bin_present apexyard-search" "..."
#       (works because presence checks run via `eval` in THIS shell, not a
#       child process — unlike the payload, they inherit this lib's functions.)
#
#   premium_hook_probe <feature_key> <presence_check_cmd> <probe_cmd> [default_enabled]
#       A cheap, bounded LIVENESS check (me2resh/apexyard#929) — for callers
#       that need to know whether a premium component can actually RESPOND
#       right now, not just whether it's installed, before deciding what to
#       advertise. Same GATE 1 (feature flag) / GATE 2 (presence) semantics
#       as premium_hook_run, and the same timeout-guarded child-process
#       execution shape, but instead of always returning 0 it returns a
#       three-way result the caller branches on:
#         0  REACHABLE     — gate passed AND probe_cmd exited 0 in time.
#         1  UNREACHABLE    — gate passed but probe_cmd exited non-zero or
#                            was killed for hanging past the timeout.
#         2  NOT_APPLICABLE — feature disabled/unconfigured, presence check
#                            failed, or required args are missing. Same
#                            "nothing to report on" case premium_hook_run
#                            treats as a silent no-op.
#       probe_cmd should be side-effect-free and fast (a liveness check,
#       not the real premium work) — see reindex-on-session-start.sh for
#       the worked example (probes `apexyard-search doctor` before nudging
#       a reindex).
#
# Tunables (env):
#   PREMIUM_HOOK_PROBE_TIMEOUT_SECS   max seconds a premium_hook_probe call
#                                     spends before killing the probe and
#                                     treating it as UNREACHABLE (default 5 —
#                                     short on purpose; a liveness check
#                                     should be fast even when the caller's
#                                     own premium_hook_run payload is allowed
#                                     a longer PREMIUM_HOOK_TIMEOUT_SECS)
#
# Source-guard: safe to source more than once in the same shell (idempotent,
# matches the pattern in _lib-ops-root.sh).

[ -n "${_LIB_PREMIUM_HOOK_SOURCED:-}" ] && return 0
_LIB_PREMIUM_HOOK_SOURCED=1

set -u

# ------------------------------------------------------------------------------
# Internal: resolve this lib's own directory (for sourcing sibling libs),
# the ops-fork root, and the portfolio root — same resolution order used by
# validate-search-config.sh / reindex-on-session-start.sh's siblings.
# Cached per-process.
# ------------------------------------------------------------------------------
_PREMIUM_HOOK_DIR_CACHE=""
_premium_hook_dir() {
  if [ -z "$_PREMIUM_HOOK_DIR_CACHE" ]; then
    _PREMIUM_HOOK_DIR_CACHE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  printf '%s' "$_PREMIUM_HOOK_DIR_CACHE"
}

_PREMIUM_OPS_ROOT_CACHE=""
_premium_ops_root() {
  if [ -n "$_PREMIUM_OPS_ROOT_CACHE" ]; then
    printf '%s' "$_PREMIUM_OPS_ROOT_CACHE"
    return 0
  fi
  local dir root
  dir=$(_premium_hook_dir)
  root=""
  if [ -f "$dir/_lib-ops-root.sh" ]; then
    # shellcheck source=/dev/null
    . "$dir/_lib-ops-root.sh"
    if command -v resolve_ops_root >/dev/null 2>&1; then
      root=$(resolve_ops_root "$PWD")
    fi
  fi
  if [ -z "$root" ]; then
    # Fall back to this lib's own fork location.
    root="$(cd "$dir/../.." 2>/dev/null && pwd)"
  fi
  _PREMIUM_OPS_ROOT_CACHE="$root"
  printf '%s' "$root"
}

_PREMIUM_PORTFOLIO_ROOT_CACHE=""
_premium_portfolio_root() {
  if [ -n "$_PREMIUM_PORTFOLIO_ROOT_CACHE" ]; then
    printf '%s' "$_PREMIUM_PORTFOLIO_ROOT_CACHE"
    return 0
  fi
  local dir ops root registry
  dir=$(_premium_hook_dir)
  ops=$(_premium_ops_root)
  root=""
  if [ -f "$dir/_lib-read-config.sh" ] && [ -f "$dir/_lib-portfolio-paths.sh" ]; then
    # shellcheck source=/dev/null
    . "$dir/_lib-read-config.sh"
    # shellcheck source=/dev/null
    . "$dir/_lib-portfolio-paths.sh"
    if command -v portfolio_registry >/dev/null 2>&1; then
      registry=$(portfolio_registry 2>/dev/null)
      if [ -n "$registry" ]; then
        root=$(cd "$(dirname "$registry")" 2>/dev/null && pwd)
      fi
    fi
  fi
  [ -n "$root" ] || root="$ops"
  _PREMIUM_PORTFOLIO_ROOT_CACHE="$root"
  printf '%s' "$root"
}

# ------------------------------------------------------------------------------
# Internal: locate features.yaml, checking the same candidate locations as
# validate-search-config.sh (portfolio root first, then ops root, then an
# explicit $APEXYARD_PORTFOLIO_ROOT override). Not cached — cheap stat calls,
# and callers may run this across a long-lived shell where the file could
# appear mid-session (e.g. a test fixture writing it after first source).
# ------------------------------------------------------------------------------
_premium_features_yaml() {
  local ops portfolio candidate
  ops=$(_premium_ops_root)
  portfolio=$(_premium_portfolio_root)
  for candidate in "$portfolio/features.yaml" "$ops/features.yaml" "${APEXYARD_PORTFOLIO_ROOT:-}/features.yaml"; do
    [ -n "$candidate" ] && [ -f "$candidate" ] || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# ------------------------------------------------------------------------------
# Public: premium_feature_enabled <feature_key> [default_enabled]
#   See header for full semantics. Scoped block match (top-level
#   "<feature_key>:" followed by an indented "enabled: true/false") — not a
#   blanket grep, so it can't false-positive on an unrelated feature's flag.
# ------------------------------------------------------------------------------
premium_feature_enabled() {
  local key="${1:-}"
  local default_enabled="${2:-true}"

  # No key to look up -> apply the caller's default directly.
  if [ -z "$key" ]; then
    [ "$default_enabled" = "false" ] && return 1 || return 0
  fi

  local file
  if ! file=$(_premium_features_yaml); then
    # No features.yaml anywhere -> apply the caller's default.
    [ "$default_enabled" = "false" ] && return 1 || return 0
  fi

  # Explicit "enabled: true" inside the <key>: block -> enabled, full stop.
  if awk -v key="$key" '
    $0 ~ "^" key ":[[:space:]]*$" { inblk = 1; next }
    inblk && /^[^[:space:]]/ { inblk = 0 }
    inblk && /enabled:[[:space:]]*true/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$file" 2>/dev/null; then
    return 0
  fi

  # Explicit "enabled: false" inside the <key>: block -> disabled, full
  # stop — an explicit false always wins over [default_enabled].
  if awk -v key="$key" '
    $0 ~ "^" key ":[[:space:]]*$" { inblk = 1; next }
    inblk && /^[^[:space:]]/ { inblk = 0 }
    inblk && /enabled:[[:space:]]*false/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$file" 2>/dev/null; then
    return 1
  fi

  # Key entirely absent from features.yaml -> fall back to the caller's
  # chosen default.
  [ "$default_enabled" = "false" ] && return 1 || return 0
}

# ------------------------------------------------------------------------------
# Public: premium_bin_present <bin_name>
#   Convenience one-liner for building a presence_check_cmd string.
# ------------------------------------------------------------------------------
premium_bin_present() {
  command -v "${1:-}" >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# Public: premium_hook_run <feature_key> <presence_check_cmd> <payload_cmd> [default_enabled]
#   See header for full semantics. This function NEVER returns non-zero.
# ------------------------------------------------------------------------------
premium_hook_run() {
  local feature_key="${1:-}"
  local presence_cmd="${2:-}"
  local payload_cmd="${3:-}"
  local default_enabled="${4:-true}"

  # Nothing to run -> trivially fine.
  [ -n "$feature_key" ] || return 0
  [ -n "$payload_cmd" ] || return 0

  # GATE 1: feature flag. Absent/disabled -> silent no-op, zero latency —
  # nothing below this line executes.
  premium_feature_enabled "$feature_key" "$default_enabled" || return 0

  # GATE 2: component presence, when the caller supplied a check. Run via
  # `eval` in a subshell — cheap, isolated from this shell's state, and
  # (unlike the payload below) still sees this lib's own helper functions
  # (e.g. premium_bin_present) since it's not a separate process.
  if [ -n "$presence_cmd" ]; then
    ( eval "$presence_cmd" ) >/dev/null 2>&1 || return 0
  fi

  # FAIL-SAFE EXECUTION: timeout-guarded child process. Prefer GNU `timeout`,
  # then macOS `gtimeout`; degrade to no wrapper if neither exists (the
  # payload still runs, just unbounded — rare, matches
  # reindex-on-session-start.sh's existing fallback).
  local timeout_secs to
  timeout_secs="${PREMIUM_HOOK_TIMEOUT_SECS:-25}"
  to=""
  if command -v timeout >/dev/null 2>&1; then
    to="timeout -k 2 ${timeout_secs}"
  elif command -v gtimeout >/dev/null 2>&1; then
    to="gtimeout -k 2 ${timeout_secs}"
  fi

  # Run in a NEW bash process so the timeout wrapper can actually kill it if
  # it hangs — a `timeout` around an `eval` in the current shell can't do
  # that. The payload string carries its own redirection (if any); this
  # function does not impose stdout/stderr handling of its own, so a
  # retrofitted hook can preserve its exact prior output shape verbatim.
  # shellcheck disable=SC2086
  $to bash -c "$payload_cmd" || true

  # ALWAYS 0 — a premium hook can never block or break its caller.
  return 0
}

# ------------------------------------------------------------------------------
# Public: premium_hook_probe <feature_key> <presence_check_cmd> <probe_cmd> [default_enabled]
#   See header for full semantics. Unlike premium_hook_run, this function's
#   return code IS the signal — 0 (reachable) / 1 (unreachable) /
#   2 (not applicable) — so callers can branch on it. It still never lets a
#   hanging probe run unbounded: same timeout-guarded child-process shape as
#   premium_hook_run, just with its own (shorter-by-default) timeout knob.
# ------------------------------------------------------------------------------
premium_hook_probe() {
  local feature_key="${1:-}"
  local presence_cmd="${2:-}"
  local probe_cmd="${3:-}"
  local default_enabled="${4:-true}"

  # Nothing to probe -> not applicable, same as premium_hook_run's "nothing
  # to run" early-out.
  [ -n "$feature_key" ] || return 2
  [ -n "$probe_cmd" ] || return 2

  # GATE 1: feature flag. Absent/disabled -> not applicable, zero latency.
  premium_feature_enabled "$feature_key" "$default_enabled" || return 2

  # GATE 2: component presence, when the caller supplied a check.
  if [ -n "$presence_cmd" ]; then
    ( eval "$presence_cmd" ) >/dev/null 2>&1 || return 2
  fi

  # LIVENESS CHECK: timeout-guarded child process, same fallback order as
  # premium_hook_run (GNU `timeout`, then macOS `gtimeout`, else unbounded).
  local timeout_secs to
  timeout_secs="${PREMIUM_HOOK_PROBE_TIMEOUT_SECS:-5}"
  to=""
  if command -v timeout >/dev/null 2>&1; then
    to="timeout -k 2 ${timeout_secs}"
  elif command -v gtimeout >/dev/null 2>&1; then
    to="gtimeout -k 2 ${timeout_secs}"
  fi

  # shellcheck disable=SC2086
  if $to bash -c "$probe_cmd"; then
    return 0
  fi
  return 1
}
