#!/bin/bash
# _lib-leak-remote-visibility.sh — classify a Git remote as confirmed-private
# or must-scan for leak protection (me2resh/apexyard#1528 / AgDR-0220).
#
# The leak risk is content leaving for a public repository. A remote is
# confirmed private only when a fresh cache or a live lookup reports
# private=true. Everything else — public-class slugs, unknown, error, no
# gh, timeout, non-GitHub hosts — means SCAN (fail closed).
#
# Public-class (never skipped):
#   - leak_protection.public_framework_repos (or the shipped default)
#   - the local `upstream` remote slug
#   - any registry entry with public: true
#
# Cache (local git config; subsection key so any owner/name is a valid key):
#   apexyard-leak.<owner>/<name>.state = "<state> <epoch>"
#   state private|public: fresh for 24 h.
#   state unknown (a failed lookup): fresh for 10 min, so an offline or
#   hanging lookup does not repeat on every commit. unknown means SCAN.
#
# TEST-ONLY overrides (never set in production):
#   APEXYARD_LEAK_TEST_MODE=1 — required to honour any command override below.
#     Without it, APEXYARD_LEAK_VISIBILITY_CMD is ignored (real `gh` is used).
#   APEXYARD_LEAK_VISIBILITY_CMD — command invoked as
#     $APEXYARD_LEAK_VISIBILITY_CMD <owner/name>
#   Must print `true` (private) or `false` (public) on stdout and exit 0.
#   Any other result is a failed lookup → SCAN. Used only by hook tests
#   with a stub; production uses `gh api repos/<slug> --jq .private`.
#   Answers from this override are NEVER written to the visibility cache
#   (even in test mode). Cache tests plant entries directly.
#   APEXYARD_LEAK_VISIBILITY_TIMEOUT — lookup timeout seconds (tests only).
#     Shortening it only fails closed (SCAN); it cannot skip the scan.
#   APEXYARD_LEAK_FORCE_WATCHDOG — forces the bash-native timeout path;
#     does not change the verdict.

# shellcheck disable=SC2034  # sourced library; callers use the functions

_LEAK_VISIBILITY_TTL_SECONDS=86400
_LEAK_VISIBILITY_NEG_TTL_SECONDS=600
_LEAK_VISIBILITY_GH_TIMEOUT_SECONDS=5

# Logical URL of a named remote: the configured remote.<name>.url, read raw
# so a url.<base>.insteadOf rewrite (a mirror, a local transport) does not
# hide the GitHub slug the operator named. Falls back to `git remote get-url`.
leak_remote_url() {
  local name="$1" url
  url=$(git config --get "remote.${name}.url" 2>/dev/null || true)
  [ -n "$url" ] || url=$(git remote get-url "$name" 2>/dev/null || true)
  printf '%s' "$url"
}

# Normalise a remote URL to lowercase owner/name. Only github.com is
# recognised, and the host is anchored: https/http/git/ssh URLs (optional
# userinfo and port), and scp-style git@github.com:owner/name. A trailing
# slash and a .git suffix are optional. Every other input (another host, a
# host that only contains github.com, a bare owner/name, a local path)
# yields an empty string.
leak_normalize_github_slug() {
  local raw="$1" m
  raw=$(printf '%s' "$raw" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  raw=${raw%/}
  raw=${raw%.git}
  raw=${raw%/}
  m=$(printf '%s\n' "$raw" | LC_ALL=C sed -nE \
    -e 's#^(https?|git|ssh)://([^/@]+@)?github\.com(:[0-9]+)?/([a-z0-9._-]+/[a-z0-9._-]+)$#\4#p' \
    -e 's#^([^/@:]+@)?github\.com:([a-z0-9._-]+/[a-z0-9._-]+)$#\2#p')
  # Only the first line, and exactly one owner/name.
  m=${m%%$'\n'*}
  case "$m" in
    */*/*|'') printf '' ;;
    *) printf '%s' "$m" ;;
  esac
}

_leak_visibility_cache_name() {
  printf 'apexyard-leak.%s.state' "$1"
}

_leak_visibility_cache_get() {
  # Prints private|public|unknown when a fresh cache entry exists; else fails.
  local slug="$1" val state epoch now age ttl
  val=$(git config --local --get "$(_leak_visibility_cache_name "$slug")" 2>/dev/null || true)
  [ -n "$val" ] || return 1
  state=${val%% *}
  epoch=${val#* }
  case "$state" in
    private|public) ttl=$_LEAK_VISIBILITY_TTL_SECONDS ;;
    unknown) ttl=$_LEAK_VISIBILITY_NEG_TTL_SECONDS ;;
    *) return 1 ;;
  esac
  case "$epoch" in ''|0*|*[!0-9]*) return 1 ;; esac
  [ "${#epoch}" -le 12 ] || return 1
  now=$(date +%s 2>/dev/null) || return 1
  age=$((now - epoch))
  if [ "$age" -lt 0 ] || [ "$age" -ge "$ttl" ]; then
    return 1
  fi
  printf '%s\n' "$state"
  return 0
}

_leak_visibility_cache_set() {
  local slug="$1" state="$2" now
  now=$(date +%s 2>/dev/null) || return 1
  git config --local "$(_leak_visibility_cache_name "$slug")" "${state} ${now}" 2>/dev/null || true
}

# Run a command with a time limit and print its stdout. Uses timeout or
# gtimeout when present; otherwise a bash-native watchdog. Returns the
# command's status, or non-zero when it was killed.
# APEXYARD_LEAK_FORCE_WATCHDOG=1 forces the watchdog (tests only).
_leak_run_limited() {
  local secs="$1" out_f pid wd rc
  shift
  if [ -z "${APEXYARD_LEAK_FORCE_WATCHDOG:-}" ]; then
    if command -v timeout >/dev/null 2>&1; then
      timeout -k 1 "$secs" "$@" 2>/dev/null
      return $?
    elif command -v gtimeout >/dev/null 2>&1; then
      gtimeout -k 1 "$secs" "$@" 2>/dev/null
      return $?
    fi
  fi
  out_f=$(mktemp -t leak-vis.XXXXXX) || return 1
  "$@" >"$out_f" 2>/dev/null &
  pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid" 2>/dev/null
  rc=$?
  kill "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  cat "$out_f"
  rm -f "$out_f"
  return "$rc"
}

# Live visibility lookup. Prints "private" or "public" on success; exit 1 on failure.
_leak_visibility_lookup() {
  local slug="$1" out rc secs
  secs="$_LEAK_VISIBILITY_GH_TIMEOUT_SECONDS"
  # APEXYARD_LEAK_VISIBILITY_TIMEOUT: seconds override, used by tests only.
  case "${APEXYARD_LEAK_VISIBILITY_TIMEOUT:-}" in
    ''|*[!0-9]*) ;;
    *) secs="$APEXYARD_LEAK_VISIBILITY_TIMEOUT" ;;
  esac

  # Honour the command override only when APEXYARD_LEAK_TEST_MODE=1.
  # Without the flag, ignore the override silently and use real `gh`.
  if [ "${APEXYARD_LEAK_TEST_MODE:-}" = "1" ] \
    && [ -n "${APEXYARD_LEAK_VISIBILITY_CMD:-}" ]; then
    # TEST ONLY — see file header. Word-splitting the command is intended.
    # shellcheck disable=SC2086
    out=$(_leak_run_limited "$secs" $APEXYARD_LEAK_VISIBILITY_CMD "$slug")
  else
    command -v gh >/dev/null 2>&1 || return 1
    out=$(_leak_run_limited "$secs" gh api "repos/${slug}" --jq .private)
  fi
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  out=$(printf '%s' "$out" | tr -d '[:space:]')
  case "$out" in
    true) printf 'private\n'; return 0 ;;
    false) printf 'public\n'; return 0 ;;
    *) return 1 ;;
  esac
}

# True when the live lookup would use APEXYARD_LEAK_VISIBILITY_CMD (test mode).
# Override answers must not be written to the visibility cache.
_leak_visibility_lookup_uses_override() {
  [ "${APEXYARD_LEAK_TEST_MODE:-}" = "1" ] \
    && [ -n "${APEXYARD_LEAK_VISIBILITY_CMD:-}" ]
}

# Return 0 when slug is public-class (must always scan).
_leak_slug_is_public_class() {
  local slug="$1" known upstream_url upstream_slug registry entry repo
  local hook_dir root configured resolved current_public line

  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  hook_dir="$root/.claude/hooks"

  known="me2resh/apexyard"
  if [ -f "$hook_dir/_lib-read-config.sh" ]; then
    # shellcheck source=/dev/null
    . "$hook_dir/_lib-read-config.sh"
    configured=$(config_get '.leak_protection.public_framework_repos[]' 2>/dev/null || true)
    [ -n "$configured" ] && known="$configured"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    line=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    [ "$line" = "$slug" ] && return 0
  done <<EOF
$known
EOF

  upstream_url=$(leak_remote_url upstream)
  if [ -n "$upstream_url" ]; then
    upstream_slug=$(leak_normalize_github_slug "$upstream_url")
    [ -n "$upstream_slug" ] && [ "$upstream_slug" = "$slug" ] && return 0
  fi

  registry="$root/apexyard.projects.yaml"
  if [ -f "$hook_dir/_lib-portfolio-paths.sh" ]; then
    # shellcheck source=/dev/null
    . "$hook_dir/_lib-portfolio-paths.sh"
    resolved=$(portfolio_registry 2>/dev/null || true)
    [ -n "$resolved" ] && registry="$resolved"
  fi
  if [ -f "$registry" ] && [ -f "$hook_dir/_lib-registry-parser.sh" ]; then
    # shellcheck source=/dev/null
    . "$hook_dir/_lib-registry-parser.sh"
    if declare -F registry_parse_entries >/dev/null 2>&1; then
      entry=$(registry_parse_entries "$registry" 2>/dev/null || true)
      current_public=0
      while IFS= read -r line; do
        case "$line" in
          PUBLIC=*) current_public=${line#PUBLIC=} ;;
          REPO=*)
            if [ "$current_public" = "1" ]; then
              repo=$(printf '%s' "${line#REPO=}" | tr '[:upper:]' '[:lower:]')
              [ "$repo" = "$slug" ] && return 0
            fi
            ;;
        esac
      done <<EOF
$entry
EOF
    fi
  fi
  return 1
}

# Return 0 when the remote is confirmed private (scan may be skipped).
# Return 1 when the scan must run (public-class, unknown, error, non-GitHub).
leak_remote_is_confirmed_private() {
  local url_or_slug="$1" slug cached looked
  slug=$(leak_normalize_github_slug "$url_or_slug")
  if [ -z "$slug" ]; then
    return 1
  fi
  if _leak_slug_is_public_class "$slug"; then
    return 1
  fi
  cached=$(_leak_visibility_cache_get "$slug" 2>/dev/null || true)
  case "$cached" in
    private) return 0 ;;
    public|unknown) return 1 ;;
  esac
  looked=$(_leak_visibility_lookup "$slug" 2>/dev/null || true)
  case "$looked" in
    private)
      # Never cache an answer that came from the test-only command override.
      if ! _leak_visibility_lookup_uses_override; then
        _leak_visibility_cache_set "$slug" "private"
      fi
      return 0
      ;;
    public)
      if ! _leak_visibility_lookup_uses_override; then
        _leak_visibility_cache_set "$slug" "public"
      fi
      return 1
      ;;
    *)
      if ! _leak_visibility_lookup_uses_override; then
        _leak_visibility_cache_set "$slug" "unknown"
      fi
      return 1
      ;;
  esac
}
