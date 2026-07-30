#!/bin/bash
# bin/install-git-hooks.sh — install ApexYard's tracked git hooks by setting
# `core.hooksPath`, per clone. Step 1 of me2resh/apexyard#1086.
#
# Background: `.githooks/pre-push` already exists and is tracked, but
# NOTHING sets `core.hooksPath` to point at it. Adopters were expected to
# run `git config core.hooksPath .githooks` by hand (docs/getting-started.md
# § "Optional: Terminal push hook") — and empirically that doesn't happen:
# one fork inherits `.githooks/` with the config unset, another has it
# pointing at a stale absolute path left over from a prior clone location,
# leaving the tracked hook silently inert either way.
#
# `core.hooksPath` is a PER-CLONE git config value, not a repo property —
# it lives in `.git/config`, never committed, so every fresh clone starts
# unset regardless of how many times a sibling clone has run this script.
# That's exactly why this needs to be invoked from `/setup` (for the ops
# fork) and `/handover` (for each newly-cloned managed-project workspace),
# not run once and forgotten.
#
# This script is idempotent and safe to re-run: unset -> set, already
# correct -> no-op, stale (missing dir, or a leftover pointer into a
# different clone's .git/hooks) -> auto-repaired, a real third-party
# directory the adopter set on purpose -> left alone unless --force.
#
# Usage:
#   bin/install-git-hooks.sh [--repo-dir <path>] [--hooks-dir <name>] [--force]
#
# Options:
#   --repo-dir <path>   Target repo (default: the repo containing the
#                       current working directory). Lets /handover call
#                       this against a freshly-cloned managed-project
#                       workspace instead of the ops fork.
#   --hooks-dir <name>  Tracked hooks dir name, relative to the repo root
#                       (default: .githooks). Mainly useful for tests.
#   --force             Overwrite a core.hooksPath an adopter set to a
#                       real, existing, different directory on purpose.
#                       Without --force such a "third-party" value is left
#                       untouched (exit 1) — this script never clobbers a
#                       deliberate choice silently.
#
# Exit codes:
#   0 — core.hooksPath is now correctly set (freshly set, auto-repaired,
#       or was already correct)
#   1 — refused: an existing, real, non-stale core.hooksPath is set to
#       something else; re-run with --force to override
#   2 — usage error, or the target isn't a git repository at all
#   3 — the target repo has no tracked hooks dir to install (e.g. a
#       managed-project clone that hasn't adopted .githooks/ yet) — not a
#       bug, just nothing to do here
#
# See me2resh/apexyard#1086 for the full driver and the two follow-up
# steps (enforcement inside .githooks/pre-push; demoting block-main-push.sh
# to advisory) that build on top of this installer but are explicitly OUT
# OF SCOPE here — landing them before this script exists and is wired up
# would move enforcement to a layer that's off by default for every
# adopter, which AgDR-0104 already flagged as strictly worse than today.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LIB="$SCRIPT_DIR/../.claude/hooks/_lib-git-hooks-path.sh"

if [ ! -f "$LIB" ]; then
  echo "ERROR: missing $LIB — cannot resolve core.hooksPath state. Is this running from inside an apexyard clone?" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$LIB"

usage() {
  cat <<'USAGE'
Usage: bin/install-git-hooks.sh [--repo-dir <path>] [--hooks-dir <name>] [--force]

Sets core.hooksPath so this clone picks up ApexYard's tracked git hooks
(.githooks/pre-push and friends). Idempotent — safe to re-run.

Options:
  --repo-dir <path>   Target repo (default: the repo containing the cwd).
  --hooks-dir <name>  Hooks dir name relative to repo root (default: .githooks).
  --force             Overwrite a core.hooksPath an adopter set to a real,
                       different directory on purpose.

Exit codes:
  0 — core.hooksPath is now correctly set (fresh, repaired, or already correct)
  1 — refused: a deliberate third-party core.hooksPath exists; re-run with --force
  2 — usage / not-a-git-repo error
  3 — target repo has no tracked hooks dir to install (nothing to do)
USAGE
}

REPO_DIR=""
HOOKS_DIR_NAME=".githooks"
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-dir)
      [ $# -ge 2 ] || { echo "ERROR: --repo-dir requires a value." >&2; usage >&2; exit 2; }
      REPO_DIR="$2"; shift 2 ;;
    --repo-dir=*) REPO_DIR="${1#*=}"; shift ;;
    --hooks-dir)
      [ $# -ge 2 ] || { echo "ERROR: --hooks-dir requires a value." >&2; usage >&2; exit 2; }
      HOOKS_DIR_NAME="$2"; shift 2 ;;
    --hooks-dir=*) HOOKS_DIR_NAME="${1#*=}"; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Resolve the target repo's toplevel. Fails loudly (never silently) when the
# target isn't a git repository at all.
# ---------------------------------------------------------------------------
if [ -n "$REPO_DIR" ]; then
  if [ ! -d "$REPO_DIR" ]; then
    echo "ERROR: --repo-dir '$REPO_DIR' does not exist." >&2
    exit 2
  fi
  TARGET_ROOT=$(cd "$REPO_DIR" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)
else
  TARGET_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
fi

if [ -z "$TARGET_ROOT" ]; then
  echo "ERROR: ${REPO_DIR:-$PWD} is not inside a git repository. Nothing to install." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Nothing to install if this repo carries no tracked hooks dir at all — this
# is the expected, non-error state for a managed-project clone that hasn't
# adopted .githooks/ yet (see /handover's invocation of this script). Still
# loud (non-zero, explicit message) rather than a silent no-op.
# ---------------------------------------------------------------------------
if [ ! -d "$TARGET_ROOT/$HOOKS_DIR_NAME" ]; then
  echo "No $HOOKS_DIR_NAME/ directory in $TARGET_ROOT — nothing to install (this repo hasn't adopted ApexYard's tracked git hooks). Skipping." >&2
  exit 3
fi

STATE=$(ghp_classify "$TARGET_ROOT" "$HOOKS_DIR_NAME")

case "$STATE" in
  unset)
    git -C "$TARGET_ROOT" config core.hooksPath "$HOOKS_DIR_NAME"
    echo "core.hooksPath set to $HOOKS_DIR_NAME in $TARGET_ROOT (was unset)."
    exit 0
    ;;

  correct)
    echo "core.hooksPath already set to $HOOKS_DIR_NAME in $TARGET_ROOT — no change (idempotent)."
    exit 0
    ;;

  missing:*)
    RAW="${STATE#missing:}"
    git -C "$TARGET_ROOT" config core.hooksPath "$HOOKS_DIR_NAME"
    echo "core.hooksPath repaired: was '$RAW' (points at a non-existent directory), now $HOOKS_DIR_NAME in $TARGET_ROOT."
    exit 0
    ;;

  foreign-git-dir:*)
    REST="${STATE#foreign-git-dir:}"
    RAW="${REST%%:*}"
    RESOLVED="${REST#*:}"
    git -C "$TARGET_ROOT" config core.hooksPath "$HOOKS_DIR_NAME"
    echo "core.hooksPath repaired: was '$RAW' (resolves to $RESOLVED — a different clone's git hooks dir), now $HOOKS_DIR_NAME in $TARGET_ROOT."
    exit 0
    ;;

  third-party:*)
    REST="${STATE#third-party:}"
    RAW="${REST%%:*}"
    RESOLVED="${REST#*:}"
    if [ "$FORCE" != "1" ]; then
      cat >&2 <<MSG
core.hooksPath is set to '$RAW' (resolves to $RESOLVED) in $TARGET_ROOT, and
that directory exists — this looks like a deliberate adopter choice, not a
stale leftover. Refusing to overwrite without --force.

Re-run with --force to install ApexYard's tracked hooks ($HOOKS_DIR_NAME) instead:
  bash bin/install-git-hooks.sh --repo-dir "$TARGET_ROOT" --force
MSG
      exit 1
    fi
    git -C "$TARGET_ROOT" config core.hooksPath "$HOOKS_DIR_NAME"
    echo "core.hooksPath overwritten (--force): was '$RAW', now $HOOKS_DIR_NAME in $TARGET_ROOT."
    exit 0
    ;;

  *)
    echo "ERROR: internal — unrecognised core.hooksPath state '$STATE'." >&2
    exit 2
    ;;
esac
