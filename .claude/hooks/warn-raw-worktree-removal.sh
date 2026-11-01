#!/bin/bash
# PreToolUse advisory for one literal Bash command shape (AgDR-0287).
# No shell parsing or Git calls. Every path exits 0.

COMMAND=$(jq -Rers '
  select(index("\u0000") == null)
  | fromjson
  | select(type == "object" and .tool_name == "Bash")
  | .tool_input | select(type == "object")
  | .command | select(type == "string" and length > 0)
  | select(index("\u0000") == null)
' 2>/dev/null) || exit 0

# Trim surrounding whitespace only. Internal newlines cannot match below.
COMMAND=${COMMAND#"${COMMAND%%[![:space:]]*}"}
COMMAND=${COMMAND%"${COMMAND##*[![:space:]]}"}

# Literal, unquoted paths only. The positive character set excludes shell
# operators, quotes, substitutions, escapes, comments, and glob patterns.
# A path must not start with a dash, so an option alone is not a target.
path='[[:alnum:]_./:@%+=,][[:alnum:]_./:@%+=,-]*'
shape="^git[[:blank:]]+(-C[[:blank:]]+${path}[[:blank:]]+)?worktree[[:blank:]]+remove[[:blank:]]+(-[[:alnum:]-]+[[:blank:]]+)*${path}$"
if [[ "$COMMAND" =~ $shape ]]; then
  cat >&2 <<'BANNER'
Warning: raw worktree removal skips the owner check and preservation check.
  A live or unknown owner may still be writing.
  The worktree may contain uncommitted or unpushed work.
  Use /approve-merge cleanup or remove-worktree.sh to check both before removal.
BANNER
fi

exit 0
