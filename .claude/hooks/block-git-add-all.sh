#!/bin/bash
# Blocks: git add -A, git add ., git add --all
# Rationale: these commands stage every modified file in the working tree,
# including unintended ones (.env, credentials, generated artifacts, scratch
# files). Always add specific files by name.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  . "$(dirname "$0")/_lib-fail-closed-json.sh"
  if raw_payload_command_matches "$INPUT" 'git[[:space:]]+add[[:space:]]+(-A|--all|\.)'; then
    echo "BLOCKED: staging guard cannot parse this git add command. Restore jq and retry." >&2
    exit 2
  fi
  exit 0
fi

# The match must land on a COMMAND position, not only at the start of the
# whole call (me2resh/apexyard#2071). `cd src && git add -A`,
# `echo hi; git add -A`, `FOO=1 git add -A`, `sudo git add -A`, a `bash -c`
# wrapper and a multi-line script each reach the same staging command.
# A quoted mention — a commit message, a printf payload, a PR body — stays
# allowed, because the `git` there follows a quote rather than a separator.
# A heredoc body is NOT stripped before this check: the governance rule in
# _lib-strip-heredoc.sh forbids deciding whether a gate fires from stripped
# text, so a body line that starts with `git add -A` still blocks. Write the
# message with `-F <file>`, or quote the mention.
_add_flag='(-A|--all|\.)'
_add_tail='([[:space:];&|)]|$)'
_add_pos='(^[[:space:]]*|[;&|({][[:space:]]*|[[:space:]](then|do|else)[[:space:]]+)'
_add_prefix='((sudo|env|command|nohup|time|exec|builtin)[[:space:]]+)*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
_add_git='git[[:space:]]+((-[Cc]|--git-dir|--work-tree)[[:space:]]+[^[:space:];&|]+[[:space:]]+)*add[[:space:]]+'"${_add_flag}${_add_tail}"
_add_wrapped="${_add_pos}${_add_prefix}(bash|sh|zsh|dash)([[:space:]]+-[A-Za-z-]+)*[[:space:]]+-[A-Za-z]*c[A-Za-z]*[[:space:]]+.*git[[:space:]]+add[[:space:]]+${_add_flag}"

if printf '%s' "$COMMAND" | grep -qE "${_add_pos}${_add_prefix}${_add_git}" \
  || printf '%s' "$COMMAND" | grep -qE "${_add_wrapped}"; then
  cat >&2 <<MSG
BLOCKED: 'git add -A', 'git add --all', and 'git add .' are forbidden.

These commands stage every modified file in the working tree —
including .env files, credentials, generated artifacts, scratch
files, and partially-edited unrelated work. ApexYard requires
explicit file selection on every stage (.claude/rules/git-conventions.md
§ "File Staging").

To unblock:
  1. List the changed files: git status --short
  2. Stage each file you intend to commit by name:
       git add path/to/file1 path/to/file2
  3. Verify the staged set: git diff --cached --stat
  4. Retry the commit

If you have many files in the same change, group by directory:
       git add src/auth/ src/billing/
That's still explicit (you typed the path) and still safe.

The one common exception — staging all files under a single feature
directory after a refactor — is fine via the directory form above.
There's no exception for whole-tree staging.
MSG
  exit 2
fi

exit 0
