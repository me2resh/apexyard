#!/usr/bin/env bash
# Path ownership library (me2resh/apexyard#1887).
#
# The manifest .claude/ownership-manifest.yaml says who owns each path that
# the framework ships: the framework, the adopter, or both (shared). The
# manifest header defines the format and the glob rules. The update engine,
# `apexyard update` (#1885) and `apexyard migrate` (#1886) call these entry
# points. Do not reimplement the glob match in a caller.
#
# Source this file. It changes no shell options and never calls exit.
#
# Manifest path: $OWNERSHIP_MANIFEST when it is set and not empty. Otherwise
# the manifest next to this library (<repo>/.claude/ownership-manifest.yaml).
#
# Entry points:
#   ownership_manifest_path
#       Print the manifest path. Return 0.
#   ownership_validate_manifest [file]
#       Check the manifest. Return 0 when it is valid. Return 2 when it is
#       missing or invalid, with each error and its line number on stderr.
#   ownership_classify_stream
#       Read repo-relative paths on stdin, one for each line. Print one line
#       for each path: <owner> TAB <true|false> TAB <path>. The owner is
#       framework, adopter, shared or unmatched. The second field is the
#       security flag. A leading "./" is removed and an empty line is
#       skipped. One awk process reads the full stream. Return 2, with no
#       stdout, when the manifest is missing or invalid.
#   ownership_class <path>
#       Print the owner and return 0. Return 1, with no output, when no glob
#       matches. Return 2 when the manifest is invalid, or when the path is
#       empty, absolute, or has a ".." segment.
#   ownership_is_security <path>
#       Print nothing. Return 0 when the matching rule has "security: true".
#       Return 1 when it is false or no glob matches. Return 2 on the same
#       errors as ownership_class.

ownership_manifest_path() {
  if [ -n "${OWNERSHIP_MANIFEST:-}" ]; then
    printf '%s\n' "$OWNERSHIP_MANIFEST"
  else
    printf '%s/../.claude/ownership-manifest.yaml\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
}

# Read the manifest before stdin. Do not emit paths until validation succeeds.
_ownership_awk() {
  local manifest="$1" mode="$2"
  if [ ! -r "$manifest" ] || [ ! -f "$manifest" ]; then
    printf '%s: line 1: Cannot read manifest.\n' "$manifest" >&2
    return 2
  fi
  OWNERSHIP_INPUT="$manifest" OWNERSHIP_MODE="$mode" awk '
  function error(message) {
    print file ": line " line ": " message > "/dev/stderr"
    bad = 1
  }
  function value(s,    q, i, rest) {
    sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
    q = substr(s, 1, 1)
    if (q == "\"" || q == "\047") {
      # A comment may follow the closing quote. Other text may not.
      i = index(substr(s, 2), q)
      rest = substr(s, i + 2)
      sub(/^[ \t]+/, "", rest)
      if (i == 0 || (rest != "" && rest !~ /^#/)) {
        error("Close the quoted value."); return ""
      }
      return substr(s, 2, i - 1)
    }
    sub(/[ \t]+#.*/, "", s); sub(/[ \t]+$/, "", s)
    return s
  }
  function finish() {
    if (entry && owner == "") error("Set an owner for the entry at line " start ".")
    if (entry) { owners[n] = owner; flags[n] = security }
  }
  function regex(g,    r,i,c) {
    r = "^"
    for (i = 1; i <= length(g); i++) {
      c = substr(g, i, 1)
      if (substr(g,i,4) == "/**/") { r = r "/(.*/)?"; i += 3 }
      else if (i == 1 && substr(g,i,3) == "**/") { r = r "(.*/)?"; i += 2 }
      else if (substr(g,i) == "/**") { r = r "/.+"; i += 2 }
      else if (substr(g,i,2) == "**") { r = r ".*"; i++ }
      else if (c == "*") r = r "[^/]*"
      else if (c == "?") r = r "[^/]"
      else {
        if (index(".+()|^${}[]\\", c)) r = r "\\"
        r = r c
      }
    }
    return r "$"
  }
  BEGIN {
    file = ENVIRON["OWNERSHIP_INPUT"]
    while ((status = getline text < file) > 0) {
      line++
      if (text ~ /^[ \t]*(#.*)?$/) continue
      if (text ~ /^version:/) {
        if (version++ || value(substr(text,9)) != "1") error("Use version 1 once.")
      } else if (text ~ /^paths:[ \t]*(#.*)?$/) {
        if (paths++) error("Use paths once.")
      } else if (text ~ /^[ \t]+- glob:/) {
        finish(); entry = 1; start = line; owner = ""; security = "false"
        seenowner = 0; seensecurity = 0
        s = text; sub(/^[ \t]+- glob:/,"",s); g = value(s)
        if (!paths || g == "") error("Set a glob under paths.")
        patterns[++n] = regex(g)
      } else if (text ~ /^[ \t]+owner:/ && entry) {
        s = text; sub(/^[ \t]+owner:/,"",s); owner = value(s)
        if (seenowner++ || (owner != "framework" && owner != "adopter" && owner != "shared")) error("Use a valid owner once.")
      } else if (text ~ /^[ \t]+security:/ && entry) {
        s = text; sub(/^[ \t]+security:/,"",s); security = value(s)
        if (seensecurity++ || (security != "true" && security != "false")) error("Use true or false once.")
      } else error("Use only version, paths, glob, owner, and security.")
    }
    close(file)
    if (!line) line = 1
    finish()
    if (status < 0) error("Cannot read manifest.")
    if (!version) error("Set version 1.")
    if (!paths) error("Set paths.")
    if (bad) exit 2
    if (ENVIRON["OWNERSHIP_MODE"] == "validate") exit 0
  }
  {
    path = $0
    while (sub(/^\.\//,"",path)) {}
    if (path == "") next
    owner = "unmatched"; security = "false"
    for (i = 1; i <= n; i++) {
      if (path ~ patterns[i]) { owner = owners[i]; security = flags[i]; break }
    }
    printf "%s\t%s\t%s\n", owner, security, path
  }'
}

ownership_validate_manifest() {
  _ownership_awk "${1:-$(ownership_manifest_path)}" validate
}

ownership_classify_stream() {
  _ownership_awk "$(ownership_manifest_path)" classify
}

_ownership_path_result() {
  local path="${1:-}"
  while [ "${path#./}" != "$path" ]; do path=${path#./}; done
  case "$path" in
    ''|/*|..|../*|*/../*|*/..)
      printf 'Invalid repo-relative path: %s\n' "$path" >&2
      return 2 ;;
  esac
  printf '%s\n' "$path" | ownership_classify_stream
}

ownership_class() {
  local result
  result=$(_ownership_path_result "${1:-}") || return 2
  case "$result" in unmatched$'\t'*) return 1 ;; esac
  printf '%s\n' "${result%%$'\t'*}"
}

ownership_is_security() {
  local result
  result=$(_ownership_path_result "${1:-}") || return 2
  case "$result" in *$'\t'true$'\t'*) return 0 ;; *) return 1 ;; esac
}
