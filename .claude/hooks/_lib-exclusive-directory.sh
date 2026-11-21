#!/bin/bash
# Create a lock directory under an exclusive file guard. Bash 3.2.
# Noclobber uses O_EXCL. mkdir success alone does not establish ownership.
exclusive_directory_create() (
  local directory=$1 guard="$1.creating"
  (set -C; : > "$guard") 2>/dev/null || return 1
  trap 'rm -f -- "$guard"' EXIT
  trap 'exit 1' HUP INT TERM
  [ ! -e "$directory" ] && [ ! -L "$directory" ] || return 1
  mkdir "$directory"
)
