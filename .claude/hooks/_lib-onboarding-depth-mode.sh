#!/bin/bash
# _lib-onboarding-depth-mode.sh — shared helpers for the onboarding depth-mode
# session marker (.claude/session/onboarding-depth-mode ∈ {terse, guided}).
#
# Ticket: me2resh/apexyard#914 (increment-2 M6 — depth adaptivity: terse vs
# guided + override + transparency). Technical design:
# docs/technical-designs/onboarding-increment-2.md § D2/D7.
#
# THE SIGNAL VS THE MODE — two distinct things (design § D2). Increment 1
# captured `.claude/session/onboarding-tech-level` ∈ {engineer, non-engineer,
# ambiguous} — the *inference input*. This lib owns the separate, effective
# *rendering setting* the adopter can flip: `.claude/session/
# onboarding-depth-mode` ∈ {terse, guided}. This lib never writes the
# tech-level signal file — only reads it as a one-time derivation input.
#
# Functions (sourced; do not exec this file directly):
#   depth_mode_marker_path()
#       Echoes the resolved marker path for the current ops root. Empty
#       string if there's no git toplevel at all.
#   depth_mode_read()
#       Echoes the current depth mode: terse | guided.
#       SAFE DEFAULT (D2/D7): an absent, unreadable, or unrecognised
#       marker echoes "terse" — never blocks, never guesses guided. This
#       is what makes the #913/#914 parallel build correctness-safe: even
#       if #913's asides land before this ticket's mode-writer, an unset
#       marker renders terse (zero asides).
#   depth_mode_write(mode)
#       Writes "terse" or "guided" to the marker. Rejects any other value
#       (prints to stderr, returns 1, no write) — the marker must only
#       ever hold one of the two canonical values.
#   depth_mode_derive_from_signal(signal)
#       Pure mapping, no I/O: engineer->terse, non-engineer->guided.
#       Anything else (ambiguous / empty / unrecognised) prints nothing
#       and returns 1 — the caller must ask a fresh low-friction question
#       (inc-1 D5) rather than silently defaulting to guided.
#   depth_mode_classify_override(phrase)
#       Pure mapping, no I/O: classifies a plain-language phrase against
#       the two override families named in design § D2 and echoes
#       terse | guided | "" (no match). Case-insensitive substring match.
#   depth_mode_report()
#       Echoes the FR-9 transparency sentence for the CURRENT marker
#       value (reads via depth_mode_read — default terse). Read-only.
#
# CONTRACT (the "presentation only" invariant): this lib touches ONLY the
# depth-mode marker file. It never reads or writes anything under
# `.claude/session/reviews/`, never touches a `*-rex.approved` /
# `*-ceo.approved` / `*-security.approved` / `*-architecture.approved`
# marker, and never edits a gate, permission, or role-boundary file. See
# `.claude/hooks/tests/test_depth_mode.sh`'s invariant case — the
# mechanical guard for design § "Depth mode is presentation only".

# Don't run twice in the same shell.
[ -n "${_LIB_ONBOARDING_DEPTH_MODE_SOURCED:-}" ] && return 0
_LIB_ONBOARDING_DEPTH_MODE_SOURCED=1

_DEPTH_MODE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$_DEPTH_MODE_LIB_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$_DEPTH_MODE_LIB_DIR/_lib-ops-root.sh"
fi

depth_mode_marker_path() {
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
  echo "$root/.claude/session/onboarding-depth-mode"
  return 0
}

depth_mode_read() {
  local marker value
  marker=$(depth_mode_marker_path)
  if [ -n "$marker" ] && [ -f "$marker" ]; then
    value=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    case "$value" in
      terse|guided)
        echo "$value"
        return 0
        ;;
    esac
  fi
  # Safe default (D2 / D7): absent, unreadable, or unrecognised -> terse.
  echo "terse"
  return 0
}

depth_mode_write() {
  local mode="$1" marker
  case "$mode" in
    terse|guided) ;;
    *)
      echo "depth_mode_write: invalid mode '$mode' (must be terse|guided) — refusing to write" >&2
      return 1
      ;;
  esac
  marker=$(depth_mode_marker_path)
  if [ -z "$marker" ]; then
    echo "depth_mode_write: could not resolve marker path (no git toplevel)" >&2
    return 1
  fi
  mkdir -p "$(dirname "$marker")"
  printf '%s' "$mode" > "$marker"
  return 0
}

depth_mode_derive_from_signal() {
  local signal="$1"
  case "$signal" in
    engineer)
      echo "terse"
      return 0
      ;;
    non-engineer)
      echo "guided"
      return 0
      ;;
    *)
      # ambiguous / empty / unrecognised — caller must ask, not guess.
      return 1
      ;;
  esac
}

depth_mode_classify_override() {
  local phrase="$1" lower
  lower=$(printf '%s' "$phrase" | tr '[:upper:]' '[:lower:]')

  case "$lower" in
    *"explain more"*|*"explain things more"*|*"explain it more"*|*"i don't know these terms"*|*"i dont know these terms"*)
      echo "guided"
      return 0
      ;;
  esac

  case "$lower" in
    *"skip the explanations"*|*"skip explanations"*|*"be terse"*|*"i know this already"*|*"i already know this"*)
      echo "terse"
      return 0
      ;;
  esac

  echo ""
  return 0
}

depth_mode_report() {
  local mode
  mode=$(depth_mode_read)
  if [ "$mode" = "guided" ]; then
    echo "Guided — I explain terms in plain language as they come up. Say \"be terse\" to switch."
  else
    echo "Terse — I skip the plain-language explanations. Say \"explain more\" to switch to guided."
  fi
  return 0
}
