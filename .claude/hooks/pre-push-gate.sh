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

# HOOK_DIR: this file's own directory, used below to source the shared
# config-reading library from a fixed, trusted location — never from the
# repo the command text names (me2resh/apexyard#1405 review item 3 / A1).
HOOK_DIR="$(cd "$(dirname "$0")" && pwd -P)"

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Recognise a push, and isolate its OWN clause — never scan the whole
# command line for a `cd` / `-C` value (me2resh/apexyard#1405 review items
# 1-2, Hakim H1).
#
# One regex matches either `git push` or `git -C <dir> push` as ONE
# contiguous invocation, `git` and `push` as their own words. That single
# match is what:
#   - stops a `-C` that belongs to an EARLIER, unrelated git call
#     (`git -C A status && git push`) from being read as this push's own
#     target — the match only succeeds at the SECOND `git`, where the
#     optional `-C` group is empty, so the hook correctly falls back to
#     $PWD instead of resolving to A;
#   - stops text AFTER the push (a trailing `cd`, a `-C`, a shell comment,
#     an `echo`, `cd -`/`cd ..`/`cd ~/x`, a push-option value) from being
#     read as a target at all — none of that text is part of this match,
#     so H1's seven trailing-command bypass shapes never reach the
#     extraction below.
# ---------------------------------------------------------------------------
PUSH_CLAUSE=$(printf '%s' "$COMMAND" \
  | grep -oE '\bgit[[:space:]]+(-C[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|]+)[[:space:]]+)?push\b' \
  | head -n 1)

if [ -z "$PUSH_CLAUSE" ]; then
  exit 0
fi

# `-C <dir>` extracted from the push clause itself, never from the rest of
# the command — this is the ONLY `-C` this hook will ever honour.
PUSH_C_VALUE=""
if echo "$PUSH_CLAUSE" | grep -qE -- '-C[[:space:]]+'; then
  PUSH_C_VALUE=$(echo "$PUSH_CLAUSE" \
    | grep -oE -- "-C[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:];&|]+)" \
    | sed -E "s/^-C[[:space:]]+//; s/^[\"']//; s/[\"']\$//")
fi

# The text BEFORE the push clause — the only place a `cd` that sets this
# push's cwd can appear. Everything from the push clause onward is dropped,
# so a trailing `cd`/comment/echo/push-option value is never scanned.
PREFIX="${COMMAND%%"$PUSH_CLAUSE"*}"

CD_TARGET=""
if echo "$PREFIX" | grep -qE '\bcd[[:space:]]+\S'; then
  CD_TARGET=$(echo "$PREFIX" \
    | grep -oE "cd[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:];&|]+)" \
    | tail -n 1 \
    | sed -E "s/^cd[[:space:]]+//; s/^[\"']//; s/[\"']\$//")
fi

# _resolve_dir <value> <base>: joins a relative path to <base>, expanding
# a leading `~` against $HOME (Hakim H1 item 5 — `cd ~/repo` must resolve
# a real target, not just fail closed for lack of trying).
_resolve_dir() {
  local dir="$1" base="$2"
  case "$dir" in
    "~"|"~/"*)
      if [ -n "${HOME:-}" ]; then
        dir="${HOME}${dir#"~"}"
      fi
      ;;
    /*) : ;;
    *) dir="$base/$dir" ;;
  esac
  printf '%s' "$dir"
}

CD_RESOLVED=""
if [ -n "$CD_TARGET" ]; then
  CD_RESOLVED=$(_resolve_dir "$CD_TARGET" "$PWD")
fi

# Compose: `git -C <dir> push` wins over a preceding `cd` when both appear,
# but a RELATIVE `-C` value now joins to the `cd` target, not to $PWD — the
# `cd B && git -C sub push` bug in the #1405 review (Rex item 2 / Hakim A2).
# Neither present: fall back to $PWD, unchanged for the common single-repo
# session.
TARGET_EXPLICIT=0
if [ -n "$PUSH_C_VALUE" ]; then
  TARGET_EXPLICIT=1
  BASE_FOR_C="$PWD"
  [ -n "$CD_RESOLVED" ] && BASE_FOR_C="$CD_RESOLVED"
  PUSH_TARGET_DIR=$(_resolve_dir "$PUSH_C_VALUE" "$BASE_FOR_C")
elif [ -n "$CD_RESOLVED" ]; then
  TARGET_EXPLICIT=1
  PUSH_TARGET_DIR="$CD_RESOLVED"
else
  PUSH_TARGET_DIR="$PWD"
fi

REPO_ROOT=$(git -C "$PUSH_TARGET_DIR" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  # A target was named (via `cd` or `-C`) and it does not resolve to a git
  # repository: BLOCK instead of silently skipping every check
  # (me2resh/apexyard#1405 review item 2, Hakim H1 item 2 — "do not skip").
  # The bare-$PWD case (no cd/-C at all) keeps the pre-#1366 behaviour: if
  # the session repo itself is not a git repo, `git push` will fail on its
  # own and this hook running is moot.
  if [ "$TARGET_EXPLICIT" -eq 1 ]; then
    cat >&2 <<MSG
BLOCKED: pre-push-gate cannot resolve the repository this push targets.
Resolved target: ${PUSH_TARGET_DIR}
This is not a git repository, or this shell cannot reach it. A gate that
cannot verify its target fails closed instead of skipping every check.
Fix the cd/-C target and push again.
MSG
    exit 2
  fi
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
# Source the shared reader from THIS HOOK'S OWN directory, never from
# $REPO_ROOT (me2resh/apexyard#1405 review item 3, Hakim A1). $REPO_ROOT is
# a directory named by the command TEXT — sourcing arbitrary shell code
# from a directory the command names, before the permission decision, is a
# code-execution path with no independent trust check. The library that
# INTERPRETS `.pre_push.commands` always comes from the hook's own,
# framework-controlled copy; only the CONFIG DATA (JSON already read from
# $PWD via `config_get`, which resolves against the target repo we already
# `cd`-ed into above) comes from the target repo — the same trust boundary
# this hook has had since before #1366: a repo's `.pre_push.commands` was
# always free to declare arbitrary shell commands, run via `bash -c` below;
# only the INTERPRETER's location changes here, not what a repo may
# configure. See docs/agdr/AgDR-0170-pre-push-trust-boundary.md.
if [ -f "$HOOK_DIR/_lib-read-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$HOOK_DIR/_lib-read-config.sh"
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
