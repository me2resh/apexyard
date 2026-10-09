#!/bin/bash
# Shared streaming awk path. Caller programs consume an appended 0x1c byte.
# Remove only the final output marker, preserving identical bytes in input.
# Fallback functions receive the original input and any remaining arguments.
# Callers choose the locale, preserving each existing scanner's character rules.
_run_awk_or_fallback() {
  local input="$1" fallback="$2" program="$3" output sentinel=$'\034'
  shift 3
  program="$program"$'\n''END { printf "\034" }'
  if output=$(printf '%s\034' "$input" | awk "$program" 2>/dev/null); then
    case "$output" in
      *"$sentinel") printf '%s' "${output%"$sentinel"}"; return 0 ;;
    esac
  fi
  "$fallback" "$input" "$@"
}

# Bash removes continuations outside single quotes and comments.
# broad-space retains older gate scans, including quoted and commented pairs.
join_shell_continuations() {
  local mode="${2:-bash}" broad_space=0
  [ "$mode" = broad-space ] && broad_space=1
  LC_ALL=C _run_awk_or_fallback "$1" "${3:-_join_shell_continuations_fallback}" '

    BEGIN {
      broad_space = '"$broad_space"'
      sq = sprintf("%c", 39)
      dq = sprintf("%c", 34)
      in_sq = 0
      in_dq = 0
    }
    function is_word_boundary_prev(prev) {
      # Bash starts a comment when `#` begins a token (start / whitespace /
      # shell metacharacters), not when it sits inside a word like `foo#bar`.
      return prev == "" || prev == " " || prev == "\t" || \
             prev == ";" || prev == "|" || prev == "&" || \
             prev == "(" || prev == ")" || prev == "<" || prev == ">" || \
             prev == "`" || prev == "\n"
    }
    function emit(line,    i, n, c, out, bs, prev, in_comment) {
      if (broad_space) {
        if (sub(/\\$/, " ", line)) printf "%s", line
        else printf "%s\n", line
        return
      }
      n = length(line); out = ""; bs = 0; prev = ""; in_comment = 0
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (in_comment) {
          out = out c
          bs = 0
          prev = c
          continue
        }
        if (in_sq) {
          out = out c
          if (c == sq) in_sq = 0
          bs = 0
          prev = c
          continue
        }
        if (in_dq) {
          if (c == "\\") { out = out c; bs++; prev = c; continue }
          out = out c
          if (c == dq && (bs % 2) == 0) in_dq = 0
          bs = 0
          prev = c
          continue
        }
        if (c == sq && (bs % 2) == 0) { out = out c; in_sq = 1; bs = 0; prev = c; continue }
        if (c == dq && (bs % 2) == 0) { out = out c; in_dq = 1; bs = 0; prev = c; continue }
        if (c == "#" && is_word_boundary_prev(prev)) {
          # Comment to EOL — trailing backslash must not join (#1568).
          out = out c
          in_comment = 1
          bs = 0
          prev = c
          continue
        }
        if (c == "\\") { out = out c; bs++; prev = c; continue }
        out = out c
        bs = 0
        prev = c
      }
      # Bash continues inside double quotes; only single quotes and
      # `#` comments suppress continuation (#1564 / #1568).
      if (!in_sq && !in_comment && (bs % 2) == 1) {
        # Drop the continuing backslash; next record appends immediately.
        printf "%s", substr(out, 1, length(out) - 1)
        return
      }
      printf "%s\n", out
    }
    NR > 1 { emit(previous) }
    { previous = $0 }
    END { printf "%s", substr(previous, 1, length(previous) - 1) }
  ' "$mode"
}

_join_shell_continuations_fallback() {
  local joined nl=$'\n'
  if [ "${2:-bash}" = bash ]; then
    printf '%s' "$1" | LC_ALL=C tr '\\\n' '  '
    return $?
  fi
  if joined=$(printf '%s' "$1" | LC_ALL=C tr '\\\n' '  '); then
    printf '%s' "$joined"
  else
    # Keep the older PR-create fail-safe when core utilities are unavailable.
    printf '%s' "${1//\\$nl/ }"
  fi
}
