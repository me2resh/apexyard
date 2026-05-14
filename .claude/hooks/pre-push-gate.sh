#!/bin/bash
# pre-push-gate.sh — blocks `git push` on red local checks.
#
# Upgraded from an advisory reminder (pre-#111) to a blocking check-runner:
# reads a list of shell commands from `.claude/project-config.*.json`
# (`.pre_push.commands`) and runs them in sequence before the push is
# allowed through. Non-zero exit from any command blocks the push.
#
# This implements the HARD STOP documented in `.claude/rules/pr-workflow.md`
# — "Never push without running CI checks locally." Previously the rule
# was self-discipline; now it's mechanical.
#
# Silent pass conditions (exit 0, no output):
#   - Not a `git push` command.
#   - No `.claude/project-config.defaults.json` AND no `package.json` in the
#     repo → treat as a non-runnable repo (docs-only, newly-forked, etc.).
#   - HEAD commit subject contains the skip marker `<!-- pre-push: skip -->`
#     → emergency escape hatch; prints a visible WARN and lets the push
#     through. Leaves a grep-able trace so bypasses are auditable.
#
# Configured commands (example, from the shipped defaults):
#   - lint:      npm run lint
#   - typecheck: npm run typecheck
#   - test:      npm run test
#   - build:     npm run build
#
# Skip marker: include the literal string `<!-- pre-push: skip -->` in the
# HEAD commit message (subject or body) to bypass for that one push.
# The hook prints the bypassed command set to stderr so the skip is visible.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

if ! echo "$COMMAND" | grep -qE '\bgit\s+push\b'; then
  exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Skip marker — check HEAD commit message for the escape hatch.
# ---------------------------------------------------------------------------

SKIP_MARKER='<!-- pre-push: skip -->'
HEAD_MSG=$(cd "$REPO_ROOT" && git log -1 --format='%B' 2>/dev/null)
if echo "$HEAD_MSG" | grep -qF -- "$SKIP_MARKER"; then
  echo "WARN: pre-push gate bypassed by skip marker in HEAD commit message." >&2
  echo "      Skipped commands will run in CI regardless — fix broken state before merging." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Load command list from project config via the shared reader.
# Shipped defaults ship at .claude/project-config.defaults.json.
# See docs/project-config.md and apexyard#109.
# ---------------------------------------------------------------------------

CMDS_JSON=""
if [ -f "$REPO_ROOT/.claude/hooks/_lib-read-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$REPO_ROOT/.claude/hooks/_lib-read-config.sh"
  # Produce a JSON array of {name, run} objects.
  CMDS_JSON=$(config_get '.pre_push.commands' 2>/dev/null)
fi

# Check that the config actually contains commands. Silent skip if not —
# the hook is a no-op on repos that haven't configured any (docs-only
# repos, newly forked skeletons, the apexyard framework repo itself before
# it configures its own CI in a separate ticket).
if [ -z "$CMDS_JSON" ] || [ "$CMDS_JSON" = "null" ] || [ "$CMDS_JSON" = "[]" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Run each command. On first non-zero, block with a summary.
# ---------------------------------------------------------------------------

cd "$REPO_ROOT" || exit 0

FAILURES=""
NUM_CMDS=$(echo "$CMDS_JSON" | jq 'length' 2>/dev/null)
if [ -z "$NUM_CMDS" ] || [ "$NUM_CMDS" = "null" ]; then
  exit 0
fi

i=0
while [ "$i" -lt "$NUM_CMDS" ]; do
  NAME=$(echo "$CMDS_JSON" | jq -r ".[$i].name // \"step-$i\"" 2>/dev/null)
  RUN=$(echo "$CMDS_JSON" | jq -r ".[$i].run // empty" 2>/dev/null)
  i=$((i + 1))

  if [ -z "$RUN" ]; then
    continue
  fi

  # Run each command capturing last 20 lines for the error report.
  TMP_LOG=$(mktemp -t pre-push-gate.XXXXXX)
  if bash -c "$RUN" >"$TMP_LOG" 2>&1; then
    rm -f "$TMP_LOG"
    continue
  fi

  # Command failed — accumulate a summary. Keep the log for the final
  # block message; clean up after we print.
  TAIL=$(tail -20 "$TMP_LOG" 2>/dev/null)
  rm -f "$TMP_LOG"

  FAILURES="${FAILURES}${NAME}: FAILED
  command: ${RUN}
  last 20 lines of output:
${TAIL}

"
  # Fail-fast: don't keep running subsequent commands once one has failed.
  # (Parallel execution is a follow-up — ticket notes it as a P2 polish.)
  break
done

if [ -n "$FAILURES" ]; then
  cat >&2 <<MSG
BLOCKED: pre-push-gate detected failing check(s). Fix before pushing.

${FAILURES}
To override for a genuine emergency (the fix will run in CI regardless):
  git commit --amend -m "\$(git log -1 --format=%B)
  ${SKIP_MARKER}"

The skip marker is grep-able on purpose — bypasses should be rare and
auditable. See .claude/rules/pr-workflow.md "Before git push (HARD STOP)".
MSG
  exit 2
fi

exit 0
