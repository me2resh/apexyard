#!/bin/bash
# _lib-flag-value.sh — quoted flag value from a raw command string.
#
# Not a hook (prefixed `_lib-`). Sourced by:
#   validate-issue-structure.sh
#   require-agdr-for-arch-pr.sh
#   block-private-refs-in-public-repos.sh
#   require-orbit-slice-for-ticket.sh
#
#   . "$(dirname "$0")/_lib-flag-value.sh"
#
# Matches (possibly multi-line):
#   --title "value with spaces"
#   --title 'value'
#   --title value
#
# The four copies this file replaced were not the same program. Two knobs
# preserve each caller's previous result:
#
#   trim ($3)
#     sub  — leftmost sub() cut. Default. Used by the issue-structure,
#            AgDR, and ORBIT hooks.
#     last — cut at the last delimiter. Leak DETECTION. A superset can
#            only over-block (me2resh/apexyard#1046).
#     first — earliest qualifying cut. Skip-marker check only. A subset
#            is fail-closed for an allow decision.
#   anchor ($4)
#     double — the next flag must be `--<letter>`. Default. AgDR and the
#            leak hook. Widening this reopened #227 (me2resh/apexyard#1040).
#     either — one dash or two (`-F` and `--field`). Issue-structure and
#            ORBIT, so `--title "[Feature] F" -F body=@file` keeps the
#            title (me2resh/apexyard#695).
#
# Quoted values are greedy and stop on the chosen flag boundary or
# end-of-string. The earlier `[^"]*` form truncated at the first embedded
# quote (me2resh/apexyard#227). A path flag is a different parser
# (`extract_path_flag` in the two hooks that read `--body-file`). Do not
# widen this anchor to accept shell operators.
#
# INVARIANT: a caller that ALLOWS or bypasses on the extracted text must
# pass trim `first`. Detection callers pass `last`. The default `sub` is
# the older content trim, not the leak-detection trim. A new allow-path
# caller that omits $3 does not get the detection superset.

extract_flag_value() {
  # $1 = flag regex (for example --title|-t). $2 = command text.
  local flag_re="$1"
  local cmd="$2"
  local mode="${3:-sub}"
  local anchor_re="--"
  case "${4:-double}" in
    either) anchor_re='--?' ;;
  esac
  # `--?` is one dash plus an optional second dash. It matches the same
  # flags as `-{1,2}` and does not depend on ERE interval support.
  printf '%s' "$cmd" | awk -v FLAG_RE="$flag_re" -v SQ="'" -v MODE="$mode" -v MATCH_ANCHOR="$anchor_re" '
    # Truncate CHUNK at its LAST occurrence of delimiter D.
    #
    # A regex sub() cannot do this (me2resh/apexyard#1046). POSIX ERE
    # substitution is leftmost-longest, so
    #   sub("\"([[:space:]]+--[a-zA-Z].*)?$", "", chunk)
    # cut at the EARLIEST quote that was followed by ` --<letter>` and
    # dropped the rest. A body with an embedded quote and, later, any
    # double-dash token was amputated there. The tail went unscanned.
    #
    # match() already anchored the region on the real closing delimiter.
    # The only text after it is the boundary or trailing space, and
    # neither contains the delimiter. The last D in CHUNK is that closer.
    function trim_to_last(chunk, d,    i) {
      for (i = length(chunk); i >= 1; i--) {
        if (substr(chunk, i, 1) == d) return substr(chunk, 1, i - 1)
      }
      return chunk
    }
    # SCOPE ASYMMETRY (me2resh/apexyard#1046).
    #
    # A SUPERSET is fail-closed for leak detection and fail-OPEN for the
    # skip marker: `--body "<private>" --label "<marker>"` blocked before
    # the superset trim and bypassed after it. Detection uses "last".
    # The marker check uses "first", the old earliest cut, which is a
    # subset.
    #
    # The "first" cut keys on `--?`, not `--`. `-l` is `--label`. Keying
    # the cut on a double dash left the short spelling open.
    #
    # `--?` and not `-{1,2}`: `{n,m}` is an ERE interval and awk support
    # for it is not universal. Where it is unsupported the pattern is
    # literal, the cut fires only at end-of-chunk, and this branch
    # degrades toward the superset. Smaller is fail-closed for the marker
    # consumer. Leak detection never uses this branch.
    function trim_cut(chunk, d, anch) {
      sub(d "([[:space:]]+" anch "[a-zA-Z].*)?$", "", chunk)
      sub(d "[[:space:]]*$", "", chunk)
      return chunk
    }
    function trim_mode(chunk, d,    anch) {
      if (MODE == "last") return trim_to_last(chunk, d)
      anch = MATCH_ANCHOR
      if (MODE == "first") anch = "--?"
      return trim_cut(chunk, d, anch)
    }
    { buf = (NR == 1 ? $0 : buf "\n" $0) }
    END {
      s = buf
      re = "(" FLAG_RE ")[[:space:]]+\"(.*)\"([[:space:]]+" MATCH_ANCHOR "[a-zA-Z]|[[:space:]]*$)"
      if (match(s, re)) {
        chunk = substr(s, RSTART, RLENGTH)
        sub("^(" FLAG_RE ")[[:space:]]+\"", "", chunk)
        print trim_mode(chunk, "\"")
        exit
      }
      re = "(" FLAG_RE ")[[:space:]]+" SQ "(.*)" SQ "([[:space:]]+" MATCH_ANCHOR "[a-zA-Z]|[[:space:]]*$)"
      if (match(s, re)) {
        chunk = substr(s, RSTART, RLENGTH)
        sub("^(" FLAG_RE ")[[:space:]]+" SQ, "", chunk)
        print trim_mode(chunk, SQ)
        exit
      }
      re = "(" FLAG_RE ")[[:space:]]+[^[:space:]]+"
      if (match(s, re)) {
        chunk = substr(s, RSTART, RLENGTH)
        sub("^(" FLAG_RE ")[[:space:]]+", "", chunk)
        print chunk
        exit
      }
    }
  '
}
