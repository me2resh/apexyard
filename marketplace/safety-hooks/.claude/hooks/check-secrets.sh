#!/bin/bash
# Scans staged files for hardcoded secrets before git commit.
# Blocks the commit if potential secrets are detected in the diff.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Only check on git commit
if ! echo "$COMMAND" | grep -qE '\bgit\s+commit\b'; then
  exit 0
fi

# Check staged files for secret patterns. macOS-compatible regex.
SECRETS_FOUND=$(git diff --cached --diff-filter=ACMR -U0 2>/dev/null | grep -iE "(api[_-]?key|api[_-]?secret|password|passwd|secret[_-]?key|access[_-]?token|private[_-]?key|client[_-]?secret)[[:space:]]*[:=][[:space:]]*[\"'][^\"']{8,}" | grep -v '^\-' | head -5)

if [ -n "$SECRETS_FOUND" ]; then
  cat >&2 <<MSG
BLOCKED: Potential hardcoded secrets detected in staged files.

Matches (max 5 shown):
$SECRETS_FOUND

ApexYard's no-hardcoded-secrets rule (.claude/rules/git-conventions.md
§ "No Hardcoded Secrets"). Secrets in commits are forever — even after
removal the value lives in the reflog and on any clone that's been
fetched.

To unblock:
  1. Move each secret value into an environment variable, read it via
     process.env / os.environ / etc. in code, and add the var name to
     your .env.example or equivalent (a placeholder, NOT the real value)
  2. Add the real .env to .gitignore if it isn't already
  3. Unstage the file: git restore --staged <file>
  4. Edit the file to use the env var, then re-stage: git add <file>
  5. Retry the commit

If the match is a false positive (e.g. a test fixture, a literal in a
markdown code block, or a public-by-design API key constant):
  - Refactor so the value isn't on a line matching the secret-pattern
    regex (rename the variable, or move to a fixtures file), OR
  - Add a one-line comment above the line explaining why it's safe and
    retry. The hook only matches actual secret-shape lines; comments
    don't trip it.

Pattern source: .claude/hooks/check-secrets.sh (the regex is
intentionally noisy on the false-positive side — secret leaks are
worse than extra friction).
MSG
  exit 2
fi

exit 0
