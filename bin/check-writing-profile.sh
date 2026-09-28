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
# Round-2 fixes (Rex + Hakim review of PR #1429):
#   - Fence detection no longer uses grep with an escaped backtick
#     (`\``). GNU grep reads `\`` as its own "start of buffer" operator,
#     not a literal backtick, so every line matched and nothing was ever
#     reported on Linux. Fence, and every other line-shape check that can
#     run on a hostile or hand-crafted line, now uses a plain bash `case`
#     pattern or the bash `[[ =~ ]]` builtin instead of forking `grep`
#     with a hand-escaped pattern.
#   - A table row's `|` used to be escaped as `\|` in an ERE, which is
#     unspecified behaviour outside GNU's extensions. It is now matched
#     inside a bracket expression (`[|]`), which needs no escaping and
#     means the same thing on every grep.
#   - Renamed files are now read from ONE whole-range `git diff -M`, not
#     one `git diff` per path. Git can only pair a rename against a pool
#     of candidates, so diffing one path at a time made a pure rename look
#     like a brand-new file and reported every old line as "added".
#   - The sentence-length awk pass now reads its input through `ENVIRON`,
#     not `-v`. Awk's `-v` unescapes backslash sequences in the value, so
#     printable text like "\033" in a Markdown line became a real ESC
#     byte in the printed excerpt. `ENVIRON` does not do this. Every
#     excerpt is also passed through `tr -d` to drop any control byte
#     that was already raw in the source line.
#   - `--range` with no following value used to loop forever (a `shift 2`
#     that silently does nothing when only one argument remains). `--files`
#     with no following file used to exit 1 on bash 3.2, because an empty
#     array's elements are "unset" under `set -u` on that bash version.
#     Both are fixed. The whole script also now runs inside a subshell
#     wrapper, so an error this review did not anticipate still can't stop
#     the final `exit 0` from running.
#   - Finding counts are a shared shell variable now, not a function
#     return code. A return code is one byte and wraps at 256; a variable
#     does not.
#   - Every `git diff` call adds `--no-ext-diff --no-textconv --no-color`,
#     so a contributor's `diff.external` or `color.diff=always` git config
#     cannot change what this script parses. `-c core.quotePath=false`
#     stops git from octal-escaping a non-ASCII filename in the diff
#     header, so such a file is no longer silently skipped.
#   - Content inside a YAML frontmatter block or a multi-line HTML comment
#     is now skipped for its whole extent, not just on the delimiter line.
#   - Added lines are capped at $MAX_ADDED_LINES (default 3000, override
#     with WP_MAX_ADDED_LINES for a test). Past the cap, the script stops
#     forking a check per line and prints one notice line instead.
# ---------------------------------------------------------------------------
# Known limits of the heuristic (documented on purpose):
#   - Sentence splitting on `.`, `!`, `?` is approximate. It does not
#     understand abbreviations, decimal numbers, or ellipses.
#   - A list item is treated as its own sentence, so a long bullet is
#     checked as one sentence rather than merged with its neighbours.
#   - A bare `---` toggles the YAML-frontmatter skip. A Markdown
#     horizontal rule or setext-heading underline is also a bare `---`,
#     so one of those can wrongly start or end a skipped block. This is a
#     false SKIP (fewer findings), never a false finding, so it stays
#     inside this script's advisory-only bar.
#   - Skip rules run per line with per-file state carried across lines in
#     the same diff. A fence, frontmatter block, or comment that started
#     BEFORE the range being checked (so its opening line is not itself an
#     added line) is not recognised as already open.
#   - Only added lines are checked. A long sentence split across an
#     existing line and a new line is not detected.
#   - This script does not read git's own pre-push stdin ref list (the
#     exact refs a `git push` is sending). It diffs HEAD against the
#     merge base with the upstream branch, or `HEAD~1..HEAD` with no
#     upstream. Pushing a ref that is not the checked-out HEAD, or a new
#     branch with no upstream yet, checks the wrong or a narrower range.
#     This is the same limit `bin/run-pre-push-checks.sh`'s own
#     markdownlint step already accepts (see that script's header) and is
#     left as-is here on purpose.
#   - A filename that git cannot losslessly print in its diff header (for
#     example, one containing a literal double-quote or backslash) is
#     skipped rather than mis-parsed.
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
# Override with WP_MAX_ADDED_LINES for a fast test; production default 3000.
MAX_ADDED_LINES="${WP_MAX_ADDED_LINES:-3000}"

# Shared counters. Deliberately plain shell variables, not function return
# codes: a return code is a single byte (0-255) and wraps silently past
# that; a large Markdown push could otherwise under-report its own count.
TOTAL_FINDINGS=0
SCANNED_FILES=0

# Per-file skip state. Reset at the start of each file (see check_range and
# check_whole_file). Read and written directly by check_one_line, which
# always runs in the current shell (never inside a `$(...)` subshell), so
# these mutations are visible to the caller without any plumbing.
in_code_fence=0
in_frontmatter=0
in_html_comment=0

# ltrim TEXT
# Prints TEXT with leading spaces/tabs removed. A bash `case` pattern, not
# a regex — this needs no escaping and behaves identically on every shell.
ltrim() {
  local s="$1"
  while :; do
    case "$s" in
      ' '*|"$(printf '\t')"*) s="${s#?}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$s"
}

main() {
  local mode="diff"
  local range=""
  local files=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --range)
        # Always shift past the flag itself first. A bare `shift 2` here,
        # when this was the LAST argument, leaves $1 == "--range" and
        # repeats forever — that was the round-1 hang.
        shift
        mode="range"
        if [ $# -gt 0 ]; then
          range="$1"
          shift
        else
          range=""
        fi
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

  if [ "$mode" = "files" ]; then
    # Check length before indexing. On bash 3.2 (macOS's default),
    # expanding an EMPTY array's elements under `set -u` is treated as an
    # unset-variable reference and aborts the script — that was the
    # round-1 "--files with no files" crash. ${#files[@]} is always safe.
    if [ "${#files[@]}" -gt 0 ]; then
      local f
      for f in "${files[@]}"; do
        case "$f" in
          *.md) ;;
          *) continue ;;
        esac
        [ -f "$f" ] || continue
        SCANNED_FILES=$((SCANNED_FILES + 1))
        check_whole_file "$f"
      done
    fi
  else
    if [ "$mode" = "range" ] && [ -n "$range" ]; then
      : # use the explicit range as given
    else
      range=$(resolve_diff_range "$repo_root") || range=""
    fi
    [ -z "$range" ] && return 0
    check_range "$repo_root" "$range"
  fi

  if [ "$TOTAL_FINDINGS" -gt 0 ]; then
    echo "writing-profile: $TOTAL_FINDINGS finding(s) in $SCANNED_FILES file(s)."
  fi

  return 0
}

# resolve_diff_range REPO_ROOT
# Prints a git diff range to stdout. Prefers the merge base with the
# upstream branch, since that mirrors what a reviewer sees as "this push's
# changes." Falls back to HEAD~1..HEAD when there is no upstream tracking
# branch, so the script still does something useful stand-alone. See the
# header's "Known limits" for why this is not the exact push range.
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

# check_range REPO_ROOT RANGE
# Reads ONE whole-range diff, scoped to *.md, with rename detection (-M)
# on. Diffing the whole range at once (rather than one path at a time)
# lets git pair a rename against its old name, so a pure rename with
# unchanged content reports zero added lines instead of the whole file.
check_range() {
  local repo_root="$1" range="$2"
  local diff_out
  diff_out=$(git -c core.quotePath=false -C "$repo_root" --no-pager diff -U0 -M \
    --no-ext-diff --no-textconv --no-color --diff-filter=ACMR \
    "$range" -- '*.md' 2>/dev/null) || return 0
  [ -z "$diff_out" ] && return 0

  local file_sections
  file_sections=$(printf '%s\n' "$diff_out" | grep -c '^diff --git ' 2>/dev/null)
  case "$file_sections" in
    ''|*[!0-9]*) file_sections=0 ;;
  esac
  SCANNED_FILES=$file_sections

  local cur_file="" cur_line=0 added_seen=0 capped=0
  in_code_fence=0
  in_frontmatter=0
  in_html_comment=0

  while IFS= read -r line; do
    case "$line" in
      "diff --git "*)
        # New file section. Take the path after the LAST " b/" (the
        # post-rename name, when this is a rename). A filename git had to
        # quote (a literal quote, backslash, or control byte in the name)
        # is left quoted here and simply won't match any check below —
        # see "Known limits".
        cur_file="${line##* b/}"
        case "$cur_file" in
          \"*\") cur_file="${cur_file#\"}"; cur_file="${cur_file%\"}" ;;
        esac
        in_code_fence=0
        in_frontmatter=0
        in_html_comment=0
        cur_line=0
        ;;
      "+++ "*|"--- "*)
        continue
        ;;
      "@@ "*)
        # Hunk header: @@ -a,b +c,d @@ — c is the first new-file line number.
        cur_line=$(printf '%s' "$line" | sed -n 's/^@@ -[0-9,]* +\([0-9]*\).*/\1/p')
        [ -z "$cur_line" ] && cur_line=0
        cur_line=$((cur_line - 1))
        ;;
      "+"*)
        [ -z "$cur_file" ] && continue
        if [ "$capped" = "1" ]; then
          continue
        fi
        cur_line=$((cur_line + 1))
        added_seen=$((added_seen + 1))
        check_one_line "$cur_file" "$cur_line" "${line#+}"
        if [ "$added_seen" -ge "$MAX_ADDED_LINES" ]; then
          capped=1
          echo "writing-profile: line cap (${MAX_ADDED_LINES} added lines) reached — remaining added lines were not checked."
        fi
        ;;
      *)
        continue
        ;;
    esac
  done <<< "$diff_out"
}

# check_whole_file FILE
# Same fault checks, applied to every line of FILE (used by --files mode).
check_whole_file() {
  local file="$1"
  in_code_fence=0
  in_frontmatter=0
  in_html_comment=0
  local lineno=0 seen=0 capped=0
  local content

  while IFS= read -r content || [ -n "$content" ]; do
    lineno=$((lineno + 1))
    if [ "$capped" = "1" ]; then
      continue
    fi
    seen=$((seen + 1))
    check_one_line "$file" "$lineno" "$content"
    if [ "$seen" -ge "$MAX_ADDED_LINES" ]; then
      capped=1
      echo "writing-profile: line cap (${MAX_ADDED_LINES} lines) reached in ${file} — remaining lines were not checked."
    fi
  done < "$file"
}

# check_one_line FILE LINE CONTENT
# Runs both fault checks on one line unless it is skip-listed content.
# Reads and updates the in_code_fence / in_frontmatter / in_html_comment
# globals directly — see their declaration above for why that is safe.
check_one_line() {
  local file="$1" lineno="$2" content="$3"
  local trimmed
  trimmed="$(ltrim "$content")"

  # Fence delimiter: three or more backticks or tildes. A bash `case`
  # glob, not a regex — this is the exact construct that broke on GNU
  # grep in round 1 (an escaped backtick reads as GNU's own
  # "start of buffer" operator, matching every line). A case pattern has
  # no regex engine underneath it at all, so there is nothing to diverge
  # between platforms.
  case "$trimmed" in
    '```'*|'~~~'*)
      in_code_fence=$((1 - in_code_fence))
      return 0
      ;;
  esac
  if [ "$in_code_fence" = "1" ]; then
    return 0
  fi

  # YAML frontmatter delimiter. Toggles a block; content inside is
  # skipped for its whole extent (round-2 fix — round 1 only skipped the
  # delimiter line itself). See "Known limits" for the horizontal-rule
  # ambiguity this accepts.
  if [ "$trimmed" = "---" ]; then
    in_frontmatter=$((1 - in_frontmatter))
    return 0
  fi
  if [ "$in_frontmatter" = "1" ]; then
    return 0
  fi

  # HTML comment, including a multi-line one (round-2 fix). A line that
  # opens and closes on the same line is fully skipped without changing
  # state. A line that only opens starts a skipped block; a later line
  # that closes it ends the block.
  if [ "$in_html_comment" = "1" ]; then
    case "$trimmed" in
      *'-->'*) in_html_comment=0 ;;
    esac
    return 0
  fi
  case "$trimmed" in
    *'<!--'*'-->'*)
      return 0
      ;;
    *'<!--'*)
      in_html_comment=1
      return 0
      ;;
  esac

  # Table row. `[|]` is a bracket expression: it needs no escaping and
  # means "a literal pipe" on every grep. `\|` (escaping an ERE
  # metacharacter to make it literal) is unspecified by POSIX, which is
  # its own small GNU/BSD risk even though it was not the bug CI hit.
  case "$trimmed" in
    '|'*) return 0 ;;
  esac

  # Heading line. Untouched since round 1 — interval expressions
  # ({1,6}) are ordinary POSIX ERE, not the GNU extension that broke the
  # fence check, and this pattern was not among CI's failures.
  if printf '%s' "$trimmed" | grep -qE '^#{1,6}[[:space:]]'; then
    return 0
  fi

  # Strip inline code spans (`...`) before checking — a semicolon or long
  # run inside backticks is code, not prose. Then drop any C0 control
  # byte or DEL that is already raw in the source line (not a printable
  # escape sequence — see the awk ENVIRON note below), so it can never
  # reach a printed excerpt.
  local stripped
  stripped=$(printf '%s' "$content" | sed -E 's/`[^`]*`//g' | LC_ALL=C tr -d '\001-\010\013-\037\177')

  # A line that is only a bare URL or a link/image reference: skip.
  # Untouched since round 1 — same reasoning as the heading check above.
  if printf '%s' "$stripped" | grep -qE '^[[:space:]]*(\[.*\]:\s*\S+|!?\[.*\]\(\S+\)|https?://\S+)[[:space:]]*$'; then
    return 0
  fi

  # Rule 1: a semicolon in prose.
  if printf '%s' "$stripped" | grep -q ';'; then
    local excerpt
    excerpt=$(printf '%s' "$stripped" | cut -c1-80)
    echo "${file}:${lineno}: semicolon-in-prose: ${excerpt}"
    TOTAL_FINDINGS=$((TOTAL_FINDINGS + 1))
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
  # ENVIRON, not -v: awk's `-v NAME=value` unescapes backslash sequences
  # in `value` (its own command-line-assignment rule), so printable text
  # like "\033" in a Markdown line became a real ESC byte in the printed
  # excerpt in round 1. Reading the same value through ENVIRON performs
  # no such unescaping.
  sentence_findings=$(WP_TEXT="$prose" WP_LIMIT="$WORD_LIMIT" WP_FILE="$file" WP_LINE="$lineno" awk '
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
      text = ENVIRON["WP_TEXT"]
      limit = ENVIRON["WP_LIMIT"] + 0
      file = ENVIRON["WP_FILE"]
      lineno = ENVIRON["WP_LINE"]
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
      TOTAL_FINDINGS=$((TOTAL_FINDINGS + 1))
    done <<< "$sentence_findings"
  fi

  return 0
}

# Run inside a subshell, then unconditionally exit 0. If something this
# review did not anticipate still kills `main` outright (bash's `set -u`
# aborts the whole shell on some unset-variable references, not just the
# current function), that abort only ends the subshell — this script's
# own `exit 0` below still runs.
( main "$@" ) 2>/dev/null
exit 0
