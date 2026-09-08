#!/bin/bash
# Scan complete staged file contents for private portfolio references.
set -u
INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
if [ -z "$COMMAND" ]; then
  # shellcheck source=/dev/null
  . "$(dirname "$0")/_lib-fail-closed-json.sh"
  if raw_payload_command_matches "$INPUT" 'git[[:space:]]+commit'; then
    echo "BLOCKED: staged private-reference hook cannot parse this commit. Restore jq and retry." >&2
    exit 2
  fi
  exit 0
fi
printf '%s' "$COMMAND" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+commit([[:space:]]|$)' || exit 0
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
if [ -f "$ROOT/.claude/hooks/_lib-portfolio-paths.sh" ]; then
  # shellcheck source=/dev/null
  . "$ROOT/.claude/hooks/_lib-portfolio-paths.sh"
fi
REGISTRY=$(portfolio_registry 2>/dev/null || true)
[ -f "$REGISTRY" ] || exit 0
TOKENS=$(awk '/^[[:space:]]*(name|workspace):[[:space:]]*/ { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/["'"'"' ]/, ""); if (length($0) >= 3) print $0 } /^[[:space:]]*repo:[[:space:]]*/ { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/["'"'"' ]/, ""); split($0, a, "/"); for (i in a) if (length(a[i]) >= 3) print a[i]; print $0 }' "$REGISTRY" | sort -u)
[ -n "$TOKENS" ] || exit 0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  content=$(git show ":$path" 2>/dev/null) || continue
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    if printf '%s' "$content" | grep -Fq -- "$token"; then
      echo "BLOCKED: staged file content contains a private portfolio reference." >&2
      echo "File: $path" >&2
      echo "Move the reference to an abstract name, unstage the file, and retry." >&2
      exit 2
    fi
  done < <(printf '%s\n' "$TOKENS")
done < <(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)
exit 0
