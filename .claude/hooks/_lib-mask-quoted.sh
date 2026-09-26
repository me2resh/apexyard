#!/bin/bash
# _lib-mask-quoted.sh — mask shell metacharacters that sit INSIDE quotes.
#
# Not a hook itself (prefixed `_lib-`). Sourced by callers that need to tell a
# real shell operator from the same character used as literal data.
#
# WHY THIS EXISTS (me2resh/apexyard#1356)
# ---------------------------------------------------------------------------
# `_lib-detect-bash-write.sh` matches a regular expression against the raw
# command text. It runs no quoting step. Bash treats `>` inside single quotes
# as a literal character. The matcher treats it as a redirect operator. So a
# read-only command reports a write, and the diagnostic names a target the
# command never writes:
#
#   git log --format='%h > %s'          reported target: %s
#   echo '  >> ZERO MATCHES'            reported target: ZERO
#   awk '{ if (c && NR > 1) exit }' f   reported target: 1)
#
# THIS FILE IS DIAGNOSIS-ONLY. READ THIS BEFORE WIRING IT INTO A GATE.
# ---------------------------------------------------------------------------
# AgDR-0113 governs this class of helper. Its options table names this exact
# approach ("Strip heredoc bodies (and quoted strings) before matching") and
# then sets the rule that keeps it safe:
#
#   > `strip_heredoc_bodies` is a subtractive pre-filter on gate input — it
#   > decides what a caller is even ALLOWED to see. A bug here produces no
#   > question being asked at all, silently and fail-open across every
#   > consumer simultaneously.
#
# So this helper MUST NOT feed a gate's presence question — the boolean that
# decides whether a hook looks at a command at all. Today that means it must
# not feed `bash_command_appears_to_write`. Three hooks read that function
# (`require-active-ticket.sh`, `require-migration-ticket.sh`,
# `warn-review-marker-write.sh`), so one state-machine bug here would fail
# OPEN across all three at once. AgDR-0113 records eight shapes where the
# heredoc stripper did exactly that.
#
# It is safe for ADDITIVE questions: which target did the operator name, and
# should the diagnostic explain that the match came from quoted text. A bug in
# an additive answer yields a worse message, never a skipped gate.
#
# UNCERTAINTY FALLS BACK TO THE RAW COMMAND
# ---------------------------------------------------------------------------
# `mask_quoted_metachars` returns the command UNCHANGED whenever it cannot be
# confident about quote state:
#
#   - quotes are unbalanced when the scan ends
#   - the command holds a heredoc operator (`<<`), whose body bash does not
#     quote-process but this scanner would
#   - the command holds a backtick, which nests a fresh quoting context
#   - the command holds a `#` at a comment position, because bash does not
#     quote-process a comment body but this scanner would. A comment
#     position is the start of the command, or a place after whitespace or
#     after one of `; & | ( ) < >`.
#   - a double-quoted span holds `$(`. Bash starts a fresh quoting context
#     inside a command substitution, so a `>` there is a real redirect. This
#     scanner would still count it as quoted.
#
# Each fallback preserves the caller's current behaviour.
#
# SCOPE OF THAT CLAIM — read it before adopting this helper elsewhere.
# The five guards above cover five KNOWN divergences between this scanner and
# bash. They are not a proof that no divergence remains. A shape that makes
# the scanner treat a REAL operator as quoted, and that no guard catches,
# would hide that character from a caller.
#
# Known residue, recorded rather than claimed away. AgDR-0171 records it. The
# first of AgDR-0113's two closing rules requires it: cite the test, or write
# the claim as residue.
#
#   - `$'...'` ANSI-C quoting. Bash processes backslash escapes inside it and
#     this scanner does not. Every variant tried so far left quotes
#     unbalanced and hit guard 1. It is PROBED, not proven safe.
#   - Review found the last two guards, not the original author. The first
#     review found the comment shape after whitespace. A second review found
#     the comment shape after an operator, and the `"$( )"` shape. Treat the
#     guard list as a living list.
#
# Each entry is pinned by a case in `tests/test_mask_quoted.sh` where one
# exists, and named here where one does not.
#
# OFFSETS AND LENGTH ARE PRESERVED
# ---------------------------------------------------------------------------
# Masking substitutes one byte for one byte, so a masked string indexes the
# same as the raw string. A quoted write target keeps working: for
# `echo x > "out.txt"` nothing inside the quotes is a metacharacter, and for
# `echo x > "a>b"` the extracted target round-trips through
# `unmask_quoted_metachars` back to `a>b`.
#
# Exposed functions:
#   mask_quoted_metachars COMMAND
#       echoes COMMAND with `>`, `<`, `|`, `&`, `;` replaced by placeholder
#       bytes wherever they sit inside a single- or double-quoted span.
#       Echoes COMMAND unchanged when any uncertainty guard above trips.
#
#   unmask_quoted_metachars TEXT
#       reverses the substitution. Apply it to any value extracted from masked
#       text before showing it to a human or comparing it with raw text.

# Placeholder bytes. Chosen from the C0 control range, which does not appear in
# real command text. Each metacharacter gets a DISTINCT placeholder so the
# substitution round-trips exactly.
#   >  ->  \021    <  ->  \022    |  ->  \023    &  ->  \024    ;  ->  \025

# ------------------------------------------------------------------------------
# Public: mask_quoted_metachars COMMAND
# ------------------------------------------------------------------------------
mask_quoted_metachars() {
  local cmd="${1-}"
  [ -z "$cmd" ] && return 0

  # Uncertainty guards. Any hit returns the raw command, so the caller sees
  # exactly what it sees today.
  case "$cmd" in
    *'<<'*) printf '%s' "$cmd"; return 0 ;;
    *'`'*)  printf '%s' "$cmd"; return 0 ;;
  esac

  # A `#` at a comment position opens a bash comment, and bash does NOT
  # process quote characters inside one. This scanner would. An odd number of
  # quotes inside a comment, rebalanced later, therefore leaves the scanner
  # in a quoted state across a REAL redirect while bash is not — and the
  # balance check at the end of the scan cannot see it. Bail instead of
  # modelling comments, which would add a second divergence to fix the first.
  #
  # A comment starts where a word starts. A word starts at the start of the
  # command, after whitespace, or after an operator character. A `#` anywhere
  # else is an ordinary character, so `awk '/^## D/ ...'` is unaffected. The
  # guard also trips on a `#` inside a quoted span after a space. That costs
  # nothing, because a trip only returns the raw command.
  local comment_re='(^|[[:space:];&|()<>])#'
  if [[ $cmd =~ $comment_re ]]; then
    printf '%s' "$cmd"; return 0
  fi

  # The command travels through the environment rather than `-v`, so arbitrary
  # backslashes and newlines survive unmangled.
  MASKQ_CMD="$cmd" awk '
    function mask(c) {
      if (c == ">") return M_GT
      if (c == "<") return M_LT
      if (c == "|") return M_PIPE
      if (c == "&") return M_AMP
      if (c == ";") return M_SEMI
      return c
    }
    BEGIN {
      SQ     = sprintf("%c", 39)   # single quote, spelled by code to avoid
                                   # nesting a quote inside this program
      DQ     = sprintf("%c", 34)   # double quote
      BS     = sprintf("%c", 92)   # backslash
      M_GT   = sprintf("%c", 17)
      M_LT   = sprintf("%c", 18)
      M_PIPE = sprintf("%c", 19)
      M_AMP  = sprintf("%c", 20)
      M_SEMI = sprintf("%c", 21)

      s = ENVIRON["MASKQ_CMD"]
      n = length(s)
      state = 0                    # 0 outside, 1 single-quoted, 2 double-quoted
      out = ""

      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)

        if (state == 0) {
          # Outside quotes a backslash escapes the next character, so that
          # character cannot open a quoted span.
          if (c == BS) {
            out = out c
            i++
            if (i <= n) out = out substr(s, i, 1)
            continue
          }
          if (c == SQ) { state = 1; out = out c; continue }
          if (c == DQ) { state = 2; out = out c; continue }
          out = out c
          continue
        }

        if (state == 1) {
          # Inside single quotes nothing is special except the closing quote.
          # A backslash is literal here, matching bash.
          if (c == SQ) { state = 0; out = out c; continue }
          out = out mask(c)
          continue
        }

        # state == 2, inside double quotes. A `$(` opens a command
        # substitution, and bash parses its body in a fresh quoting context.
        # This scanner does not model that, so hand back the raw command.
        # This also covers `$((`, where a `>` is a comparison, not a redirect.
        if (c == "$" && substr(s, i + 1, 1) == "(") { printf "%s", s; exit }

        # A backslash still escapes, so the escaped character cannot close
        # the span.
        if (c == BS) {
          out = out c
          i++
          if (i <= n) out = out mask(substr(s, i, 1))
          continue
        }
        if (c == DQ) { state = 0; out = out c; continue }
        out = out mask(c)
      }

      # Unbalanced quotes mean the scan lost track. Hand back the raw command.
      if (state != 0) { printf "%s", s; exit }

      printf "%s", out
    }
  '
}

# ------------------------------------------------------------------------------
# Public: unmask_quoted_metachars TEXT
# ------------------------------------------------------------------------------
unmask_quoted_metachars() {
  local t="${1-}"
  [ -z "$t" ] && return 0
  # `tr`, not `${t//.../&}`. Bash gives `&` a special meaning in the
  # replacement half of a pattern substitution, so the ampersand placeholder
  # did not round-trip. `tr` maps byte to byte with no such rule.
  printf '%s' "$t" | tr '\021\022\023\024\025' '><|&;'
}
