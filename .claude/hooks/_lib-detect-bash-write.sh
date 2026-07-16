#!/bin/bash
# _lib-detect-bash-write.sh — detect whether a Bash command writes to a file.
#
# Closes the bypass surface where Bash file-writes routed around hooks
# scoped to Edit|Write|MultiEdit only. See me2resh/apexyard#151.
#
# Design choice: false-negatives PREFERRED over false-positives.
# Blocking a legitimate read-only command on a fresh-adopter test is
# worse than missing one obscure write pattern. We catch the common
# cases (~95%) and treat the long tail as a known-limitation that
# extends as new patterns are discovered.
#
# AgDR-0011 frames the matcher table as a LIVING LIST — extended on
# observation. me2resh/apexyard#153 extended the first-version coverage
# (#152) with file-moving builtins, archive/network writes, additional
# interpreters, and python-helper / heredoc shapes.
#
# Usage:
#   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-detect-bash-write.sh"
#   if bash_command_appears_to_write "$COMMAND"; then
#     targets=$(bash_extract_write_targets "$COMMAND")
#     # ... apply gate to EVERY line of $targets — see #886. Judging only
#     # the first target lets a command that ALSO writes an out-of-repo
#     # path first (`echo x > /tmp/a; echo y > src/app.ts`) slip its
#     # second, in-repo target past a gate that only looked at target #1.
#   fi
#
# Exposed functions:
#   bash_command_appears_to_write COMMAND
#       returns 0 if the command appears to write to a file, 1 otherwise
#
#   bash_extract_write_target COMMAND
#       echoes the FIRST target path if extractable, empty string
#       otherwise. Best-effort — only handles the simple cases (echo >
#       file, tee file, sed -i ... file, cp src dst, curl -o file).
#       Embedded interpreters (python -c, node -e, ruby -e, perl -e,
#       php -r, go run, deno, bun) return empty.
#
#       Kept for backward compatibility with existing single-target
#       call sites and tests. New gate consumers should prefer
#       bash_extract_write_targets (plural, below) — a command can name
#       more than one write target, and judging only the first is a
#       gate-bypass surface (#886).
#
#   bash_extract_write_targets COMMAND
#       echoes EVERY extractable write target, one per line, deduplicated.
#       Splits the command on top-level separators (&&, ||, ;, |) so each
#       chained command is considered independently, and within a segment
#       captures every redirection (`cmd > a; cmd2 > b` inside one
#       segment, e.g. from a heredoc) and every tee operand (`tee a b c`
#       names three targets). Same misses as bash_extract_write_target —
#       an unparseable segment contributes nothing, never a fabricated
#       target.

# ------------------------------------------------------------------------------
# Public: bash_command_appears_to_write COMMAND
#
# Detects (matcher families):
#
#   Redirection / pipes-to-disk
#     - cmd > file, cmd >> file, cmd 2> file
#     - cmd &> file, cmd >| file (force-clobber), cmd <> file (read-write
#       open, #931)
#     - tee
#
#   NOT matched as a write (deliberate exclusion, #931):
#     - cmd >(subshell), cmd <(subshell) — process substitution. Looks
#       adjacent to a redirect but is a command, not a file target.
#
#   In-place text editors
#     - sed -i (in-place edit, GNU + BSD `''` form)
#     - awk -i inplace
#
#   File-moving builtins (#153)
#     - cp, mv, rm, dd, install — anchored at command start, --help/--version
#       excluded, `git rm`/`git mv` excluded (those are subcommands)
#
#   Archive / network writes (#153)
#     - tar -x, tar --extract
#     - curl -o / --output
#     - wget -O / --output-document
#
#   Embedded interpreters with inline source (-c / -e / -r)
#     - python -c '…' with write/open/touch/copy/rename keywords
#     - python <<EOF / python - <<EOF (heredoc-fed)
#     - node -e '…' with writeFile/appendFile/write keywords
#     - node <<EOF (heredoc-fed, #153)
#     - ruby -e '…' with File.write/open keywords
#     - ruby <<EOF (heredoc-fed, #153)
#     - perl -e '…' with print-to-handle / open / unlink keywords (#153)
#     - php -r '…' with file_put_contents / fwrite / fopen keywords (#153)
#
#   Script runners — categorical (#153)
#     - go run <file>
#     - deno run / deno <script.{ts,js,mjs}>
#     - bun / bun run <script.{ts,js,mjs}>
#
# Misses (intentionally — long tail):
#   - xargs that constructs a write command
#   - find -exec sed/awk/etc.
#   - Custom scripts that wrap writes (could be anything)
#   - Bash builtins like `read VAR < file` (that's a read, anyway)
#
# Returns 0 (write detected), 1 (no write detected).
# ------------------------------------------------------------------------------

# Helper: returns 0 if $1 (a command string) is a "help / version" invocation
# that should be treated as read-only — used by file-moving-builtin matchers.
_bdw_is_help_or_version() {
  local cmd="$1"
  echo "$cmd" | grep -qE '(^|[[:space:]])(--help|--version|-h|-V)([[:space:]]|$)'
}

# Helper: returns 0 if the bare command (first word, possibly after pipe/&&/;/|/()
# is `git`. Used to skip `git rm`, `git mv` — those are subcommands, not the
# coreutils. We check at every command-start position.
_bdw_starts_with_git_subcommand() {
  local cmd="$1" sub="$2"
  # Match `git <sub>` at command-start positions only.
  echo "$cmd" | grep -qE "(^|[;&|(]|&&|\|\|)[[:space:]]*git[[:space:]]+${sub}\b"
}

# ------------------------------------------------------------------------------
# Matcher families
# ------------------------------------------------------------------------------

# 1. Redirection.
#
# The leading-context class `[^|<&]` excludes a `>` that's part of `2>&1`
# fd-dup or immediately follows a pipe/heredoc marker. But `[^|<&]` REQUIRES
# a character before `>` to exist at all — a command (or, after #886's
# segment split, a SEGMENT) that BEGINS with `>` has no preceding character,
# so the original pattern silently failed to match at position 0. That's
# the exact shape a no-space chained write produces: splitting
# `echo a > /tmp/ok;> .gitignore` on `;` yields a second segment of
# `> .gitignore` — starting with `>` — and the un-anchored pattern dropped
# it entirely (apexyard#886 Hakim security-review finding, PR #926).
# `(^|[^|<&])` adds "start of string/segment" as an equally-valid leading
# context, closing that hole while leaving the `2>&1` / `<<EOF` exclusions
# intact (neither of those ever begins a segment with a bare `>`).
#
# COMPLETE operator alternation (apexyard#886/#926 round 3 — Hakim's
# adversarial re-hunt): the pattern above only modelled `>` / `>>` (and,
# via the leading-context class, `n>` / `n>>` for an fd number). It missed
# two more real, destructive write operators:
#   - `&>` / `&>>`  — redirect BOTH stdout and stderr to a file (a write).
#     Matched by a dedicated `&>>?` alternative: `&` immediately followed
#     by `>` is unambiguous — it never appears in `2>&1` or `>&2` (there
#     the `&` comes AFTER the `>`, not before), so this can't collide with
#     the fd-dup exclusion the leading-context class protects.
#   - `>|` / `>>|`  — force-clobber (override `set -o noclobber`), also a
#     write. Modelled by an optional trailing `\|?` on the existing `>>?`.
# Both are added as alternatives / suffixes to the SAME anchored pattern,
# not new logic — `2>&1`, `>&2`, `<`, `<<EOF`, `<<<` are all still excluded
# by the same mechanisms as before (whitespace after the operator is now
# OPTIONAL — see the #886/#926 round-4 note below — but the exclusions
# don't rely on mandatory whitespace; they rely on `&` only being
# recognised when it precedes `>`, never follows).
#
# Whitespace after the operator is OPTIONAL (apexyard#886/#926 round 4 —
# Hakim's adversarial re-hunt): bash accepts ZERO whitespace between a
# redirect operator and its target (`echo hi>file`, `echo b 2>file`,
# `echo b>>file`, `echo b>|file`, `echo b&>file` are all valid, real
# writes) — the mandatory `[[:space:]]+` here silently dropped every one
# of them. Relaxed to `[[:space:]]*` (zero-or-more). This does NOT open a
# new false-positive surface for `2>&1`/`>&2`/`1>&2` (fd-dup): after the
# operator matches, the target class `[^[:space:]&|;]+` still EXCLUDES
# `&` — so when the very next character is `&` (as in all three fd-dup
# forms), the target can't start there regardless of how much whitespace
# came before it. The whitespace requirement was never what excluded
# fd-dup; the target character class was and still is.
#
# `<>` READ-WRITE OPEN (apexyard#886/#931 round 6, closing one of the two
# residuals #926 documented-and-deferred): `[n]<>word` opens `word` for
# BOTH reading and writing on descriptor `n` (or fd 0 if `n` is omitted) —
# `exec 3<> some/file`, `cmd <>file` are real, non-truncating writes that
# every prior round's operator alternation missed entirely (the `<`
# leading character was always excluded by the OTHER operators' own
# leading-context class, `[^|<&]`, so `<>` was structurally invisible to
# this pattern, not just an uncovered edge case). The new `[0-9]*<>`
# alternative is unambiguous against every existing operator: `<>` is two
# literal characters (`<` immediately followed by `>`), which never
# occurs inside `<<` (heredoc), `<<<` (herestring), or any of the
# fd-dup/`>`-based forms above (those all have `>` preceding `&`, never
# `<` immediately preceding `>`). Chosen to DETECT rather than
# document-as-accepted (per #931's own framing: "a write is a write") —
# the non-truncating risk profile differs from `>`/`>>`, but the ticket
# gate cares about "was tracked content touched", not "was it truncated".
#
# `>(…)` / `<(…)` PROCESS SUBSTITUTION now EXCLUDED from the target class
# (apexyard#886/#931 round 6, closing the second #926-deferred residual):
# `diff a >(sort)` is not a file write — `>(sort)` is process substitution,
# a subshell whose stdin bash wires to a fifo/fd path, syntactically
# adjacent to `>` but semantically a command, not a redirect target. The
# prior target class `[^[:space:]&|;]+` allowed a leading `(` and so
# happily consumed `(sort)` as if it were a filename — a fail-closed
# (over-blocking) false positive, not a bypass, but still worth tightening
# per #931. Splitting the target class into a first-char exclusion,
# `[^[:space:]&|;(]`, plus the unchanged `[^[:space:]&|;]*` for the rest,
# means the match FAILS whenever the character immediately after the
# operator (past any optional whitespace) is `(` — process substitution
# always starts there with zero space (`> (foo)` is not valid bash
# redirect-to-subshell syntax; a space there is a syntax error, so
# excluding the immediately-adjacent case costs nothing on real commands).
# A legitimate filename that merely CONTAINS a paren not in the leading
# position (`file(1).txt`) is untouched — only a LEADING `(` is excluded.
# `<(…)` (process substitution on the read side) was never matched here
# to begin with (`<` alone isn't a write operator in this file), so no
# change was needed for that half.
_bdw_match_redirection() {
  echo "$1" | grep -qE '(&>>?|(^|[^|<&])>>?\|?|[0-9]*<>)[[:space:]]*[^[:space:]&|;(][^[:space:]&|;]*'
}

# ------------------------------------------------------------------------------
# Internal: _bdw_split_top_level COMMAND
#
# Splits COMMAND into top-level segments on &&, ||, ;, | — echoed one per
# line via stdout. THE canonical segmentation for this whole library:
# both DETECTION (_bdw_match_redirection_any_segment, below) and
# EXTRACTION (bash_extract_write_targets) call this SAME function, so
# they cannot disagree about where one command ends and the next begins
# (apexyard#886/#926 round 5 — Hakim security review; see that helper's
# comment for why divergence was the actual structural bug behind rounds
# 1-5 of this operator class, not "yet another missed operator").
#
# Protects the force-clobber operators (`>|`, `>>|`) from being torn
# apart by the bare-`|` split — a real bash tokenizer lexes them as ONE
# operator, never as `>` followed by a separate pipe — via a
# placeholder-and-restore step. Uses bash parameter-expansion
# substitution, NOT sed, for the split itself: BSD sed (macOS's default,
# non-GNU) does not honour `\n` in replacement text as a literal newline,
# so a sed-based split would silently no-op on a stock Mac.
# ------------------------------------------------------------------------------
_bdw_split_top_level() {
  local cmd="$1"
  [ -z "$cmd" ] && return 0

  local split="$cmd"
  # Longest-match-first: protect >>| before >| so >>| isn't half-eaten by
  # the >| substitution (>>| contains >| as a substring).
  split="${split//>>|/@@APEXYARD_CLOBBER_APPEND@@}"
  split="${split//>|/@@APEXYARD_CLOBBER@@}"

  # Two-character separators BEFORE single-character ones, so && / ||
  # aren't first flattened into two lone & / | splits.
  split="${split//&&/$'\n'}"
  split="${split//||/$'\n'}"
  split="${split//;/$'\n'}"
  split="${split//|/$'\n'}"

  split="${split//@@APEXYARD_CLOBBER_APPEND@@/>>|}"
  split="${split//@@APEXYARD_CLOBBER@@/>|}"

  printf '%s\n' "$split"
}

# ------------------------------------------------------------------------------
# Internal: _bdw_match_redirection_any_segment COMMAND
#
# THE STRUCTURAL FIX for apexyard#886/#926 round 5 (Hakim security
# review). Runs _bdw_match_redirection on EACH top-level segment of
# COMMAND (via _bdw_split_top_level) instead of on the whole, unsplit
# command.
#
# Why this was the actual bug, not another missed operator: DETECTION
# (bash_command_appears_to_write, via this helper's predecessor) used to
# call _bdw_match_redirection on the WHOLE command. EXTRACTION
# (bash_extract_write_targets) already split into segments FIRST, then
# anchored `^` per segment. For `false ||> src/app.ts` — a real,
# truncating write — the `>` is immediately preceded by `|` (from `||`).
# On the whole, unsplit string, `[^|<&]` (needed to exclude `2>&1`/`>&2`
# fd-dup) EXCLUDES that `|`-preceded `>` from matching, and it isn't at
# `^` either (it's preceded by `|`), so detection said "not a write" —
# false negative, exit 0, no ticket. Extraction, meanwhile, split on `||`
# first, leaving `> src/app.ts` as its own segment where the `>` sits at
# `^` — which the anchor DOES match — so extraction correctly found the
# target. Detection and extraction disagreed; that disagreement, not the
# `|`/`||` operator itself, was the root cause across rounds 1-5 (`;>`
# survived only because `;` isn't excluded by the leading-context class;
# `&&>` survived only by coincidentally containing the substring `&>`;
# `|>`/`||>`/`||>|` had no such rescue). Splitting BEFORE matching, with
# the SAME segmentation function extraction already uses, means the two
# paths can't diverge again — this is the fix, not one more operator
# added to the alternation.
# ------------------------------------------------------------------------------
_bdw_match_redirection_any_segment() {
  local cmd="$1" seg
  [ -z "$cmd" ] && return 1
  while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    _bdw_match_redirection "$seg" && return 0
  done < <(_bdw_split_top_level "$cmd")
  return 1
}

# 2. tee.
_bdw_match_tee() {
  echo "$1" | grep -qE '\btee\b'
}

# 3. sed -i.
_bdw_match_sed_inplace() {
  echo "$1" | grep -qE '\bsed[[:space:]]+([^|;&]*[[:space:]])?-i\b'
}

# 4. awk -i inplace.
_bdw_match_awk_inplace() {
  echo "$1" | grep -qE '\bawk[[:space:]]+[^|;&]*-i[[:space:]]+inplace\b'
}

# 5. File-moving builtins (cp, mv, rm, dd, install). Anchored at command-start.
#    `git rm`, `git mv`, `cp --help`, `rm --version` etc. are excluded.
_bdw_match_file_movers() {
  local cmd="$1"
  # Must contain one of the builtins as the first token of a command segment.
  # Segment delimiters: start-of-line, `;`, `&&`, `||`, `|`, `(`.
  if echo "$cmd" | grep -qE '(^|[;&|(]|&&|\|\|)[[:space:]]*(cp|mv|rm|dd|install)([[:space:]]|$)'; then
    # Exclude help/version forms.
    _bdw_is_help_or_version "$cmd" && return 1
    # Exclude `git rm` / `git mv` — those are git subcommands.
    if _bdw_starts_with_git_subcommand "$cmd" "rm" \
       || _bdw_starts_with_git_subcommand "$cmd" "mv"; then
      # If the ONLY match in the command is the git-subcommand, treat as read.
      # If there's *also* a real cp/rm/mv/dd/install elsewhere, fall through.
      # Approximation: if the command contains another fresh segment with one
      # of the builtins not preceded by `git `, it's still a write.
      if ! echo "$cmd" | grep -qE '(^|[;&|(]|&&|\|\|)[[:space:]]*(cp|mv|rm|dd|install)([[:space:]]|$)' \
           | grep -vE 'git[[:space:]]+(rm|mv)'; then
        # Fast path: if the entire command starts with `git rm` / `git mv` and
        # has no further command segments, treat as read-only.
        if echo "$cmd" | grep -qE '^[[:space:]]*git[[:space:]]+(rm|mv)\b' \
           && ! echo "$cmd" | grep -qE '[;&|]'; then
          return 1
        fi
      fi
    fi
    return 0
  fi
  return 1
}

# 6. tar -x / tar --extract.
_bdw_match_tar_extract() {
  local cmd="$1"
  # Fast reject — must contain `tar`.
  echo "$cmd" | grep -qE '\btar\b' || return 1
  # `tar --extract` long form.
  if echo "$cmd" | grep -qE '\btar\b[^|;&]*--extract\b'; then
    return 0
  fi
  # `tar -x` / `tar -xf` / `tar xf` (short bundled form, common).
  # Look for tar followed by an option token containing `x`. Avoid matching
  # the `x` inside `--exclude` etc. by requiring a single-dash short-flag form.
  if echo "$cmd" | grep -qE '\btar\b[[:space:]]+(-[A-Za-z]*x[A-Za-z]*|x[A-Za-z]*)\b'; then
    return 0
  fi
  return 1
}

# 7. curl -o / --output.
_bdw_match_curl_output() {
  local cmd="$1"
  echo "$cmd" | grep -qE '\bcurl\b' || return 1
  # `--output FILE` or `-o FILE`. Exclude `--output-dir` (separate flag) by
  # requiring `--output` to be followed by whitespace and a non-flag token.
  if echo "$cmd" | grep -qE '\bcurl\b[^|;&]*(--output\b|-o\b)'; then
    # Avoid matching `--output-dir` alone (rare flag — still a write surface
    # but conservative match keeps this branch tight).
    if echo "$cmd" | grep -qE '\bcurl\b[^|;&]*--output-dir\b' \
       && ! echo "$cmd" | grep -qE '\bcurl\b[^|;&]*(--output[[:space:]]|-o[[:space:]])'; then
      return 1
    fi
    return 0
  fi
  return 1
}

# 8. wget -O / --output-document.
_bdw_match_wget_output() {
  local cmd="$1"
  echo "$cmd" | grep -qE '\bwget\b' || return 1
  if echo "$cmd" | grep -qE '\bwget\b[^|;&]*(--output-document\b|-O\b)'; then
    return 0
  fi
  return 1
}

# 9. Embedded Python (-c) with write keywords. Extended in #153 to include
#    pathlib touch, shutil copy*/move, os.rename.
_bdw_match_python_dash_c() {
  local cmd="$1"
  echo "$cmd" | grep -qE '\bpython3?[[:space:]]+(-[^c]*[[:space:]]+)?-c\b' || return 1
  echo "$cmd" | grep -qE '\.write_text\b|\.write\b|\bopen\([^)]*[wa+]|\.touch\(|\bshutil\.(copy|copyfile|copy2|copytree|move)\b|\bos\.rename\b'
}

# 10. Heredoc-fed Python. Extended in #153 for the same keyword list.
_bdw_match_python_heredoc() {
  local cmd="$1"
  echo "$cmd" | grep -qE '\bpython3?[[:space:]]+(-[[:space:]]+)?<<' || return 1
  echo "$cmd" | grep -qE '\.write_text\b|\.write\b|\bopen\([^)]*[wa+]|\.touch\(|\bshutil\.(copy|copyfile|copy2|copytree|move)\b|\bos\.rename\b'
}

# 11. Embedded Node (-e) with write keywords.
_bdw_match_node_dash_e() {
  local cmd="$1"
  echo "$cmd" | grep -qE '\bnode[[:space:]]+(-[^e]*[[:space:]]+)?-e\b' || return 1
  echo "$cmd" | grep -qE '\bwriteFile(Sync)?\b|\.write\b|\bappendFile(Sync)?\b|\bcopyFile(Sync)?\b|\brename(Sync)?\b'
}

# 12. Heredoc-fed Node (#153).
_bdw_match_node_heredoc() {
  local cmd="$1"
  echo "$cmd" | grep -qE '\bnode\b[[:space:]]*<<' || return 1
  echo "$cmd" | grep -qE '\bwriteFile(Sync)?\b|\.write\b|\bappendFile(Sync)?\b|\bcopyFile(Sync)?\b|\brename(Sync)?\b'
}

# 13. Embedded Ruby (-e).
_bdw_match_ruby_dash_e() {
  local cmd="$1"
  echo "$cmd" | grep -qE '\bruby[[:space:]]+(-[^e]*[[:space:]]+)?-e\b' || return 1
  echo "$cmd" | grep -qE '\bFile\.write\b|\.write\b|\bFile\.open\([^)]*[wa+]|\bFileUtils\.(cp|mv|rm)\b'
}

# 14. Heredoc-fed Ruby (#153).
_bdw_match_ruby_heredoc() {
  local cmd="$1"
  echo "$cmd" | grep -qE '\bruby\b[[:space:]]*<<' || return 1
  echo "$cmd" | grep -qE '\bFile\.write\b|\.write\b|\bFile\.open\([^)]*[wa+]|\bFileUtils\.(cp|mv|rm)\b'
}

# 15. Embedded Perl (-e) (#153).
_bdw_match_perl_dash_e() {
  local cmd="$1"
  echo "$cmd" | grep -qE '\bperl[[:space:]]+(-[^e]*[[:space:]]+)?-e\b' || return 1
  # Common perl write idioms: print FH, open(…, ">"), open my $fh, ">", unlink, rename.
  echo "$cmd" | grep -qE '\bprint[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]|\bopen\b[^|;&]*[">]|>>?["[:space:]]|\bunlink\b|\brename\b|\bsysopen\b'
}

# 16. Embedded PHP (-r) (#153).
_bdw_match_php_dash_r() {
  local cmd="$1"
  echo "$cmd" | grep -qE '\bphp[[:space:]]+(-[^r]*[[:space:]]+)?-r\b' || return 1
  echo "$cmd" | grep -qE '\bfile_put_contents\b|\bfwrite\b|\bfopen\([^)]*["'\'']\s*[wa+]|\bunlink\b|\brename\b|\bcopy\b'
}

# 17. Script runners — categorical (#153).
#     `go run <file>`, `deno run <file>` / `deno <file.{ts,js,mjs}>`,
#     `bun <file>` / `bun run <file>`.
_bdw_match_script_runner() {
  local cmd="$1"
  # `go run` followed by anything.
  if echo "$cmd" | grep -qE '\bgo[[:space:]]+run\b'; then
    return 0
  fi
  # `deno run …` (categorical — `deno run` is "execute script").
  if echo "$cmd" | grep -qE '\bdeno[[:space:]]+run\b'; then
    return 0
  fi
  # `deno <script.{ts,js,mjs}>` — bare `deno foo.ts` shorthand.
  if echo "$cmd" | grep -qE '\bdeno[[:space:]]+[^-][^[:space:]]*\.(ts|js|mjs|tsx|jsx)\b'; then
    return 0
  fi
  # `bun run …` or `bun <script.{ts,js,mjs}>`.
  if echo "$cmd" | grep -qE '\bbun[[:space:]]+run\b'; then
    return 0
  fi
  if echo "$cmd" | grep -qE '\bbun[[:space:]]+[^-][^[:space:]]*\.(ts|js|mjs|tsx|jsx)\b'; then
    return 0
  fi
  return 1
}

bash_command_appears_to_write() {
  local cmd="$1"
  [ -z "$cmd" ] && return 1

  # Segment-aware (apexyard#886/#926 round 5) — see
  # _bdw_match_redirection_any_segment for why matching the WHOLE, unsplit
  # command here (as this used to) missed `|`/`||`-adjacent redirects
  # (`false ||> file`, `echo x |> file`).
  _bdw_match_redirection_any_segment "$cmd" && return 0
  _bdw_match_tee             "$cmd" && return 0
  _bdw_match_sed_inplace     "$cmd" && return 0
  _bdw_match_awk_inplace     "$cmd" && return 0
  _bdw_match_file_movers     "$cmd" && return 0
  _bdw_match_tar_extract     "$cmd" && return 0
  _bdw_match_curl_output     "$cmd" && return 0
  _bdw_match_wget_output     "$cmd" && return 0
  _bdw_match_python_dash_c   "$cmd" && return 0
  _bdw_match_python_heredoc  "$cmd" && return 0
  _bdw_match_node_dash_e     "$cmd" && return 0
  _bdw_match_node_heredoc    "$cmd" && return 0
  _bdw_match_ruby_dash_e     "$cmd" && return 0
  _bdw_match_ruby_heredoc    "$cmd" && return 0
  _bdw_match_perl_dash_e     "$cmd" && return 0
  _bdw_match_php_dash_r      "$cmd" && return 0
  _bdw_match_script_runner   "$cmd" && return 0

  return 1
}

# ------------------------------------------------------------------------------
# Public: bash_command_is_deletion_only COMMAND
#
# Returns 0 when the ONLY write-like pattern in the command is `rm` — i.e. the
# command removes files but does NOT add or mutate tracked content via redirect,
# tee, cp/mv, sed -i, interpreters, archive extraction, network writes, etc.
#
# Used by require-active-ticket.sh to exempt bare `rm` calls from the ticket
# gate: deleting a file does not add source content to the repo, so requiring a
# ticket for it is over-blocking.
#
# Returns 0 (deletion only), 1 (content-writing detected or not an rm command).
# ------------------------------------------------------------------------------
bash_command_is_deletion_only() {
  local cmd="$1"
  [ -z "$cmd" ] && return 1

  # Must match _bdw_match_file_movers (covers rm / cp / mv / dd / install).
  _bdw_match_file_movers "$cmd" || return 1

  # cp, mv, dd, install all write content — not deletion-only.
  if echo "$cmd" | grep -qE '(^|[;&|(]|&&|\|\|)[[:space:]]*(cp|mv|dd|install)([[:space:]]|$)'; then
    return 1
  fi

  # Any other content-writing pattern alongside rm → not deletion-only.
  # Segment-aware (apexyard#886/#926 round 5) — same reasoning as
  # bash_command_appears_to_write: matching the whole, unsplit command
  # here would miss `rm x; false ||> src/app.ts` (a real write hiding
  # behind a `|`/`||`-adjacent redirect), wrongly classifying it as
  # deletion-only and exempting it from the ticket gate.
  _bdw_match_redirection_any_segment "$cmd" && return 1
  _bdw_match_tee            "$cmd" && return 1
  _bdw_match_sed_inplace    "$cmd" && return 1
  _bdw_match_awk_inplace    "$cmd" && return 1
  _bdw_match_tar_extract    "$cmd" && return 1
  _bdw_match_curl_output    "$cmd" && return 1
  _bdw_match_wget_output    "$cmd" && return 1
  _bdw_match_python_dash_c  "$cmd" && return 1
  _bdw_match_python_heredoc "$cmd" && return 1
  _bdw_match_node_dash_e    "$cmd" && return 1
  _bdw_match_node_heredoc   "$cmd" && return 1
  _bdw_match_ruby_dash_e    "$cmd" && return 1
  _bdw_match_ruby_heredoc   "$cmd" && return 1
  _bdw_match_perl_dash_e    "$cmd" && return 1
  _bdw_match_php_dash_r     "$cmd" && return 1
  _bdw_match_script_runner  "$cmd" && return 1

  # Only rm matched — deletion-only operation.
  return 0
}

# ------------------------------------------------------------------------------
# Public: bash_extract_write_target COMMAND
#
# Best-effort extraction of the target path from a write command.
# Echoes the target path on success, empty string on failure.
#
# Handles:
#   - cmd > /path/to/file        → /path/to/file
#   - cmd >> /path/to/file       → /path/to/file
#   - tee /path/to/file          → /path/to/file
#   - sed -i 's/.../.../' /path  → /path
#   - cp src /path/to/dst        → /path/to/dst (#153)
#   - mv src /path/to/dst        → /path/to/dst (#153)
#   - curl -o /path URL          → /path        (#153)
#   - wget -O /path URL          → /path        (#153)
#   - cmd <> /path/to/file       → /path/to/file (read-write open, #931)
#
# Does NOT handle (returns empty):
#   - python/node/ruby/perl/php with embedded path
#   - go run / deno / bun (script-runner categorical)
#   - cmd with multiple redirects
#   - paths constructed from variables
#   - tar -x (target is a directory, often implicit)
#   - `cmd >(subshell)` / `cmd <(subshell)` process substitution: NOT a
#     target at all (correctly excluded, #931 — see the leading-`(`
#     exclusion note on _bdw_match_redirection above), so this returns
#     empty for `diff a >(sort)` rather than fabricating `(sort)`.
# ------------------------------------------------------------------------------
bash_extract_write_target() {
  local cmd="$1"
  [ -z "$cmd" ] && return 0

  # Output redirection: capture the first target after >, >>, &>, &>>, >|,
  # >>|, or <>. Strip leading number/ampersand for cases like `2> file` /
  # `&> file`.
  #
  # (^|[^|<&]) — see the identical note on _bdw_match_redirection above
  # (apexyard#886/#926): a command that BEGINS with `>` (e.g. the second
  # half of `echo a > /tmp/ok;> .gitignore` once split on `;`) has no
  # character before the `>`, so the un-anchored `[^|<&]>...` silently
  # failed to match at position 0. Anchoring on start-of-string closes
  # that hole without loosening the `2>&1` / heredoc exclusions.
  #
  # `&>>?` and the trailing `\|?` (apexyard#886/#926 round 3) extend the
  # same anchored pattern to the full write-redirect operator set — see
  # the comment on _bdw_match_redirection for why `&>` can't collide with
  # `2>&1`/`>&2` fd-dup exclusion. The strip sed's `[^>]*` prefix already
  # swallows a leading `&` the same way it swallows a leading digit or
  # space, so no separate strip pattern is needed for `&>`/`&>>`; the
  # trailing `\|?` addition handles `>|`/`>>|`.
  #
  # `[[:space:]]*` (apexyard#886/#926 round 4): whitespace between the
  # operator and the target is optional in real bash (`echo hi>file`,
  # `2>file`, `>>file`, `>|file`, `&>file` are all valid writes) — see the
  # matching note on _bdw_match_redirection for why this doesn't loosen
  # the fd-dup exclusion (the target class still rejects a leading `&`).
  #
  # `[0-9]*<>` (apexyard#886/#931 round 6): the new read-write-open
  # alternative. The strip sed below (`^[^>]*>>?\|?[[:space:]]*`) already
  # handles it correctly with NO changes — `[^>]*` greedily consumes the
  # leading `<` (and any fd digit) up to the FIRST `>`, exactly the same
  # way it already consumes a leading `&` or digit for `&>`/`2>`, so
  # `<>file` strips down to `file` for free. The leading-`(` exclusion on
  # the target class (apexyard#931, same round) also applies here,
  # unchanged, for `diff a >(sort)` → no target.
  local target
  target=$(echo "$cmd" | grep -oE '(&>>?|(^|[^|<&])>>?\|?|[0-9]*<>)[[:space:]]*[^[:space:]&|;(][^[:space:]&|;]*' \
                | head -n 1 \
                | sed -E 's/^[^>]*>>?\|?[[:space:]]*//')
  if [ -n "$target" ]; then
    target="${target%\"}"; target="${target#\"}"
    target="${target%\'}"; target="${target#\'}"
    echo "$target"
    return 0
  fi

  # tee: capture the first non-flag argument after `tee`.
  if echo "$cmd" | grep -qE '\btee\b'; then
    target=$(echo "$cmd" | grep -oE '\btee\b[[:space:]]+(-[^[:space:]]+[[:space:]]+)*[^[:space:]&|;]+' \
                  | head -n 1 \
                  | sed -E 's/^tee[[:space:]]+(-[^[:space:]]+[[:space:]]+)*//')
    if [ -n "$target" ]; then
      target="${target%\"}"; target="${target#\"}"
      target="${target%\'}"; target="${target#\'}"
      echo "$target"
      return 0
    fi
  fi

  # sed -i: capture the file argument (last positional after the script).
  if echo "$cmd" | grep -qE '\bsed[[:space:]]+([^|;&]*[[:space:]])?-i\b'; then
    target=$(echo "$cmd" | sed -E "s/.*'[^']*'[[:space:]]+([^[:space:]&|;]+).*/\1/")
    if echo "$target" | grep -qE '^[A-Za-z0-9./_~-]+$'; then
      echo "$target"
      return 0
    fi
  fi

  # curl -o / --output: capture the path argument (#153).
  if echo "$cmd" | grep -qE '\bcurl\b[^|;&]*(--output\b|-o\b)'; then
    target=$(echo "$cmd" | grep -oE '(--output|-o)[[:space:]]+[^[:space:]&|;]+' \
                  | head -n 1 \
                  | sed -E 's/^(--output|-o)[[:space:]]+//')
    if [ -n "$target" ]; then
      target="${target%\"}"; target="${target#\"}"
      target="${target%\'}"; target="${target#\'}"
      echo "$target"
      return 0
    fi
  fi

  # wget -O / --output-document: same idea (#153).
  if echo "$cmd" | grep -qE '\bwget\b[^|;&]*(--output-document\b|-O\b)'; then
    target=$(echo "$cmd" | grep -oE '(--output-document|-O)[[:space:]]+[^[:space:]&|;]+' \
                  | head -n 1 \
                  | sed -E 's/^(--output-document|-O)[[:space:]]+//')
    if [ -n "$target" ]; then
      target="${target%\"}"; target="${target#\"}"
      target="${target%\'}"; target="${target#\'}"
      echo "$target"
      return 0
    fi
  fi

  # cp / mv: target is the LAST positional argument (#153).
  # Approximate: tokenise on whitespace, strip pipeline tail, take the last
  # non-flag token. Skip this for `git rm`/`git mv` (subcommands).
  if echo "$cmd" | grep -qE '(^|[;&|(]|&&|\|\|)[[:space:]]*(cp|mv)([[:space:]]|$)' \
     && ! echo "$cmd" | grep -qE '^[[:space:]]*git[[:space:]]+(rm|mv)\b'; then
    # Strip everything after a pipeline / list separator to focus on this segment.
    local seg
    seg=$(echo "$cmd" | sed -E 's/[[:space:]]*[|;&].*$//')
    # Take the last whitespace-delimited token of the segment.
    target=$(echo "$seg" | awk '{print $NF}')
    # Reject if it looks like a flag.
    if [ -n "$target" ] && ! echo "$target" | grep -qE '^-'; then
      target="${target%\"}"; target="${target#\"}"
      target="${target%\'}"; target="${target#\'}"
      echo "$target"
      return 0
    fi
  fi

  # No target extractable.
  return 0
}

# ------------------------------------------------------------------------------
# Internal: _bdw_strip_quotes ARG — trim one layer of matching quotes.
# ------------------------------------------------------------------------------
_bdw_strip_quotes() {
  local t="$1"
  t="${t%\"}"; t="${t#\"}"
  t="${t%\'}"; t="${t#\'}"
  printf '%s\n' "$t"
}

# ------------------------------------------------------------------------------
# Internal: _bdw_targets_from_segment SEGMENT
#
# Extracts ALL write targets from a single command segment (a segment is
# one command with no top-level &&, ||, ;, | separators — see
# bash_extract_write_targets below for how segments are produced).
#
# Unlike bash_extract_write_target's single-shot "first match wins" walk,
# this captures EVERY redirection and EVERY tee operand in the segment
# (both families support naming more than one target: `cmd > a 2> b`,
# `tee a b c`), then falls back to bash_extract_write_target for the
# remaining single-target families (sed -i, cp/mv, curl -o, wget -O) —
# correct here because a segment is one command invocation, so "first
# match" and "only match" coincide for those families.
# ------------------------------------------------------------------------------
_bdw_targets_from_segment() {
  local seg="$1"
  local line target tee_tail

  # ALL redirection targets in this segment (not just the first) — covers
  # every write-redirect operator: >, >>, >|, >>|, &>, &>>, and n>/n>> (an
  # fd-numbered redirect, e.g. `2> err.log`, IS a write to err.log).
  #
  # (^|[^|<&]) — apexyard#886/#926 (Hakim security review, PR #926): a
  # segment produced by bash_extract_write_targets' top-level split can
  # itself BEGIN with `>` — e.g. splitting `echo a > /tmp/ok;> .gitignore`
  # on `;` yields a second segment of `> .gitignore`. The un-anchored
  # `[^|<&]>...` requires a character before `>` to exist, so it silently
  # dropped every no-space-after-separator redirection (`;>`, `&&>`, `|>`,
  # `||>`). Anchoring on start-of-segment closes that hole while leaving
  # the `2>&1` / heredoc exclusions untouched (neither begins a segment
  # with a bare `>`).
  #
  # `&>>?` and the trailing `\|?` (apexyard#886/#926 round 3): Hakim's
  # adversarial re-hunt found this pattern still missed `&>`/`&>>`
  # (redirect-both-streams) and `>|`/`>>|` (force-clobber) — both real
  # destructive writes. `&>` is unambiguous against `2>&1`/`>&2` fd-dup
  # because the `&` precedes the `>` here, never follows it. `>|`/`>>|`
  # need the SEGMENT to still contain the literal `|` — see
  # bash_extract_write_targets' clobber-protection step, which shields
  # these operators from the later bare-`|` (pipe) split.
  #
  # `[[:space:]]*` (apexyard#886/#926 round 4): a FOURTH re-hunt found the
  # mandatory whitespace after the operator was itself a bypass — bash
  # accepts zero whitespace (`echo hi>file`, `2>file`, `&>file`, `>|file`
  # are all real writes). Relaxed to optional; the target class
  # `[^[:space:]&|;]+` still rejects a leading `&`, so `2>&1`/`>&2`
  # (fd-dup) stay correctly unmatched regardless of spacing.
  #
  # `[0-9]*<>` and the leading-`(` target exclusion (apexyard#886/#931
  # round 6): same two additions as _bdw_match_redirection and
  # bash_extract_write_target above — `<>` (read-write open) is now a
  # recognised operator (the unchanged strip-sed already handles it, since
  # `[^>]*` swallows the leading `<`/digit the same way it swallows a
  # leading `&`), and a leading `(` after the operator is excluded so
  # `diff a >(sort)` (process substitution) no longer contributes the
  # bogus target `(sort)`.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    target=$(printf '%s\n' "$line" | sed -E 's/^[^>]*>>?\|?[[:space:]]*//')
    [ -n "$target" ] && _bdw_strip_quotes "$target"
  done < <(printf '%s\n' "$seg" | grep -oE '(&>>?|(^|[^|<&])>>?\|?|[0-9]*<>)[[:space:]]*[^[:space:]&|;(][^[:space:]&|;]*')

  # ALL tee operands in this segment — `tee a b c` names three targets, not
  # one; the original single-target extractor only ever returned "a".
  #
  # NOTE: extraction deliberately uses grep (not sed) for the `\btee\b`
  # word-boundary match. BSD sed (macOS's default, non-GNU) silently does
  # NOT support `\b` in its regex engine — a `sed -E 's/^.*\btee\b.../'`
  # here would no-op on a stock Mac and this bug would ship invisible on
  # this exact platform. grep's `\b` support is fine (BSD grep is
  # GNU-compatible on this point); the strip-the-"tee"-token step below
  # uses plain anchored parameter expansion instead of sed, sidestepping
  # the incompatibility entirely.
  if printf '%s\n' "$seg" | grep -qE '\btee\b'; then
    tee_tail=$(printf '%s\n' "$seg" | grep -oE '\btee\b[[:space:]].*' | head -n 1)
    tee_tail="${tee_tail#tee}"
    local skip_flags=1
    for target in $tee_tail; do
      if [ "$skip_flags" = "1" ] && printf '%s' "$target" | grep -qE '^-'; then
        continue
      fi
      skip_flags=0
      # Stop consuming tee's operand list once a redirection operator
      # token appears (Rex review, PR #926): `tee a b 2> err.log` — the
      # `2>` starts a shell redirect of tee's OWN stdout/stderr, not
      # another tee file argument. Without this, naive whitespace
      # word-splitting would emit the operator token itself (e.g. the
      # literal string "2>") as a spurious "target". Not a bypass either
      # way — the real redirect target ("err.log") is still independently
      # captured by the redirection-matching loop above, so this only
      # tightens the gate (fail-closed on a garbage path) rather than
      # missing anything.
      printf '%s' "$target" | grep -qE '^[0-9]*(>>?|<<?)' && break
      [ -n "$target" ] && _bdw_strip_quotes "$target"
    done
  fi

  # sed -i / cp / mv / curl -o / wget -O: single-target families. Reusing
  # the existing single-shot extractor on just THIS segment is correct —
  # a segment is one command, so "first match in the segment" IS "the
  # match". (This may re-emit a redirection/tee target already captured
  # above; bash_extract_write_targets dedupes the combined output.)
  target=$(bash_extract_write_target "$seg")
  [ -n "$target" ] && printf '%s\n' "$target"
}

# ------------------------------------------------------------------------------
# Public: bash_extract_write_targets COMMAND
#
# See the header comment block at the top of this file for the contract.
# Returns via stdout (one target per line); no meaningful exit-code
# contract beyond "ran".  An empty COMMAND or a command with zero
# extractable targets produces no output at all — callers must treat
# "nothing on stdout" as the same fail-closed/categorical case that empty
# bash_extract_write_target output signals today.
#
# Segmentation is delegated to _bdw_split_top_level (apexyard#886/#926
# round 5) — the SAME function bash_command_appears_to_write's
# _bdw_match_redirection_any_segment uses, so detection and extraction
# share one source of truth for "where does one command end and the next
# begin" and can't drift apart again.
# ------------------------------------------------------------------------------
bash_extract_write_targets() {
  local cmd="$1"
  [ -z "$cmd" ] && return 0

  local seg
  {
    while IFS= read -r seg; do
      [ -z "$seg" ] && continue
      _bdw_targets_from_segment "$seg"
    done < <(_bdw_split_top_level "$cmd")
  } | awk '!seen[$0]++'
}
