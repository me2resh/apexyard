#!/bin/bash
# Session exemption paths. See AgDR-0250 and #1532.
[ -n "${_LIB_SESSION_MARKERS_SOURCED:-}" ] && return 0
_LIB_SESSION_MARKERS_SOURCED=1

# Migration release only: report each old marker once, but never trust it.
# mkdir makes the notice claim atomic across concurrent hooks.
session_marker_legacy_notice() {
  local home="$1" name="$2" base
  base="$home/.claude/session/$name"
  if [ -f "$base" ] && mkdir "$base.restart-notice" 2>/dev/null; then
    echo "ApexYard: ignored legacy $name marker. Run the skill again. Restart only if the loaded skill text is outdated." >&2
  fi
  return 0
}

# Use the active_reviewer_marker_path suffix and sanitization convention.
# Missing identity returns no path: exemption gates must stay closed.
_session_exemption_marker_path() {
  local name="$1" home="${2:-.}" sid="${3:-${CLAUDE_CODE_SESSION_ID:-${APEXYARD_SESSION_ID:-}}}" safe_sid
  session_marker_legacy_notice "$home" "$name"
  [ -n "$sid" ] || return 1
  safe_sid=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' '_')
  printf '%s/.claude/session/%s.%s' "$home" "$name" "$safe_sid"
}

active_bootstrap_marker_path() {
  _session_exemption_marker_path active-bootstrap "${1:-.}" "${2:-${CLAUDE_CODE_SESSION_ID:-${APEXYARD_SESSION_ID:-}}}"
}

active_issue_skill_marker_path() {
  _session_exemption_marker_path active-issue-skill "${1:-.}" "${2:-${CLAUDE_CODE_SESSION_ID:-${APEXYARD_SESSION_ID:-}}}"
}
