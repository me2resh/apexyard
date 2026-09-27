#!/bin/bash
# bin/check-writing-profile.sh — advisory writing-profile check.
#
# Reports two faults from the controlled technical writing profile
# (.claude/rules/writing-standard.md) in Markdown lines that a push adds:
#   - a semicolon in prose
#   - a sentence over 25 words
#
# The profile sets two limits: 20 words for an instruction and 25 words for
# descriptive text. This script does not tell an instruction from a
# description, so it applies one limit, 25 words, to every sentence. That
# is a known, documented simplification, not a bug.
#
# ADVISORY ONLY. This script always exits 0, even when it finds faults,
# even when it crashes, even on bad input. It must never block a push.
# me2resh/apexyard#1418 item 6.
#
# ---------------------------------------------------------------------------
# Known limits of the heuristic (documented on purpose):
#   - Sentence splitting on `.`, `!`, `?` is approximate. It does not
#     understand abbreviations, decimal numbers, or ellipses.
#   - A list item is treated as its own sentence, so a long bullet is
#     checked as one sentence rather than merged with its neighbours.
#   - Skip rules operate per line. A fenced code block, table, or HTML
#     comment that a single changed line only partly overlaps may still
#     be under- or over-skipped at its exact boundary.
#   - Only added lines are checked. A long sentence split across an
#     existing line and a new line is not detected.
# ---------------------------------------------------------------------------
#
# Usage:
#   bash bin/check-writing-profile.sh                    # diff vs upstream merge-base
#   bash bin/check-writing-profile.sh --range A..B        # explicit diff range
#   bash bin/check-writing-profile.sh --files a.md b.md   # explicit files (checks whole file)
#
# Output: one line per finding, `file:line: <rule>: <excerpt>`, then a
# one-line summary. Prints nothing when there are no findings.
#
# Exit code: always 0. This script must never fail a hook.

set -u

WORD_LIMIT=25

main() {
  local mode="diff"
  local range=""
  local files=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --range)
        mode="range"
        range="${2:-}"
        shift 2
        ;;
      --files)
        mode="files"
        shift
        while [ $# -gt 0 ]; do
          files+=("$1")
          shift
        done
        ;;
      *)
        shift
        ;;
    esac
  done

  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0

  local findings=0
  local scanned_files=0

  if [ "$mode" = "files" ]; then
    local f
    for f in "${files[@]}"; do
      case "$f" in
        *.md) ;;
        *) continue ;;
      esac
      [ -f "$f" ] || continue
      scanned_files=$((scanned_files + 1))
      check_whole_file "$f"
      findings=$((findings + $?))
    done
  else
    if [ "$mode" = "range" ] && [ -n "$range" ]; then
      : # use explicit range
    else
      range=$(resolve_diff_range "$repo_root") || range=""
    fi

    [ -z "$range" ] && return 0

    local diff_files
    diff_files=$(git -C "$repo_root" diff --name-only --diff-filter=ACMR "$range" -- '*.md' 2>/dev/null) || return 0
    [ -z "$diff_files" ] && return 0

    local f
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      scanned_files=$((scanned_files + 1))
      check_added_lines "$repo_root" "$range" "$f"
      findings=$((findings + $?))
    done <<< "$diff_files"
  fi

  if [ "$findings" -gt 0 ]; then
    echo "writing-profile: $findings finding(s) in $scanned_files file(s)."
  fi

  return 0
}

# resolve_diff_range REPO_ROOT
# Prints a git diff range to stdout. Prefers the merge base with the
# upstream branch, since that mirrors what a reviewer sees as "this push's
# changes." Falls back to HEAD~1..HEAD when there is no upstream tracking
# branch, so the script still does something useful stand-alone.
resolve_diff_range() {
  local repo_root="$1"
  local upstream
  upstream=$(git -C "$repo_root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)
  if [ -n "$upstream" ]; then
    local base
    base=$(git -C "$repo_root" merge-base HEAD "$upstream" 2>/dev/null)
    if [ -n "$base" ]; then
      echo "${base}..HEAD"
      return 0
    fi
  fi
  if git -C "$repo_root" rev-parse HEAD~1 >/dev/null 2>&1; then
    echo "HEAD~1..HEAD"
    return 0
  fi
  return 1
}

# check_added_lines REPO_ROOT RANGE FILE
# Extracts only the lines ADDED by RANGE for FILE, with their new-file line
# numbers, and runs the fault checks over them. Returns the finding count.
check_added_lines() {
  local repo_root="$1" range="$2" file="$3"
  local count=0

  local diff_out
  diff_out=$(git -C "$repo_root" diff -U0 "$range" -- "$file" 2>/dev/null) || return 0
  [ -z "$diff_out" ] && return 0

  local in_code_fence=0
  local cur_line=0

  while IFS= read -r line; do
    case "$line" in
      @@*)
        # Hunk header: @@ -a,b +c,d @@ — c is the first new-file line number.
        cur_line=$(printf '%s' "$line" | sed -n 's/^@@ -[0-9,]* +\([0-9]*\).*/\1/p')
        [ -z "$cur_line" ] && cur_line=0
        cur_line=$((cur_line - 1))
        ;;
      +++*|---*)
        continue
        ;;
      +*)
        cur_line=$((cur_line + 1))
        local content="${line#+}"
        check_one_line "$file" "$cur_line" "$content" "$in_code_fence"
        local line_hits=$?
        # Track fence state by scanning the running content, not the diff
        # noise. A fault check runs on the pre-toggle state of the line
        # itself (a fence delimiter line is prose-free and never a
        # finding either way).
        if printf '%s' "$content" | grep -qE '^[[:space:]]*(\`\`\`|~~~)'; then
          in_code_fence=$((1 - in_code_fence))
        fi
        count=$((count + line_hits))
        ;;
      *)
        continue
        ;;
    esac
  done <<< "$diff_out"

  return "$count"
}

# check_whole_file FILE
# Same fault checks, applied to every line of FILE (used by --files mode).
check_whole_file() {
  local file="$1"
  local count=0
  local in_code_fence=0
  local lineno=0

  while IFS= read -r content; do
    lineno=$((lineno + 1))
    check_one_line "$file" "$lineno" "$content" "$in_code_fence"
    local line_hits=$?
    if printf '%s' "$content" | grep -qE '^[[:space:]]*(\`\`\`|~~~)'; then
      in_code_fence=$((1 - in_code_fence))
    fi
    count=$((count + line_hits))
  done < "$file"

  return "$count"
}

# check_one_line FILE LINE CONTENT IN_CODE_FENCE
# Runs both fault checks on one line unless it is skip-listed content.
# Returns the number of findings (0, 1, or 2) printed for this line.
check_one_line() {
  local file="$1" lineno="$2" content="$3" in_fence="$4"
  local hits=0

  [ "$in_fence" = "1" ] && return 0

  # Fence delimiter line itself carries no prose.
  if printf '%s' "$content" | grep -qE '^[[:space:]]*(\`\`\`|~~~)'; then
    return 0
  fi

  # YAML frontmatter delimiter / a bare `---` line: skip.
  if printf '%s' "$content" | grep -qE '^---[[:space:]]*$'; then
    return 0
  fi

  # HTML comment line.
  if printf '%s' "$content" | grep -qE '^[[:space:]]*<!--.*-->[[:space:]]*$'; then
    return 0
  fi

  # Table row.
  if printf '%s' "$content" | grep -qE '^[[:space:]]*\|'; then
    return 0
  fi

  # Heading line.
  if printf '%s' "$content" | grep -qE '^[[:space:]]*#{1,6}[[:space:]]'; then
    return 0
  fi

  # Strip inline code spans (`...`) before checking — a semicolon or long
  # run inside backticks is code, not prose.
  local stripped
  stripped=$(printf '%s' "$content" | sed -E 's/`[^`]*`//g')

  # A line that is only a bare URL or a link/image reference: skip.
  if printf '%s' "$stripped" | grep -qE '^[[:space:]]*(\[.*\]:\s*\S+|!?\[.*\]\(\S+\)|https?://\S+)[[:space:]]*$'; then
    return 0
  fi

  # Rule 1: a semicolon in prose.
  if printf '%s' "$stripped" | grep -q ';'; then
    local excerpt
    excerpt=$(printf '%s' "$stripped" | cut -c1-80)
    echo "${file}:${lineno}: semicolon-in-prose: ${excerpt}"
    hits=$((hits + 1))
  fi

  # Rule 2: a sentence over 25 words. Split on ., !, ? followed by a
  # space or end of line. A list-item marker also starts a new "sentence"
  # boundary, so a bullet's own words don't merge with the previous line.
  # Done in awk, char by char, because ERE (sed -E) has no lazy quantifier
  # and cannot express "up to the first . ! or ?" any other way.
  local prose="$stripped"
  # Remove a leading list marker (-, *, +, or N.) so it doesn't count as
  # a word and doesn't block the split logic below.
  prose=$(printf '%s' "$prose" | sed -E 's/^[[:space:]]*([-*+]|[0-9]+\.)[[:space:]]+//')

  local sentence_findings
  sentence_findings=$(awk -v text="$prose" -v limit="$WORD_LIMIT" -v file="$file" -v lineno="$lineno" '
    function process(s) {
      gsub(/^[ \t]+/, "", s)
      gsub(/[ \t]+$/, "", s)
      if (s == "") { return }
      wc = split(s, words, /[ \t]+/)
      if (wc > limit) {
        excerpt = substr(s, 1, 80)
        printf "%s:%s: sentence-over-%d-words (%dw): %s\n", file, lineno, limit, wc, excerpt
      }
    }
    BEGIN {
      n = length(text)
      start = 1
      for (i = 1; i <= n; i++) {
        c = substr(text, i, 1)
        if (c == "." || c == "!" || c == "?") {
          nextc = substr(text, i + 1, 1)
          if (nextc == "" || nextc == " " || nextc == "\t") {
            process(substr(text, start, i - start + 1))
            start = i + 1
          }
        }
      }
      if (start <= n) {
        process(substr(text, start))
      }
    }
  ')

  if [ -n "$sentence_findings" ]; then
    local sentence_line
    while IFS= read -r sentence_line; do
      [ -z "$sentence_line" ] && continue
      echo "$sentence_line"
      hits=$((hits + 1))
    done <<< "$sentence_findings"
  fi

  return "$hits"
}

main "$@" 2>/dev/null
exit 0
