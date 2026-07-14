#!/usr/bin/env bash
# SessionStart hook: validate the apexyard-search MCP config and warn LOUDLY
# when it's broken — closes the "silent rot" failure mode described in
# apexyard-premium#514.
#
# THE BUG THIS FIXES: `.mcp.json` bakes in absolute roots
# (APEXYARD_OPS_ROOT / APEXYARD_PORTFOLIO_ROOT) and a `command` that can be
# a bare binary name resolved against a pipx venv at install time. Neither
# self-corrects when a repo moves, gets renamed, or is cloned onto a new
# machine — the MCP server then fails to launch, every search silently
# returns nothing, and nobody notices for weeks.
#
# SAFE SHAPE (mirrors reindex-on-session-start.sh / check-upstream-drift.sh):
# this hook NEVER blocks session start and ALWAYS exits 0. It is fully
# read-only by default — see "SCOPE" below on why auto-rewrite is opt-in.
#
# THE INTENT GATE (the load-bearing design constraint from the #514 review
# comment — see the ticket before touching this file):
#
#   The LOUD path (validate / warn) fires ONLY when there is EVIDENCE the
#   operator INTENDS to use search:
#     - an "apexyard-search" entry exists in .mcp.json, OR
#     - features.yaml has `vector_index: { enabled: true }`
#
#   Absent BOTH -> silent `exit 0`, zero output, no file reads beyond the
#   two candidate files, no file writes ever. This is the non-premium /
#   unconfigured case and MUST stay completely quiet — it's what every
#   framework adopter (not just apexyard-premium subscribers) sees at
#   every session start, so it also has to be fast and side-effect-free.
#
#   This is deliberately NOT `command -v apexyard-search` (on-PATH). That
#   guard conflates two different situations into the same silent no-op:
#     - not installed              -> non-premium, correct silent no-op
#     - installed, bare command
#       not resolvable on PATH     -> premium, BROKEN (exactly the #514 case)
#   Gating on intent-evidence instead of on-PATH resolution is what makes
#   the broken-but-premium case impossible to miss while keeping the free
#   experience silent.
#
# SCOPE (read-only by default): this hook runs at SessionStart for every
# adopter of the framework, not just the reporter of #514. Auto-rewriting
# a user's `.mcp.json` on their behalf is the one failure mode that could
# make things WORSE than silent rot — a bad rewrite could mangle other,
# unrelated MCP server entries in the same file, or write wrong paths on a
# layout this hook mis-detects. So the default (and the only behaviour
# shipped in this PR) is DETECT + WARN LOUDLY with an actionable message —
# zero mutation risk. Auto-heal exists ONLY behind an explicit opt-in
# (`APEXYARD_SEARCH_SELFHEAL=1`), and even then it backs up the file,
# touches only the "apexyard-search" entry, and validates the rewritten
# JSON round-trips before replacing the original. See "AUTO-HEAL" below.
#
# ONCE INTENT-EVIDENCE IS PRESENT, this hook validates the existing
# "apexyard-search" .mcp.json entry (or, if features.yaml wants search but
# no entry exists at all, warns that nothing is wired up):
#   a. is `command` actually launchable? (absolute + executable, OR
#      bare + resolvable on PATH, OR bare + found in the well-known pipx
#      venv `$HOME/.local/pipx/venvs/apexyard-premium/bin/<name>`)
#   b. do APEXYARD_OPS_ROOT / APEXYARD_PORTFOLIO_ROOT point at
#      directories that actually exist?
# If both check out: silent exit 0 (healthy, common case). If either is
# broken: LOUD, actionable stderr message naming the exact fix — never a
# silent no-op once intent-evidence says search should work.
#
# AUTO-HEAL (opt-in, off by default): set APEXYARD_SEARCH_SELFHEAL=1 to let
# this hook rewrite the broken fields in `.mcp.json` itself, using roots
# resolved dynamically from the same ops-fork/portfolio anchors every other
# hook uses (_lib-ops-root.sh / _lib-portfolio-paths.sh). Even then:
#   - a timestamped backup of the whole file is written first
#   - only the "apexyard-search" entry's `command` / `env.*` fields change
#   - the rewritten file is validated (valid JSON + the entry still has the
#     expected shape) before it replaces the original; any validation
#     failure discards the rewrite and falls through to the warn path
#     with the original file untouched.
#
# Tunables (env):
#   APEXYARD_SEARCH_VALIDATE_DISABLE   non-empty -> skip entirely (operator kill-switch)
#   APEXYARD_SEARCH_SELFHEAL           1 -> opt in to the backed-up, validated auto-heal
#
# Performance note: every check here is local filesystem stats + jq/awk on
# small files — no network calls, no invocation of apexyard-search itself,
# nothing that can hang. No timeout wrapper needed (contrast
# reindex-on-session-start.sh, which DOES wrap a real CLI invocation).
#
# See: me2resh/apexyard-premium#514.

set -u

# Operator kill-switch.
if [ -n "${APEXYARD_SEARCH_VALIDATE_DISABLE:-}" ]; then
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

# -----------------------------------------------------------------------
# Resolve the ops-fork root the same way every other hook does (pin-first,
# walk-up fallback). This is ALSO one of the two dynamic roots we'd heal
# APEXYARD_OPS_ROOT to (auto-heal path only) and quote in the warn message.
# -----------------------------------------------------------------------
OPS_ROOT=""
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-ops-root.sh"
  OPS_ROOT=$(resolve_ops_root "$PWD")
fi
if [ -z "$OPS_ROOT" ]; then
  # Fall back to this hook's own fork location — still correct even if the
  # walk-up resolver couldn't run (e.g. lib missing on an old checkout).
  OPS_ROOT="$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd)"
fi
[ -n "$OPS_ROOT" ] && [ -d "$OPS_ROOT" ] || exit 0

# -----------------------------------------------------------------------
# Resolve the portfolio root — the directory that holds the registry
# (apexyard.projects.yaml). In single-fork mode this IS the ops root; in
# split-portfolio v2 mode it's the sibling private repo
# (../<fork>-portfolio). features.yaml and .mcp.json both conventionally
# live next to the registry, so this is also where we look for them.
# -----------------------------------------------------------------------
PORTFOLIO_ROOT=""
if [ -f "$HOOK_DIR/_lib-read-config.sh" ] && [ -f "$HOOK_DIR/_lib-portfolio-paths.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-read-config.sh"
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-portfolio-paths.sh"
  _registry=$(portfolio_registry 2>/dev/null)
  if [ -n "$_registry" ]; then
    PORTFOLIO_ROOT=$(cd "$(dirname "$_registry")" 2>/dev/null && pwd)
  fi
fi
[ -n "$PORTFOLIO_ROOT" ] && [ -d "$PORTFOLIO_ROOT" ] || PORTFOLIO_ROOT="$OPS_ROOT"

# -----------------------------------------------------------------------
# Locate an existing "apexyard-search" entry in .mcp.json, checking every
# plausible location (ops root, portfolio root, and an explicit
# $APEXYARD_PORTFOLIO_ROOT env override if the operator's shell sets one).
# Pure string grep — no jq dependency for INTENT DETECTION, so this branch
# works even on a box that doesn't have jq installed.
# -----------------------------------------------------------------------
MCP_JSON=""
for _candidate in "$OPS_ROOT/.mcp.json" "$PORTFOLIO_ROOT/.mcp.json" "${APEXYARD_PORTFOLIO_ROOT:-}/.mcp.json"; do
  [ -n "$_candidate" ] && [ -f "$_candidate" ] || continue
  if grep -q '"apexyard-search"' "$_candidate" 2>/dev/null; then
    MCP_JSON="$_candidate"
    break
  fi
done

# -----------------------------------------------------------------------
# Locate features.yaml and check for vector_index.enabled: true — scoped
# to the vector_index: block only (not a blanket "enabled: true" grep,
# which would false-positive on every other feature flag in the file).
# -----------------------------------------------------------------------
FEATURES_YAML=""
for _candidate in "$PORTFOLIO_ROOT/features.yaml" "$OPS_ROOT/features.yaml" "${APEXYARD_PORTFOLIO_ROOT:-}/features.yaml"; do
  [ -n "$_candidate" ] && [ -f "$_candidate" ] || continue
  FEATURES_YAML="$_candidate"
  break
done

_vector_index_enabled() {
  local f="$1"
  [ -n "$f" ] && [ -f "$f" ] || return 1
  awk '
    /^vector_index:[[:space:]]*$/ { inblk=1; next }
    inblk && /^[^[:space:]]/ { inblk=0 }
    inblk && /enabled:[[:space:]]*true/ { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$f" 2>/dev/null
}

FEATURES_WANT_SEARCH=false
if _vector_index_enabled "$FEATURES_YAML"; then
  FEATURES_WANT_SEARCH=true
fi

# -----------------------------------------------------------------------
# THE INTENT GATE. No evidence of intent -> silent, zero-output, exit 0.
# This is the load-bearing acceptance criterion (#514): free / unconfigured
# adopters must see NOTHING from this hook, ever.
# -----------------------------------------------------------------------
if [ -z "$MCP_JSON" ] && ! $FEATURES_WANT_SEARCH; then
  exit 0
fi

# Intent from features.yaml but no .mcp.json entry to validate at all —
# nothing to inspect, so this is a loud warn, not a silent no-op.
if [ -z "$MCP_JSON" ]; then
  {
    echo "ApexYard: features.yaml has vector_index.enabled: true (in $FEATURES_YAML)"
    echo "  but no \"apexyard-search\" entry was found in .mcp.json (checked:"
    echo "  $OPS_ROOT/.mcp.json, $PORTFOLIO_ROOT/.mcp.json)."
    echo "  Search is configured ON but not wired up — install/configure the"
    echo "  apexyard-search MCP server (run: apexyard-premium doctor), or set"
    echo "  vector_index.enabled: false if you don't intend to use it."
  } >&2
  exit 0
fi

# -----------------------------------------------------------------------
# We have a real "apexyard-search" entry to validate. Read its command +
# roots. Prefer jq (structured, robust); fall back to a best-effort grep
# for read-only diagnosis when jq isn't installed.
# -----------------------------------------------------------------------
HAVE_JQ=false
command -v jq >/dev/null 2>&1 && HAVE_JQ=true

if $HAVE_JQ; then
  CUR_CMD=$(jq -r '.mcpServers["apexyard-search"].command // empty' "$MCP_JSON" 2>/dev/null)
  CUR_OPS_ENV=$(jq -r '.mcpServers["apexyard-search"].env.APEXYARD_OPS_ROOT // empty' "$MCP_JSON" 2>/dev/null)
  CUR_PORTFOLIO_ENV=$(jq -r '.mcpServers["apexyard-search"].env.APEXYARD_PORTFOLIO_ROOT // empty' "$MCP_JSON" 2>/dev/null)
else
  _blk=$(awk '/"apexyard-search"/{f=1} f{print} f && /\}/{c++} c>1{exit}' "$MCP_JSON" 2>/dev/null)
  CUR_CMD=$(printf '%s\n' "$_blk" | grep '"command"' | head -1 | sed -E 's/.*"command"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
  CUR_OPS_ENV=$(printf '%s\n' "$_blk" | grep '"APEXYARD_OPS_ROOT"' | head -1 | sed -E 's/.*"APEXYARD_OPS_ROOT"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
  CUR_PORTFOLIO_ENV=$(printf '%s\n' "$_blk" | grep '"APEXYARD_PORTFOLIO_ROOT"' | head -1 | sed -E 's/.*"APEXYARD_PORTFOLIO_ROOT"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
fi

# Is a command string actually launchable right now?
_cmd_launchable() {
  local c="$1"
  [ -n "$c" ] || return 1
  case "$c" in
    /*) [ -x "$c" ] ;;
    *) command -v "$c" >/dev/null 2>&1 ;;
  esac
}

need_cmd_heal=false
_cmd_launchable "$CUR_CMD" || need_cmd_heal=true

need_ops_heal=false
{ [ -n "$CUR_OPS_ENV" ] && [ -d "$CUR_OPS_ENV" ]; } || need_ops_heal=true

need_portfolio_heal=false
{ [ -n "$CUR_PORTFOLIO_ENV" ] && [ -d "$CUR_PORTFOLIO_ENV" ]; } || need_portfolio_heal=true

# Nothing broken -> healthy, silent.
if ! $need_cmd_heal && ! $need_ops_heal && ! $need_portfolio_heal; then
  exit 0
fi

# -----------------------------------------------------------------------
# Something is broken. If the command needs fixing, try to find a
# launchable binary so the warn message (and, if opted in, the heal) can
# name a concrete replacement: basename off PATH, then the well-known
# pipx venv layout (apexyard-premium#504 installs there; existing
# .mcp.json files predate that fix and don't self-update).
# -----------------------------------------------------------------------
RESOLVED_CMD="$CUR_CMD"
if $need_cmd_heal; then
  RESOLVED_CMD=""
  _bin_name="apexyard-search"
  case "$CUR_CMD" in
    */*) _bin_name=$(basename "$CUR_CMD") ;;
    "") : ;;
    *) _bin_name="$CUR_CMD" ;;
  esac

  if command -v "$_bin_name" >/dev/null 2>&1; then
    RESOLVED_CMD=$(command -v "$_bin_name")
  else
    for _venv in "$HOME/.local/pipx/venvs/apexyard-premium" "$HOME/.local/pipx/venvs/$_bin_name"; do
      if [ -x "$_venv/bin/$_bin_name" ]; then
        RESOLVED_CMD="$_venv/bin/$_bin_name"
        break
      fi
    done
  fi
fi

# -----------------------------------------------------------------------
# AUTO-HEAL — strictly opt-in (APEXYARD_SEARCH_SELFHEAL=1), OFF by default.
# Backs up the whole file first, rewrites only the apexyard-search entry,
# and validates the result before replacing the original. Any failure at
# any step discards the attempt (original file left untouched) and falls
# through to the read-only warn below.
# -----------------------------------------------------------------------
HEALED=false
if [ "${APEXYARD_SEARCH_SELFHEAL:-}" = "1" ] && $HAVE_JQ; then
  _can_heal=true
  if $need_cmd_heal && [ -z "$RESOLVED_CMD" ]; then
    _can_heal=false
  fi

  if $_can_heal; then
    NEW_CMD="$CUR_CMD"
    $need_cmd_heal && NEW_CMD="$RESOLVED_CMD"

    _backup="${MCP_JSON}.bak.$(date +%s 2>/dev/null || echo 0)"
    if cp "$MCP_JSON" "$_backup" 2>/dev/null; then
      TMP="$(mktemp "${MCP_JSON}.XXXXXX" 2>/dev/null)" || TMP=""
      if [ -n "$TMP" ] && jq \
          --arg cmd "$NEW_CMD" \
          --arg ops "$OPS_ROOT" \
          --arg pf "$PORTFOLIO_ROOT" \
          '.mcpServers["apexyard-search"].command = $cmd
           | .mcpServers["apexyard-search"].env.APEXYARD_OPS_ROOT = $ops
           | .mcpServers["apexyard-search"].env.APEXYARD_PORTFOLIO_ROOT = $pf' \
          "$MCP_JSON" > "$TMP" 2>/dev/null; then
        # Validate: still parses AND the entry still has the expected shape
        # (round-trip check) before trusting it over the original.
        if jq -e '.mcpServers["apexyard-search"].command | type == "string"' "$TMP" >/dev/null 2>&1; then
          mv "$TMP" "$MCP_JSON"
          HEALED=true
          {
            echo "ApexYard: apexyard-search config self-healed in $MCP_JSON (backup at $_backup)"
            $need_cmd_heal && echo "  - command: '$CUR_CMD' -> '$NEW_CMD' (resolved to a launchable absolute path)"
            $need_ops_heal && echo "  - APEXYARD_OPS_ROOT: '$CUR_OPS_ENV' -> '$OPS_ROOT'"
            $need_portfolio_heal && echo "  - APEXYARD_PORTFOLIO_ROOT: '$CUR_PORTFOLIO_ENV' -> '$PORTFOLIO_ROOT'"
          } >&2
        else
          rm -f "$TMP"
        fi
      else
        [ -n "$TMP" ] && rm -f "$TMP"
      fi
    fi
  fi
fi

$HEALED && exit 0

# -----------------------------------------------------------------------
# Read-only path (the default): broken and not auto-healed. Fail LOUDLY
# with an actionable, concrete fix — this is the case #514 exists to make
# impossible to miss. Never a silent no-op once intent-evidence says
# search should work.
# -----------------------------------------------------------------------
{
  echo "ApexYard: apexyard-search MCP config looks BROKEN (in $MCP_JSON):"
  if $need_cmd_heal; then
    if [ -n "$RESOLVED_CMD" ]; then
      echo "  - command '$CUR_CMD' is not launchable (not an executable absolute path, not on"
      echo "    PATH). Found a launchable binary at: $RESOLVED_CMD"
    else
      echo "  - command '$CUR_CMD' is not launchable: not an executable absolute path, not on"
      echo "    PATH, and not found under \$HOME/.local/pipx/venvs/apexyard-premium/bin/"
    fi
  fi
  if $need_ops_heal; then
    echo "  - APEXYARD_OPS_ROOT ('$CUR_OPS_ENV') does not exist. Current ops root: $OPS_ROOT"
  fi
  if $need_portfolio_heal; then
    echo "  - APEXYARD_PORTFOLIO_ROOT ('$CUR_PORTFOLIO_ENV') does not exist. Current portfolio root: $PORTFOLIO_ROOT"
  fi
  echo "  Fix: run 'apexyard-premium doctor' to diagnose/repair, or edit $MCP_JSON by hand:"
  echo "    command -> ${RESOLVED_CMD:-<absolute path to the apexyard-search binary>}"
  echo "    env.APEXYARD_OPS_ROOT -> $OPS_ROOT"
  echo "    env.APEXYARD_PORTFOLIO_ROOT -> $PORTFOLIO_ROOT"
  echo "  (Set APEXYARD_SEARCH_SELFHEAL=1 to let ApexYard auto-correct this on next"
  echo "   session start — it backs up $MCP_JSON first and only touches this entry.)"
} >&2

exit 0
