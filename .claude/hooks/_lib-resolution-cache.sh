#!/bin/bash
# _lib-resolution-cache.sh — session-scoped, CROSS-PROCESS cache for the
# resolutions _lib-read-config.sh and _lib-portfolio-paths.sh already
# memoise PER-PROCESS (me2resh/apexyard#1013 / AgDR-0120).
#
# ---------------------------------------------------------------------------
# Why this file exists — per-process vs cross-process
# ---------------------------------------------------------------------------
# _lib-read-config.sh (_CONFIG_CACHE, _CONFIG_ROOT_CACHE) and
# _lib-portfolio-paths.sh (_PORTFOLIO_ROOT_CACHE, _PORTFOLIO_*_CACHE) already
# memoise their answers WITHIN one hook's bash process — call the same
# resolver twice in the same script and the second call is a variable read.
# That memoisation does nothing across hooks, because the harness spawns a
# SEPARATE bash process per hook (48 of them can fire on a single Bash tool
# call, per the issue's own measurement). Every process starts with an empty
# per-process cache and redoes the same disk walk / jq parse / subshell
# chain that the process before it already did, 48 times, for 48 identical
# answers.
#
# This file adds the missing layer: a cache that survives ACROSS those
# process spawns, scoped to the current Claude Code session
# ($CLAUDE_CODE_SESSION_ID), consulted by the per-process caches' own
# cold-start path. A cold or invalidated session cache falls through to
# EXACTLY the pre-#1013 logic — this file only ever short-circuits work that
# would otherwise still happen; it never changes what gets computed.
#
# ---------------------------------------------------------------------------
# What gets cached here (and what deliberately does not)
# ---------------------------------------------------------------------------
#   - The merged project-config JSON (_lib-read-config.sh's _config_load).
#   - Each portfolio_* resolver's final absolute path
#     (_lib-portfolio-paths.sh's portfolio_registry, portfolio_workspace_dir,
#     etc.) via _portfolio_resolve_with_session_cache.
#
# Ops-root resolution is NOT duplicated here — `resolve_ops_root()` in
# _lib-ops-root.sh already has its own pin-first cross-process cache
# (me2resh/apexyard#381, the ops-root-<session> pin file), and this file
# reuses that SAME resolved value (and that SAME pin directory) as one of
# the two inputs to the fingerprint below, rather than re-deriving or
# re-caching it a second way. Two independently-maintained resolvers for
# the same fact is exactly the failure mode named in this issue's own
# "Related" section (apexyard-premium#537) — this file avoids adding a
# second one.
#
# Per-filter config_get() reads (e.g. `config_get '.tracker.kind'`) are also
# NOT cached here. Each config_get call still spawns its own `jq` against
# whatever JSON text it was handed — caching an unbounded set of caller
# jq filters would mean guessing which future filter strings are safe to
# trust from a stale-looking key, which is exactly the "clever cache that
# can go wrong" this design avoids. Caching the JSON BLOB those filters run
# against (this file's job) is the safe version of the same win: identical
# filter behaviour, minus redoing the disk read + jq merge that produced
# the blob.
#
# ---------------------------------------------------------------------------
# Staleness model — "correct-or-cold, never confidently-wrong"
# ---------------------------------------------------------------------------
# Every cached value here is a pure function of exactly two inputs:
#   1. .claude/project-config.defaults.json's (mtime, size)
#   2. .claude/project-config.json's (mtime, size), or the literal ABSENT
#      token when the file does not exist
#
# (A third input — "the resolved ops root" — was listed here and in
# AgDR-0120 through me2resh/apexyard#1013's initial landing, but was never
# actually wired: every call site derived it via a command substitution,
# so the value never survived into the frame that builds the fingerprint
# and it was always the empty string in production. Removed in the #1013
# follow-up (F2) rather than wired for real, because there is no genuine
# within-session ops-root-change threat for it to guard against —
# resolve_ops_root() (#381) already pins the root once per
# $CLAUDE_CODE_SESSION_ID, and every cache file this library writes is
# ALREADY scoped into its filename by that same session id. See
# _resolution_cache_config_fingerprint's own comment for the full
# writeup.)
#
# _resolution_cache_current_fingerprint() combines both into one opaque
# string. Every cache file stores its own fingerprint ALONGSIDE its value
# (fingerprint on line 1, value on the remaining line(s)) so each file is
# independently self-describing — a reader never has to trust that some
# OTHER file's fingerprint update implies this file is current too. On
# every read, the CURRENT fingerprint is recomputed fresh (two `stat`
# calls) and compared byte-for-byte; anything other than an exact match
# (missing file, mismatched fingerprint, unreadable stat) is treated as a
# miss, and the caller falls through to computing the value itself, exactly
# as it always has. This means a `.claude/project-config.json` edit mid-
# session — the scenario the issue calls out as "worse than the latency it
# saves" — invalidates every cache entry that depends on it on the very
# next read, never silently serving the pre-edit answer... PROVIDED the
# edit actually changes the fingerprint. It doesn't always:
#
# `stat`-reported mtimes are INTEGER-SECOND resolution on both GNU and
# BSD/macOS. A same-byte-size edit landing within the SAME wall-clock
# second as the value that got cached produces an IDENTICAL (mtime, size)
# signature — the read-side comparison above cannot tell the two edits
# apart, and would serve the pre-edit value with no way to detect it (a
# real, reproduced bug — me2resh/apexyard#1013 follow-up, F1). Read-side
# comparison alone cannot close this window; it can only compare what
# `stat` reports, and integer-second `stat` cannot distinguish the two
# states. The fix instead guards the WRITE: _resolution_cache_write and
# _resolution_cache_write_json both refuse to persist an entry while any
# fingerprint input file's mtime equals the CURRENT wall-clock second (see
# _resolution_cache_write_time_settled below) — a file touched THIS second
# might still be edited again before the second rolls over, so its
# signature is not yet trustworthy as a cache key. This is what makes
# "never confidently-wrong" true rather than aspirational: no cache entry
# is EVER written whose freshness a same-second, same-size edit could
# silently defeat.
#
# `stat` itself has two incompatible flavours (GNU vs BSD/macOS); when
# NEITHER succeeds, the fingerprint is the literal token UNKNOWN, and both
# the read and write paths refuse to trust or store anything under it —
# see _resolution_cache_file_sig and the UNKNOWN guards below. This is the
# "when in doubt, don't cache that value" rail from the issue, applied
# per-platform rather than per-value.
#
# ---------------------------------------------------------------------------
# Mechanism — a cache FILE, not exported env
# ---------------------------------------------------------------------------
# A SessionStart hook's exported env does not reliably reach the
# independently-spawned per-hook bash processes the harness invokes for
# PreToolUse/PostToolUse — each is its own process tree, not a child of the
# SessionStart hook's shell. A file under the session pin directory is the
# channel that already works for this exact problem (`pin-ops-root.sh` /
# `resolve_ops_root`'s pin), so this file reuses it rather than inventing a
# second channel.
#
# ---------------------------------------------------------------------------
# Fail-safe posture
# ---------------------------------------------------------------------------
#   - No CLAUDE_CODE_SESSION_ID (git hooks, CI, a bare `bash script.sh`
#     invocation) -> caching is a no-op; every read/write function returns 1
#     immediately. This is the same scoping resolve_ops_root() already uses
#     for its own pin, and it's why standalone git-hook installs (which run
#     these libs with no Claude Code session at all) are unaffected.
#   - APEXYARD_DISABLE_RESOLUTION_CACHE=1 -> same no-op, operator escape
#     hatch, independent of APEXYARD_OPS_DISABLE_PIN (which only affects the
#     ops-root pin, untouched by this file).
#   - Cache directory unwritable (read-only FS, sandbox) -> every write
#     silently returns 1 (stderr swallowed); callers already compute the
#     value BEFORE attempting to cache it, so a write failure never affects
#     the value returned, only whether the NEXT process gets to skip the
#     work this process just did.
#   - Any read miss, for any reason -> caller falls through to the existing
#     cold path, byte-for-byte the same code that ran before this file
#     existed.
#
# Sourced by _lib-read-config.sh and _lib-portfolio-paths.sh; never executed
# directly.

[ -n "${_LIB_RESOLUTION_CACHE_SOURCED:-}" ] && return 0
_LIB_RESOLUTION_CACHE_SOURCED=1

# ------------------------------------------------------------------------------
# _resolution_cache_enabled — is session-scoped caching usable right now?
# ------------------------------------------------------------------------------
_resolution_cache_enabled() {
  [ -z "${APEXYARD_DISABLE_RESOLUTION_CACHE:-}" ] || return 1
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || return 1
  return 0
}

# ------------------------------------------------------------------------------
# _resolution_cache_dir — same directory the ops-root pin already uses.
# ------------------------------------------------------------------------------
_resolution_cache_dir() {
  printf '%s' "${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}"
}

# ------------------------------------------------------------------------------
# _resolution_cache_file <name> — the on-disk path for one cache entry.
# <name> is always a hardcoded literal from this file family (never derived
# from tool input), so no path-safety validation is needed beyond what the
# existing ops-root-<session> pin filename already assumes.
# ------------------------------------------------------------------------------
_resolution_cache_file() {
  local name="$1"
  printf '%s/resolve-cache-%s-%s' "$(_resolution_cache_dir)" "${CLAUDE_CODE_SESSION_ID:-}" "$name"
}

# ------------------------------------------------------------------------------
# _resolution_cache_file_sig <file> — portable (mtime, size) signature.
#
# Echoes "ABSENT" when the file does not exist (distinguishes "file is
# missing" from "file has mtime 0", which cannot happen on a real
# filesystem but costs nothing to rule out explicitly). Echoes "UNKNOWN"
# when neither the GNU nor the BSD/macOS `stat` flavour succeeds — callers
# MUST treat UNKNOWN as "cannot verify freshness, never trust or write a
# cache under this fingerprint" (see _resolution_cache_config_fingerprint).
# ------------------------------------------------------------------------------
_resolution_cache_file_sig() {
  local f="$1"
  if [ ! -f "$f" ]; then
    printf 'ABSENT'
    return 0
  fi
  local out
  out=$(stat -c '%Y:%s' "$f" 2>/dev/null)
  if [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  out=$(stat -f '%m:%z' "$f" 2>/dev/null)
  if [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  printf 'UNKNOWN'
  return 0
}

# ------------------------------------------------------------------------------
# _resolution_cache_config_fingerprint <defaults_file> <overrides_file>
#   The one fingerprint shared by every cache entry in this file: the
#   merged config JSON and every portfolio_* resolved path are all pure
#   functions of these same two inputs. One shared signature means every
#   dependent cache entry invalidates together on either changing, rather
#   than each consumer growing its own slightly different staleness rule
#   that could disagree with the others.
#
#   NOTE (me2resh/apexyard#1013 follow-up, F2): this function used to take
#   a THIRD leading <root> argument ("the resolved ops root"). Every real
#   call site computed it via `root=$(_config_repo_root)` — a command
#   substitution — so whatever _config_repo_root() cached into
#   $_CONFIG_ROOT_CACHE lived only inside that forked subshell and was
#   never visible back in the calling frame. `root` was therefore ALWAYS
#   the empty string in production, on every call, producing a fingerprint
#   shaped like `|<defaults-sig>|<overrides-sig>` — a permanently dead
#   leading field, not a real input. Dropped rather than wired for real:
#   the ops root cannot actually change mid-session (resolve_ops_root(),
#   #381, pins it once per $CLAUDE_CODE_SESSION_ID), and every cache file
#   this library writes is ALREADY scoped into its filename by that same
#   session id (_resolution_cache_file) — so even a hypothetical root
#   change could never cause one session's cache to serve a different
#   root's answer. There was no genuine within-session ops-root-change
#   threat for the dead field to guard against.
#
#   Echoes "UNKNOWN" (never matches a real fingerprint, and
#   _resolution_cache_read / _resolution_cache_read_json both refuse to
#   treat "UNKNOWN" as a valid expected value) when either file's
#   signature cannot be determined.
# ------------------------------------------------------------------------------
_resolution_cache_config_fingerprint() {
  local defaults="$1" overrides="$2"
  local d_sig o_sig
  d_sig=$(_resolution_cache_file_sig "$defaults")
  o_sig=$(_resolution_cache_file_sig "$overrides")
  if [ "$d_sig" = "UNKNOWN" ] || [ "$o_sig" = "UNKNOWN" ]; then
    printf 'UNKNOWN'
    return 0
  fi
  printf '%s|%s' "$d_sig" "$o_sig"
}

# ------------------------------------------------------------------------------
# _resolution_cache_current_fingerprint
#   Convenience wrapper: resolves defaults/overrides paths via
#   _lib-read-config.sh's own functions (which this file expects to already
#   be sourced — see the header) and computes the fingerprint above. Both
#   _lib-read-config.sh and _lib-portfolio-paths.sh call this instead of
#   assembling the two inputs themselves, so there is exactly one place
#   that defines "what counts as the config having changed."
#
#   Echoes "UNKNOWN" (never a cache hit) if _config_defaults_file /
#   _config_overrides_file aren't available — e.g. this file was sourced
#   standalone, out of the expected order. Fails closed to "always
#   recompute," never to "guess."
# ------------------------------------------------------------------------------
_resolution_cache_current_fingerprint() {
  if ! command -v _config_defaults_file >/dev/null 2>&1 || ! command -v _config_overrides_file >/dev/null 2>&1; then
    printf 'UNKNOWN'
    return 0
  fi
  local defaults overrides
  defaults=$(_config_defaults_file)
  overrides=$(_config_overrides_file)
  _resolution_cache_config_fingerprint "$defaults" "$overrides"
}

# ------------------------------------------------------------------------------
# _resolution_cache_file_mtime_epoch <file>
#   Bare mtime, in epoch seconds, of an EXISTING file. Same two-flavour
#   (GNU / BSD-macOS) `stat` handling as _resolution_cache_file_sig, just
#   without the (mtime,size) pairing — callers here only need mtime, to
#   compare against "now" (see _resolution_cache_write_time_settled).
#   Echoes nothing and returns 1 when the file is absent or neither `stat`
#   flavour succeeds; callers treat that as "cannot determine," never as
#   "assume settled" or "assume unsettled."
# ------------------------------------------------------------------------------
_resolution_cache_file_mtime_epoch() {
  local f="$1"
  [ -f "$f" ] || return 1
  local out
  out=$(stat -c '%Y' "$f" 2>/dev/null)
  if [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  out=$(stat -f '%m' "$f" 2>/dev/null)
  if [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  return 1
}

# ------------------------------------------------------------------------------
# _resolution_cache_write_time_settled
#   WRITE-time-only guard closing the mtime-second stale-serve window
#   described in the "Staleness model" header comment above
#   (me2resh/apexyard#1013 follow-up, F1). Refuses to let a write proceed
#   while EITHER fingerprint input file (project-config.defaults.json,
#   project-config.json) has an mtime equal to the CURRENT wall-clock
#   second: a file touched THIS second might still be edited again,
#   same byte size, before the second rolls over, and integer-second
#   `stat` would never be able to tell the two states apart on a later
#   read. Forcing the write to wait one tick means the cache is only ever
#   populated once the file's signature has "settled" into a strictly-past
#   second — at which point ANY further edit necessarily changes the
#   mtime, and the existing read-side fingerprint mismatch (unchanged)
#   catches it exactly as documented above.
#
#   This is a WRITE-time guard only — reads are completely untouched. A
#   refused write is a silent no-op: the value the caller already computed
#   is still returned unchanged; only whether the NEXT process gets to
#   skip that work is affected. Same fail-safe shape as every other write
#   failure mode this file already tolerates (unwritable dir, disabled
#   cache, etc.) — see _resolution_cache_write / _resolution_cache_write_json.
#
#   Absent files are trivially settled: a file's own absent -> present
#   transition is already caught by the fingerprint's ABSENT -> real-sig
#   mismatch on the very next read (_resolution_cache_config_fingerprint)
#   — this guard closes only the narrower window where a file EXISTS and
#   was modified in the current second.
#
#   Fails CLOSED: if "now" itself can't be determined (`date +%s` fails on
#   some exotic platform), every write is treated as unsettled and
#   refused — same "when in doubt, don't cache" rail this file already
#   applies to an UNKNOWN fingerprint.
#
#   Only checks _config_defaults_file / _config_overrides_file when BOTH
#   are defined (mirrors _resolution_cache_current_fingerprint's own
#   graceful degrade for a standalone-sourced caller — e.g. this file's
#   own test suite exercising the low-level read/write functions directly
#   with synthetic fingerprints). Those two files are the ONLY inputs the
#   fingerprint is computed from, so there is nothing else to check.
# ------------------------------------------------------------------------------
_resolution_cache_write_time_settled() {
  command -v _config_defaults_file >/dev/null 2>&1 || return 0
  command -v _config_overrides_file >/dev/null 2>&1 || return 0

  local now
  now=$(date +%s 2>/dev/null)
  [ -n "$now" ] || return 1

  local defaults overrides f mt
  defaults=$(_config_defaults_file)
  overrides=$(_config_overrides_file)

  for f in "$defaults" "$overrides"; do
    [ -n "$f" ] || continue
    mt=$(_resolution_cache_file_mtime_epoch "$f") || continue
    if [ "$mt" = "$now" ]; then
      return 1
    fi
  done
  return 0
}

# ------------------------------------------------------------------------------
# _resolution_cache_write <name> <fingerprint> <value>
#   Atomically writes a SINGLE-LINE value (fingerprint on line 1, value on
#   line 2) via write-to-tmp + `mv` (atomic on the same filesystem, so a
#   concurrent reader never observes a partially-written file). <value>
#   must not itself contain a newline — every current caller passes an
#   absolute path, which cannot.
#
#   Never writes under fingerprint "UNKNOWN" — an unverifiable fingerprint
#   must never be trusted as a cache key by a future reader. Never writes
#   while a fingerprint input file is still mtime-second-unsettled either
#   — see _resolution_cache_write_time_settled (F1: the mtime-second
#   stale-serve guard).
#
#   Returns 1 (no-op, nothing written) on: caching disabled, unwritable
#   cache dir, mtime-second-unsettled input file, or any I/O failure.
#   Never surfaces an error to stdout — callers' stdout is the hook's/lib's
#   own return value and must stay clean regardless of cache-write success.
# ------------------------------------------------------------------------------
_resolution_cache_write() {
  local name="$1" fp="$2" value="$3"
  _resolution_cache_enabled || return 1
  [ "$fp" != "UNKNOWN" ] || return 1
  _resolution_cache_write_time_settled || return 1
  local dir file tmp
  dir=$(_resolution_cache_dir)
  file=$(_resolution_cache_file "$name")
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="${file}.tmp.$$"
  { printf '%s\n' "$fp"; printf '%s\n' "$value"; } >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# ------------------------------------------------------------------------------
# _resolution_cache_read <name> <expected_fingerprint>
#   Echoes the cached single-line value and returns 0 ONLY when the file
#   exists and its stored fingerprint matches <expected_fingerprint>
#   EXACTLY. Any other outcome (file absent, fingerprint mismatch,
#   fingerprint "UNKNOWN") returns 1 and echoes nothing — the caller's
#   existing cold path runs unchanged.
# ------------------------------------------------------------------------------
_resolution_cache_read() {
  local name="$1" expected_fp="$2"
  _resolution_cache_enabled || return 1
  [ -n "$expected_fp" ] && [ "$expected_fp" != "UNKNOWN" ] || return 1
  local file
  file=$(_resolution_cache_file "$name")
  [ -f "$file" ] || return 1
  local fp val
  { IFS= read -r fp; IFS= read -r val; } <"$file" 2>/dev/null
  [ -n "$fp" ] || return 1
  [ "$fp" = "$expected_fp" ] || return 1
  printf '%s' "$val"
  return 0
}

# ------------------------------------------------------------------------------
# _resolution_cache_write_json <fingerprint> <json>
#   Same contract as _resolution_cache_write (including the
#   mtime-second-unsettled write guard), specialised for the one
#   MULTI-line value this file caches: the merged project-config JSON.
#   Fingerprint on line 1; every remaining line is the value, verbatim.
# ------------------------------------------------------------------------------
_resolution_cache_write_json() {
  local fp="$1" json="$2"
  _resolution_cache_enabled || return 1
  [ "$fp" != "UNKNOWN" ] || return 1
  _resolution_cache_write_time_settled || return 1
  local dir file tmp
  dir=$(_resolution_cache_dir)
  file=$(_resolution_cache_file "config-json")
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="${file}.tmp.$$"
  {
    printf '%s\n' "$fp"
    printf '%s\n' "$json"
  } >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# ------------------------------------------------------------------------------
# _resolution_cache_read_json <expected_fingerprint>
#   Multi-line counterpart to _resolution_cache_read. Uses `tail -n +2`
#   (one small subprocess) rather than the pure-bash 2-line read, because
#   the value here can legitimately span many lines.
# ------------------------------------------------------------------------------
_resolution_cache_read_json() {
  local expected_fp="$1"
  _resolution_cache_enabled || return 1
  [ -n "$expected_fp" ] && [ "$expected_fp" != "UNKNOWN" ] || return 1
  local file
  file=$(_resolution_cache_file "config-json")
  [ -f "$file" ] || return 1
  local fp
  IFS= read -r fp <"$file" 2>/dev/null
  [ -n "$fp" ] || return 1
  [ "$fp" = "$expected_fp" ] || return 1
  tail -n +2 "$file" 2>/dev/null
  return 0
}

# ------------------------------------------------------------------------------
# _resolution_cache_clear_session [session_id]
#   Test/debug utility: removes every cache file for the given (or
#   current) session id. Not called by any hook in normal operation.
# ------------------------------------------------------------------------------
_resolution_cache_clear_session() {
  local sid="${1:-${CLAUDE_CODE_SESSION_ID:-}}"
  [ -n "$sid" ] || return 0
  local dir
  dir=$(_resolution_cache_dir)
  rm -f "$dir"/resolve-cache-"$sid"-* 2>/dev/null
  return 0
}
