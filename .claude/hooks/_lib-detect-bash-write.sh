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
#     target=$(bash_extract_write_target "$COMMAND")
#     # ... apply gate, optionally with target-aware path exemptions
#   fi
#
# Exposed functions:
#   bash_command_appears_to_write COMMAND
#       returns 0 if the command appears to write to a file, 1 otherwise
#
#   bash_extract_write_target COMMAND
#       echoes the target path if extractable, empty string otherwise.
#       Best-effort — only handles the simple cases (echo > file,
#       tee file, sed -i ... file, cp src dst, curl -o file). Embedded
#       interpreters (python -c, node -e, ruby -e, perl -e, php -r,
#       go run, deno, bun) return empty.

# ------------------------------------------------------------------------------
# Public: bash_command_appears_to_write COMMAND
#
# Detects (matcher families):
#
#   Redirection / pipes-to-disk
#     - cmd > file, cmd >> file, cmd 2> file
#     - tee
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
_bdw_match_redirection() {
  echo "$1" | grep -qE '[^|<&]>>?[[:space:]]+[^[:space:]&|;]+'
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

  _bdw_match_redirection     "$cmd" && return 0
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
#
# Does NOT handle (returns empty):
#   - python/node/ruby/perl/php with embedded path
#   - go run / deno / bun (script-runner categorical)
#   - cmd with multiple redirects
#   - paths constructed from variables
#   - tar -x (target is a directory, often implicit)
# ------------------------------------------------------------------------------
bash_extract_write_target() {
  local cmd="$1"
  [ -z "$cmd" ] && return 0

  # Output redirection: capture the first target after > or >>.
  # Strip leading number for cases like `2> file`.
  local target
  target=$(echo "$cmd" | grep -oE '[^|<&]>>?[[:space:]]+[^[:space:]&|;]+' \
                | head -n 1 \
                | sed -E 's/^[^>]*>>?[[:space:]]+//')
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
