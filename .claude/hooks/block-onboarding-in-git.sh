#!/bin/bash

# Blocks committing a filled-in onboarding.yaml — the Layer-2 backstop for the
# example-file + gitignore model (#517 / AgDR-0064).
#
# onboarding.yaml is gitignored (real, local config). This guard catches the
# cases gitignore can't: a force-add (`git add -f onboarding.yaml`), or a
# pre-#517 clone where the file is still tracked. It uses a placeholder-diff
# signal — comparing the staged onboarding.yaml against the shipped
# onboarding.example.yaml placeholders — so a pristine template copy is allowed
# but a filled-in one (real company name, internal URLs, named individuals,
# tracker instances) is blocked before it can reach a public fork or upstream PR.
#
# Sibling to check-secrets.sh (catches credentials) and
# block-private-refs-in-public-repos.sh (catches private project names in
# upstream tickets) — same "scan outgoing content for things that should never
# leave local" shape, wired to git-commit time.
#
# Escape hatch (rare, legitimate — e.g. intentionally re-seeding a template):
#   - env var:    APEXYARD_ALLOW_ONBOARDING_COMMIT=1
#   - in-message: include  <!-- onboarding: allow -->  in the commit message

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
  _onboard_pat='git[[:space:]]+commit'
  if command -v git_subcommand_payload_pattern >/dev/null 2>&1; then
    _onboard_pat="$(git_subcommand_payload_pattern commit)"
  fi
  if raw_payload_command_matches "$INPUT" "$_onboard_pat"; then
    echo "BLOCKED: onboarding guard cannot parse this commit command. Restore jq and retry." >&2
    exit 2
  fi
  exit 0
fi

# Only check on git commit. Global options may sit between git and commit.
if command -v command_has_git_subcommand >/dev/null 2>&1; then
  command_has_git_subcommand "$COMMAND" commit || exit 0
else
  echo "$COMMAND" | grep -qE '\bgit\s+commit\b' || exit 0
fi

# Escape hatches
if [ "${APEXYARD_ALLOW_ONBOARDING_COMMIT:-}" = "1" ]; then
  echo "WARN: onboarding-in-git guard bypassed via APEXYARD_ALLOW_ONBOARDING_COMMIT=1" >&2
  exit 0
fi
if echo "$COMMAND" | grep -q '<!-- onboarding: allow -->'; then
  echo "WARN: onboarding-in-git guard bypassed via '<!-- onboarding: allow -->' marker" >&2
  exit 0
fi

PAYLOAD_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // .tool_input.cwd // empty' 2>/dev/null || true)
if command -v git_prepare_invocation >/dev/null 2>&1; then
  git_prepare_invocation "$COMMAND" commit "$PAYLOAD_CWD"
fi
if command -v git_target >/dev/null 2>&1; then
  REPO_ROOT=$(git_target rev-parse --show-toplevel 2>/dev/null)
else
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
fi
[ -z "$REPO_ROOT" ] && exit 0

# Is onboarding.yaml staged for this commit? Use -F (fixed string) so the '.'
# is a literal dot, not a regex wildcard — '-x' already anchors the whole line.
if command -v git_target >/dev/null 2>&1; then
  STAGED=$(git_target diff --cached --name-only --diff-filter=ACMR 2>/dev/null)
else
  STAGED=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)
fi
echo "$STAGED" | grep -Fxq 'onboarding.yaml' || exit 0

# Placeholder-diff: if the staged onboarding.yaml is byte-identical to the
# shipped example template, it carries no real values → allow. Otherwise it's
# a filled-in template → block.
EXAMPLE="$REPO_ROOT/onboarding.example.yaml"
if command -v git_target >/dev/null 2>&1; then
  STAGED_CONTENT=$(git_target show ":onboarding.yaml" 2>/dev/null)
else
  STAGED_CONTENT=$(git show ":onboarding.yaml" 2>/dev/null)
fi
if [ -f "$EXAMPLE" ] && [ "$STAGED_CONTENT" = "$(cat "$EXAMPLE")" ]; then
  exit 0
fi

cat >&2 <<MSG
BLOCKED: onboarding.yaml is staged for commit with non-placeholder values.

onboarding.yaml holds your private configuration (company name, internal URLs,
tracker instance, named individuals) and must stay LOCAL — it is gitignored by
design (#517). Committing it would publish private config to a public fork or
an upstream pull request, where it is indexed forever.

To unblock:
  1. Unstage it:        git restore --staged onboarding.yaml
  2. Confirm it's ignored: grep -q '^onboarding.yaml' .gitignore || echo 'onboarding.yaml' >> .gitignore
  3. If a teammate needs the SHAPE of the config, edit onboarding.example.yaml
     (placeholders only) and commit THAT instead.
  4. Retry the commit.

If you are on a pre-#517 clone where onboarding.yaml is still TRACKED, untrack
it once with:  git rm --cached onboarding.yaml  (keeps your local copy).

Escape hatch (rare — e.g. deliberately re-seeding a pristine template):
  APEXYARD_ALLOW_ONBOARDING_COMMIT=1 git commit ...
  or add  <!-- onboarding: allow -->  to the commit message.

Guard source: .claude/hooks/block-onboarding-in-git.sh — sibling to
check-secrets.sh. Config leaks are worse than the friction of unstaging.
MSG
exit 2

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
