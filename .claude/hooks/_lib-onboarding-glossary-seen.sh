#!/bin/bash
# _lib-onboarding-glossary-seen.sh — shared helpers for the onboarding
# just-in-time glossary asides: the per-session seen-set marker
# (.claude/session/onboarding-glossary-seen) and the glossary.md term
# lookup the asides slice content from.
#
# Ticket: me2resh/apexyard#913 (increment-2 M5 — teach-in-context glossary
# + just-in-time asides). Technical design:
# docs/technical-designs/onboarding-increment-2.md § D1/D3/D7.
#
# THIS LIB IS GATED ON, NOT RESPONSIBLE FOR, DEPTH MODE. #914's
# _lib-onboarding-depth-mode.sh owns the .claude/session/onboarding-depth-mode
# marker (derivation, override, transparency). This lib only READS that
# marker (via depth_mode_read) to decide whether an aside should fire at
# all — it never writes it. D7's safe default (absent marker -> terse ->
# depth_mode_read echoes "terse") makes this correctness-safe regardless
# of whether #914's writer has run yet in a given session.
#
# Functions (sourced; do not exec this file directly):
#   glossary_seen_marker_path()
#       Echoes the resolved seen-set marker path for the current ops
#       root. Empty string if there's no git toplevel at all. Same
#       ops-root resolution as _lib-onboarding-depth-mode.sh (pin-first,
#       walk-up fallback, via _lib-ops-root.sh when present).
#   glossary_seen_has(term_key)
#       Returns 0 (true) if term_key is already present in the seen-set
#       marker (newline-delimited term keys), 1 otherwise. A missing or
#       empty marker always returns 1 (nothing seen yet).
#   glossary_seen_add(term_key)
#       Appends term_key to the seen-set marker, creating it if absent.
#       Idempotent: a no-op if the key is already present (never writes a
#       duplicate line). Refuses (prints to stderr, returns 1, no write)
#       an empty term_key.
#   glossary_term_body(term_key)
#       Pure read, no session-marker I/O: slices ONE term's plain-language
#       definition out of docs/onboarding/glossary.md by its `<!-- term:
#       ... -->` key-comment (D1's read contract — comma-separated
#       surface spellings resolve to one entry, e.g. "issue" and "ticket"
#       both hit the same section). Echoes the definition paragraph
#       (trimmed, blank lines collapsed, the "**Example**:" line and
#       anything after it excluded — asides are a short parenthetical,
#       not the full entry). Echoes nothing and returns 1 if the term
#       isn't found or the asset is missing. Resolved relative to the git
#       toplevel — glossary.md is tracked framework content living in the
#       SAME repo as this lib, not per-fork session state, so it needs no
#       ops-root indirection the way the two session markers do.
#   glossary_maybe_aside(term_key)
#       The full D3 firing algorithm, composed:
#         1. Gate on mode first (reads .claude/session/onboarding-depth-mode
#            via #914's depth_mode_read). Not "guided" -> echo nothing,
#            return 1, seen-set untouched. This is what makes terse mode's
#            "zero asides" structural rather than a formatting choice.
#         2. Seen-set check -- key already present -> echo nothing,
#            return 1 (term already glossed this session).
#         3. Slice the term's body via glossary_term_body. Empty/unknown
#            term -> echo nothing, return 1, seen-set untouched.
#         4. Record the key in the seen-set, echo the sliced body, return
#            0. The caller (the agent, in-flow) composes this into ONE
#            short inline parenthetical the first time it uses the term
#            toward the adopter -- this function supplies gating +
#            source content, never inline prose formatting.
#
# CONTRACT (the "presentation only" invariant, same as #914's lib): this
# lib touches ONLY the glossary-seen marker file and reads (never writes)
# the depth-mode marker + docs/onboarding/glossary.md. It never reads or
# writes anything under `.claude/session/reviews/`, never touches a
# `*-rex.approved` / `*-ceo.approved` / `*-security.approved` /
# `*-architecture.approved` marker, and never edits a gate, permission, or
# role-boundary file. See `.claude/hooks/tests/test_glossary_asides.sh`'s
# invariant case.

# Don't run twice in the same shell.
[ -n "${_LIB_ONBOARDING_GLOSSARY_SEEN_SOURCED:-}" ] && return 0
_LIB_ONBOARDING_GLOSSARY_SEEN_SOURCED=1

_GLOSSARY_SEEN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$_GLOSSARY_SEEN_LIB_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$_GLOSSARY_SEEN_LIB_DIR/_lib-ops-root.sh"
fi

if [ -f "$_GLOSSARY_SEEN_LIB_DIR/_lib-onboarding-depth-mode.sh" ]; then
  # shellcheck source=/dev/null
  . "$_GLOSSARY_SEEN_LIB_DIR/_lib-onboarding-depth-mode.sh"
fi

glossary_seen_marker_path() {
  local repo_root root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$repo_root" ]; then
    echo ""
    return 0
  fi
  root="$repo_root"
  if command -v resolve_ops_root >/dev/null 2>&1; then
    root=$(resolve_ops_root "$repo_root")
    [ -n "$root" ] || root="$repo_root"
  fi
  echo "$root/.claude/session/onboarding-glossary-seen"
  return 0
}

glossary_seen_has() {
  local term_key="$1" marker
  [ -n "$term_key" ] || return 1
  marker=$(glossary_seen_marker_path)
  [ -n "$marker" ] && [ -f "$marker" ] || return 1
  grep -qxF "$term_key" "$marker" 2>/dev/null
}

glossary_seen_add() {
  local term_key="$1" marker
  if [ -z "$term_key" ]; then
    echo "glossary_seen_add: refusing to add an empty term key" >&2
    return 1
  fi
  marker=$(glossary_seen_marker_path)
  if [ -z "$marker" ]; then
    echo "glossary_seen_add: could not resolve marker path (no git toplevel)" >&2
    return 1
  fi
  if glossary_seen_has "$term_key"; then
    return 0
  fi
  mkdir -p "$(dirname "$marker")"
  printf '%s\n' "$term_key" >> "$marker"
  return 0
}

glossary_term_body() {
  local term_key="$1" asset
  [ -n "$term_key" ] || return 1

  asset="docs/onboarding/glossary.md"
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/$asset" ]; then
    asset="$CLAUDE_PROJECT_DIR/$asset"
  elif ! [ -f "$asset" ]; then
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
    [ -n "$repo_root" ] && [ -f "$repo_root/$asset" ] && asset="$repo_root/$asset"
  fi
  [ -f "$asset" ] || return 1

  local body
  body=$(awk -v key="$term_key" '
    /^<!-- term: /{
      line = $0
      sub(/^<!-- term: /, "", line)
      sub(/ *-->$/, "", line)
      n = split(line, keys, ",")
      match_found = 0
      for (i = 1; i <= n; i++) {
        k = keys[i]
        gsub(/^[ \t]+|[ \t]+$/, "", k)
        if (k == key) { match_found = 1 }
      }
      capture = match_found
      next
    }
    capture && /^\*\*Example\*\*:/ { capture = 0; next }
    capture && /^#/ { capture = 0; next }
    capture && /^---/ { capture = 0; next }
    capture { buf = buf $0 "\n" }
    END { printf "%s", buf }
  ' "$asset")

  # Trim leading/trailing blank lines and collapse internal newlines to
  # single spaces, so the caller gets one clean sentence-block, not a
  # multi-line blob with markdown line-wrap artifacts.
  body=$(printf '%s' "$body" | awk 'NF{$1=$1; print}' | tr '\n' ' ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

  [ -n "$body" ] || return 1
  printf '%s' "$body"
  return 0
}

glossary_maybe_aside() {
  local term_key="$1" mode body
  [ -n "$term_key" ] || return 1

  mode="terse"
  if command -v depth_mode_read >/dev/null 2>&1; then
    mode=$(depth_mode_read)
  fi
  [ "$mode" = "guided" ] || return 1

  if glossary_seen_has "$term_key"; then
    return 1
  fi

  body=$(glossary_term_body "$term_key") || return 1
  [ -n "$body" ] || return 1

  glossary_seen_add "$term_key" || return 1
  printf '%s' "$body"
  return 0
}
