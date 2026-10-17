#!/bin/bash

# Scans staged files for hardcoded secrets before git commit.
# Blocks the commit if potential secrets are detected in the diff.

# Run one target check. The visitor isolates each call in a subshell.
_git_gate_body() {
INPUT="$_GIT_GATE_INPUT"
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -r "$HOOK_DIR/_lib-git-global.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOOK_DIR/_lib-git-global.sh"
fi

if [ -z "$COMMAND" ]; then
  . "$(dirname "$0")/_lib-fail-closed-json.sh"
  _secrets_pat='git[[:space:]]+commit'
  if command -v git_subcommand_payload_pattern >/dev/null 2>&1; then
    _secrets_pat="$(git_subcommand_payload_pattern commit)"
  fi
  if raw_payload_command_matches "$INPUT" "$_secrets_pat"; then
    echo "BLOCKED: secrets hook cannot parse this commit command. Restore jq and retry so staged content can be scanned." >&2
    exit 2
  fi
  exit 0
fi

# Only check on git commit. Global options such as -C and -c sit between
# git and commit (#1731).
if command -v command_has_git_subcommand >/dev/null 2>&1; then
  command_has_git_subcommand "$COMMAND" commit || exit 0
elif ! echo "$COMMAND" | grep -qE '\bgit\s+commit\b'; then
  exit 0
fi

PAYLOAD_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // .tool_input.cwd // empty' 2>/dev/null || true)
if command -v git_prepare_invocation >/dev/null 2>&1; then
  git_prepare_invocation "$COMMAND" commit "$PAYLOAD_CWD"
fi

# Check staged files for secret patterns. macOS-compatible regex.
# -C selects the index git will commit, not the hook process directory.
if command -v git_target >/dev/null 2>&1; then
  SECRETS_FOUND=$(git_target diff --cached --diff-filter=ACMR -U0 2>/dev/null | grep -iE "(api[_-]?key|api[_-]?secret|password|passwd|secret[_-]?key|access[_-]?token|private[_-]?key|client[_-]?secret)[[:space:]]*[:=][[:space:]]*[\"'][^\"']{8,}" | grep -v '^\-' | head -5)
else
  SECRETS_FOUND=$(git diff --cached --diff-filter=ACMR -U0 2>/dev/null | grep -iE "(api[_-]?key|api[_-]?secret|password|passwd|secret[_-]?key|access[_-]?token|private[_-]?key|client[_-]?secret)[[:space:]]*[:=][[:space:]]*[\"'][^\"']{8,}" | grep -v '^\-' | head -5)
fi

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

}

_GIT_GATE_INPUT=$(cat)
_GIT_GATE_LIB="$(cd "$(dirname "$0")" && pwd)/_lib-git-global.sh"
if [ -r "$_GIT_GATE_LIB" ]; then
  # shellcheck disable=SC1090
  . "$_GIT_GATE_LIB"
fi
if command -v git_visit_invocations >/dev/null 2>&1; then
  git_visit_invocations _git_gate_body block "$_GIT_GATE_INPUT" commit
  exit $?
fi
_git_gate_body
