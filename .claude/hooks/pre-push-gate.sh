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

# Recognise `git push` and the `git -C <dir> push` form the scoping fix
# below reads a target directory from (me2resh/apexyard#1366). A bare
# `\bgit\s+push\b` check, alone, never matches the `-C` form at all — the
# scoping logic further down would be unreachable dead code for it.
IS_PUSH=0
if echo "$COMMAND" | grep -qE '\bgit\s+push\b'; then
  IS_PUSH=1
elif echo "$COMMAND" | grep -qE '\bgit\s+-C\s+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|]+)\s+push\b'; then
  IS_PUSH=1
fi
if [ "$IS_PUSH" -ne 1 ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve the repo being pushed, not the session's cwd (me2resh/apexyard#1366).
#
# A portfolio session's cwd is often the ops fork while the push itself
# targets a sibling managed-project clone, via `git -C <dir> push` or a
# `cd <dir> &&` prefix. Reading the target directory out of the command,
# instead of assuming $PWD, is the same extraction shape
# block-main-push.sh added for #1230 — this hook keeps its own copy
# because the two hooks ask different questions (a skip-check there, the
# actual run target here), so sharing one function would couple them.
#
# `git -C <dir> push` wins over a `cd` prefix when both appear (it names
# the target more precisely). Neither present: fall back to $PWD, the
# pre-#1366 behaviour, unchanged for the common single-repo session.
# ---------------------------------------------------------------------------
PUSH_TARGET_DIR="$PWD"
if echo "$COMMAND" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+-C[[:space:]]+[^[:space:];&|]+'; then
  PUSH_TARGET_DIR=$(echo "$COMMAND" \
    | grep -oE "git[[:space:]]+-C[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:];&|]+)" \
    | tail -n 1 \
    | sed -E "s/^git[[:space:]]+-C[[:space:]]+//; s/^[\"']//; s/[\"']\$//")
  case "$PUSH_TARGET_DIR" in
    /*) ;;
    *) PUSH_TARGET_DIR="$PWD/$PUSH_TARGET_DIR" ;;
  esac
elif echo "$COMMAND" | grep -qE '(^|[;&|[:space:]])cd[[:space:]]+\S'; then
  CD_TARGET=$(echo "$COMMAND" \
    | grep -oE "cd[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:];&|]+)" \
    | tail -n 1 \
    | sed -E "s/^cd[[:space:]]+//; s/^[\"']//; s/[\"']\$//")
  if [ -n "$CD_TARGET" ]; then
    case "$CD_TARGET" in
      /*) PUSH_TARGET_DIR="$CD_TARGET" ;;
      *) PUSH_TARGET_DIR="$PWD/$CD_TARGET" ;;
    esac
  fi
fi

REPO_ROOT=$(git -C "$PUSH_TARGET_DIR" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

# Move into the target repo NOW, before the config lookup below. The
# shared config reader (`_lib-read-config.sh`) resolves its own repo root
# from `$PWD`, so calling it while `$PWD` is still the session's original
# directory reads the WRONG repo's `.pre_push.commands` — the second half
# of #1366 ("the commands can be read from one repo's config and executed
# against a different repo").
cd "$REPO_ROOT" || exit 0

# ---------------------------------------------------------------------------
# Skip marker — check HEAD commit message for the escape hatch.
# ---------------------------------------------------------------------------

SKIP_MARKER='<!-- pre-push: skip -->'
HEAD_MSG=$(cd "$REPO_ROOT" && git log -1 --format='%B' 2>/dev/null)
# -x: whole-line match only, so prose that mentions the marker inline
# (e.g. a commit that documents the escape hatch) does not trigger it —
# only a line consisting of exactly the marker does. See #1097.
if printf '%s\n' "$HEAD_MSG" | grep -qxF -- "$SKIP_MARKER"; then
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
  # APEXYARD_OPS_DISABLE_PIN=1: the shared reader's `_config_repo_root`
  # prefers a session-pinned ops root over `$PWD` (apexyard#381), which
  # is right for a marker write but wrong here — this gate must read the
  # config of the repo it is ABOUT TO RUN COMMANDS AGAINST ($REPO_ROOT,
  # already `cd`-ed into above), not the operator's other, pinned fork.
  # Unset, this was the second half of #1366: commands read from one
  # repo's config, executed against a different one.
  CMDS_JSON=$(APEXYARD_OPS_DISABLE_PIN=1 config_get '.pre_push.commands' 2>/dev/null)
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
# `$PWD` is already `$REPO_ROOT` from the cd above.
# ---------------------------------------------------------------------------

FAILURES=""
# printf '%s', NOT echo: CMDS_JSON comes from config_get and may carry a JSON
# backslash escape (the markdownlint `tr '\n' '\0'` command). echo would mangle
# it under an escape-interpreting shell, zeroing NUM_CMDS and silently skipping
# every pre-push check. Same bug class as #629. See #631.
NUM_CMDS=$(printf '%s' "$CMDS_JSON" | jq 'length' 2>/dev/null)
if [ -z "$NUM_CMDS" ] || [ "$NUM_CMDS" = "null" ]; then
  exit 0
fi

i=0
while [ "$i" -lt "$NUM_CMDS" ]; do
  NAME=$(printf '%s' "$CMDS_JSON" | jq -r ".[$i].name // \"step-$i\"" 2>/dev/null)
  RUN=$(printf '%s' "$CMDS_JSON" | jq -r ".[$i].run // empty" 2>/dev/null)
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
