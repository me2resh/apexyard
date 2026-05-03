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
#       tee file, sed -i ... file). Embedded interpreters
#       (python -c, node -e, ruby -e) return empty.

# ------------------------------------------------------------------------------
# Public: bash_command_appears_to_write COMMAND
#
# Detects:
#   - Output redirection: cmd > file, cmd >> file, cmd 2> file
#   - tee
#   - cat > file (with or without heredoc)
#   - printf > file
#   - sed -i (in-place edit)
#   - awk -i inplace
#   - python -c '...write...' or python -c '...open(...).write...'
#   - python <<EOF ... write ... EOF (heredoc-fed python)
#   - python3 - <<EOF ... write ... EOF (stdin-fed python — common pattern)
#   - node -e '...writeFileSync...' or node -e '...write...'
#   - ruby -e '...File.write...' or ruby -e '...write...'
#
# Misses (intentionally — long tail):
#   - cp, mv, rm (those move/remove, not "write content")
#   - xargs that constructs a write command
#   - find -exec sed/awk/etc.
#   - Custom scripts that wrap writes (could be anything)
#   - Bash builtins like `read VAR < file` (that's a read, anyway)
#
# Returns 0 (write detected), 1 (no write detected).
# ------------------------------------------------------------------------------
bash_command_appears_to_write() {
  local cmd="$1"
  [ -z "$cmd" ] && return 1

  # Output redirection. Match `> file`, `>> file`, `2> file`, etc.
  # Excludes `<>` (read-write open, rare) and `&>` (combined redirect — also
  # a write but our regex catches the trailing `>`).
  if echo "$cmd" | grep -qE '[^|<&]>>?[[:space:]]+[^[:space:]&|;]+'; then
    return 0
  fi

  # `tee` — writes to its arguments.
  if echo "$cmd" | grep -qE '\btee\b'; then
    return 0
  fi

  # `sed -i` — in-place edit. Catch `-i` and `-i ''` (BSD/macOS form).
  if echo "$cmd" | grep -qE '\bsed[[:space:]]+([^|;&]*[[:space:]])?-i\b'; then
    return 0
  fi

  # `awk -i inplace`
  if echo "$cmd" | grep -qE '\bawk[[:space:]]+[^|;&]*-i[[:space:]]+inplace\b'; then
    return 0
  fi

  # Embedded Python: `python -c '...write...'` or `python3 -c '...'`.
  # Look for write/open keywords inside the command string.
  if echo "$cmd" | grep -qE '\bpython3?[[:space:]]+(-[^c]*[[:space:]]+)?-c\b' && \
     echo "$cmd" | grep -qE '\.write_text\b|\.write\b|\bopen\([^)]*[wa+]'; then
    return 0
  fi

  # Heredoc-fed Python: `python3 <<EOF ... write ... EOF` or `python3 - <<EOF`.
  # If the command contains `python` followed by `<<` or `-` and then any
  # write keyword, treat as a write.
  if echo "$cmd" | grep -qE '\bpython3?[[:space:]]+(-[[:space:]]+)?<<' && \
     echo "$cmd" | grep -qE '\.write_text\b|\.write\b|\bopen\([^)]*[wa+]'; then
    return 0
  fi

  # Embedded Node: `node -e '...writeFileSync...'` etc.
  if echo "$cmd" | grep -qE '\bnode[[:space:]]+(-[^e]*[[:space:]]+)?-e\b' && \
     echo "$cmd" | grep -qE '\bwriteFile(Sync)?\b|\.write\b|\bappendFile(Sync)?\b'; then
    return 0
  fi

  # Embedded Ruby: `ruby -e '...File.write...'`.
  if echo "$cmd" | grep -qE '\bruby[[:space:]]+(-[^e]*[[:space:]]+)?-e\b' && \
     echo "$cmd" | grep -qE '\bFile\.write\b|\.write\b|\bFile\.open\([^)]*[wa+]'; then
    return 0
  fi

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
#
# Does NOT handle (returns empty):
#   - python/node/ruby with embedded path
#   - cmd with multiple redirects
#   - paths constructed from variables
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
    # Strip surrounding quotes if any.
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
  # This is approximate — sed's argument grammar is annoying.
  if echo "$cmd" | grep -qE '\bsed[[:space:]]+([^|;&]*[[:space:]])?-i\b'; then
    # Take everything after the last quote-pair in the sed invocation.
    target=$(echo "$cmd" | sed -E "s/.*'[^']*'[[:space:]]+([^[:space:]&|;]+).*/\1/")
    # Heuristic: only accept if it looks like a path (contains / or starts with
    # an alphanumeric, doesn't contain quote chars).
    if echo "$target" | grep -qE '^[A-Za-z0-9./_~-]+$'; then
      echo "$target"
      return 0
    fi
  fi

  # No target extractable.
  return 0
}
