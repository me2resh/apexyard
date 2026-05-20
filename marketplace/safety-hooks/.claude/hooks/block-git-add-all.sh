#!/bin/bash
# Blocks: git add -A, git add ., git add --all
# Rationale: these commands stage every modified file in the working tree,
# including unintended ones (.env, credentials, generated artifacts, scratch
# files). Always add specific files by name.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

if echo "$COMMAND" | grep -qE '\bgit\s+add\s+(-A|--all|\.)(\s|$)'; then
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
