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
# That's exactly why this needs to be invoked from `/setup`, every time it
# configures the ops fork's own clone — a config value that isn't repeated
# per clone doesn't stick.
#
# ONLY `/setup` invokes this script. `/handover` deliberately does NOT —
# running it against an arbitrary, just-cloned managed-project workspace
# would point core.hooksPath at THAT repo's own tracked .githooks/ (whatever
# it ships), handing it silent execution with no provenance check (PR #1087
# review, HIGH-1). See .claude/skills/handover/SKILL.md's "1.5-clone" note
# for the full reasoning and AgDR-0115 for the accepted-residual decision
# this leaves in place for a human's terminal `git push` inside a managed
# project's clone. Do not re-add a `/handover` call to this script without
# re-reading both first — that is precisely the footgun this comment exists
# to block.
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
#                       current working directory). Exists for tests and
#                       for pointing the installer at a repo other than
#                       the cwd's — NOT an invitation to call this against
#                       a managed-project clone; see the `/handover`
#                       note above.
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
#   2 — usage error, the target isn't a git repository at all, --repo-dir
#       resolved to a DIFFERENT (enclosing) repo than requested, the
#       tracked hooks dir is a symlink, or --hooks-dir resolves outside
#       the target repo
#   3 — the target repo has no tracked hooks dir to install (e.g. a
#       managed-project clone that hasn't adopted .githooks/ yet) — not a
#       bug, just nothing to do here
#   4 — the core.hooksPath write did not take effect (a `git config`
#       error, e.g. a stale .git/config.lock or a multi-valued key) —
#       fails CLOSED: never reports success on an unverified write
#
# Security note (PR #1087 review, HIGH-1): this script gates only on
# whether $TARGET_ROOT/$HOOKS_DIR_NAME exists. It performs NO provenance
# check on what that directory contains. That is fine when the caller
# controls the target repo (the ops fork configuring its own .githooks/,
# via /setup) — it is NOT fine against an arbitrary, just-cloned
# third-party repo, because doing so points git at THAT repo's own
# scripts with no operator confirmation. Callers MUST NOT invoke this
# against an untrusted clone. See .claude/skills/handover/SKILL.md's
# explicit note on why /handover deliberately does not call this script,
# and AgDR-0115 for the residual this leaves accepted.
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
# _resolve_real_path (used below and inside ghp_classify) comes from
# _lib-path-resolve.sh, sourced TRANSITIVELY here via $LIB above — this
# script never sources it directly. If that deeper lib is itself missing
# (genuine corruption; it ships right next to $LIB), $LIB's own else
# branch defines a stand-in that always echoes nothing and prints a named
# diagnostic once. See that else branch's comment for the full "deliberate
# degrade, not an oversight" rationale (#1089 — closing #1087's LOW-2),
# and the "load-bearing ordering" comment below for what an empty resolve
# means for THIS script's own safety property.

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
  2 — usage / not-a-git-repo / wrong-repo-resolved / symlinked-hooks-dir error
  3 — target repo has no tracked hooks dir to install (nothing to do)
  4 — the core.hooksPath write did not take effect (fails closed)
USAGE
}

# ---------------------------------------------------------------------------
# _ghp_set_hookspath TARGET_ROOT HOOKS_DIR_NAME
#
# Writes core.hooksPath and FAILS CLOSED (PR #1087 review, MEDIUM-2): the
# advisory hook is allowed to fail open (warn, never block), but this
# installer's whole job is telling the operator their clone IS protected —
# reporting success on a write that silently didn't take is worse than not
# writing at all, because the operator stops worrying about exactly the
# thing that's still broken.
#
# Two independent checks, neither trusted alone:
#   1. `git config`'s own exit status — catches a stale .git/config.lock
#      (a routine race when several worktree agents run in parallel) and
#      a multi-valued core.hooksPath (`git config <key> <value>` refuses
#      to collapse multiple values to one and exits non-zero).
#   2. Re-classify afterward and require "correct" — a defence-in-depth
#      read-back in case some git version/config-shape combination exits
#      0 without the value actually landing.
#
# Prints nothing on success (caller prints its own message); prints a
# specific error and returns 1 on failure.
# ---------------------------------------------------------------------------
_ghp_set_hookspath() {
  local target_root="$1" hooks_dir_name="$2"
  local err rc recheck

  err=$(git -C "$target_root" config core.hooksPath "$hooks_dir_name" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: 'git config core.hooksPath' failed (exit $rc): $err" >&2
    return 1
  fi

  recheck=$(ghp_classify "$target_root" "$hooks_dir_name")
  if [ "$recheck" != "correct" ]; then
    echo "ERROR: core.hooksPath write did not take effect (post-write state: '$recheck'). Not reporting success." >&2
    return 1
  fi

  return 0
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
# MEDIUM-3 (PR #1087 review): when --repo-dir is given but is not itself a
# repo's own root, `git rev-parse --show-toplevel` walks UP and silently
# returns whatever repo ENCLOSES it — e.g. --repo-dir <ops>/workspace/proj
# on a failed or partial clone resolves to the ops fork itself. Without
# this check the installer would then configure a repo the caller never
# named, and report success as if it had configured the one it did name.
# This is exactly the wrong-repo-write class .claude/rules/isolated-builds.md
# exists to prevent: a wrong-target resolution must stop, not continue.
# Compare resolved, symlink-free forms so a legitimate symlinked repo path
# doesn't false-positive here.
# ---------------------------------------------------------------------------
if [ -n "$REPO_DIR" ]; then
  REQUESTED_RESOLVED=$(_resolve_real_path "$REPO_DIR")
  TARGET_RESOLVED_FOR_CHECK=$(_resolve_real_path "$TARGET_ROOT")
  if [ -z "$REQUESTED_RESOLVED" ] || [ "$REQUESTED_RESOLVED" != "$TARGET_RESOLVED_FOR_CHECK" ]; then
    echo "ERROR: --repo-dir '$REPO_DIR' is not itself a git repository root — it resolved to the ENCLOSING repo at '$TARGET_ROOT' instead. Refusing to silently configure a different repo than requested. Pass the actual repo root, or omit --repo-dir to target the current directory's repo." >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# LOW-5 (PR #1087 review): refuse a tracked hooks dir committed as a
# SYMLINK, checked BEFORE the existence/directory test below. `[ -L ]`
# tests the entry itself without following it, so it catches a symlink
# named .githooks regardless of what it points to (a real dir outside the
# repo, a missing target, anything) — `[ -d ]` alone would follow a
# symlink-to-directory and treat it as an ordinary tracked dir, letting it
# resolve hooks from wherever the link leads instead of what "the repo's
# tracked hooks directory" is supposed to mean.
# ---------------------------------------------------------------------------
if [ -L "$TARGET_ROOT/$HOOKS_DIR_NAME" ]; then
  echo "ERROR: $TARGET_ROOT/$HOOKS_DIR_NAME is a symlink, not a real directory. Refusing to point core.hooksPath at a symlinked hooks dir (it can resolve outside the repo tree)." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Nothing to install if this repo carries no tracked hooks dir at all — this
# is the expected, non-error state for a managed-project clone that hasn't
# adopted .githooks/ yet. Still loud (non-zero, explicit message) rather
# than a silent no-op.
# ---------------------------------------------------------------------------
if [ ! -d "$TARGET_ROOT/$HOOKS_DIR_NAME" ]; then
  echo "No $HOOKS_DIR_NAME/ directory in $TARGET_ROOT — nothing to install (this repo hasn't adopted ApexYard's tracked git hooks). Skipping." >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# LOW-4 (PR #1087 review): reject a --hooks-dir value that resolves OUTSIDE
# the target repo (e.g. `--hooks-dir ../evil-hooks`). The classifier lib
# already reasons carefully about "outside REPO_ROOT" when DETECTING state;
# this is the matching check on the value we're about to WRITE.
#
# LOAD-BEARING ORDERING (#1089 — closing #1087's LOW-4 finding, the
# reviewer's own words): this check MUST run BEFORE `STATE=$(ghp_classify
# ...)` below, and that ordering is doing more work than the comment above
# alone suggests. If _lib-path-resolve.sh (see the `. "$LIB"` comment
# above) is ever missing, _resolve_real_path echoes nothing, so
# $HOOKS_DIR_RESOLVED is empty here — an empty string never matches
# `"$TARGET_ROOT"/*` or `"$TARGET_ROOT"`, so this check exits 2 BEFORE
# ghp_classify ever runs. That matters because ghp_classify has the SAME
# empty-resolve problem: with a missing lib, it would report a real,
# existing, deliberate third-party core.hooksPath as "missing:<raw>" —
# the STATE branch below that AUTO-REPAIRS with no --force. Running this
# check first is what keeps a corrupted clone from silently clobbering an
# adopter's deliberate choice; reordering these two blocks (e.g. moving
# ghp_classify earlier for readability) would remove that protection
# without anything else in the script noticing. See
# .claude/hooks/tests/test_install_git_hooks.sh's "installer's own lib
# missing" case for the pinned regression test.
# ---------------------------------------------------------------------------
HOOKS_DIR_RESOLVED=$(_resolve_real_path "$TARGET_ROOT/$HOOKS_DIR_NAME")
case "$HOOKS_DIR_RESOLVED" in
  "$TARGET_ROOT"/*|"$TARGET_ROOT") : ;;
  *)
    echo "ERROR: --hooks-dir '$HOOKS_DIR_NAME' resolves to '$HOOKS_DIR_RESOLVED', which is outside $TARGET_ROOT. Refusing to point core.hooksPath outside the repo tree." >&2
    exit 2
    ;;
esac

# #1089: reaching this line at all already proves _resolve_real_path
# resolved a real path above — see the LOAD-BEARING ORDERING comment on
# the LOW-4 check just above for why that ordering is what keeps a
# missing-lib degrade from reaching ghp_classify's auto-repair branch.
STATE=$(ghp_classify "$TARGET_ROOT" "$HOOKS_DIR_NAME")

case "$STATE" in
  unset)
    if _ghp_set_hookspath "$TARGET_ROOT" "$HOOKS_DIR_NAME"; then
      echo "core.hooksPath set to $HOOKS_DIR_NAME in $TARGET_ROOT (was unset)."
      exit 0
    else
      echo "ERROR: failed to set core.hooksPath in $TARGET_ROOT — clone is NOT protected. Check for a stale .git/config.lock, retry, or investigate the error above." >&2
      exit 4
    fi
    ;;

  correct)
    echo "core.hooksPath already set to $HOOKS_DIR_NAME in $TARGET_ROOT — no change (idempotent)."
    exit 0
    ;;

  missing:*)
    RAW="${STATE#missing:}"
    if _ghp_set_hookspath "$TARGET_ROOT" "$HOOKS_DIR_NAME"; then
      echo "core.hooksPath repaired: was '$RAW' (points at a non-existent directory), now $HOOKS_DIR_NAME in $TARGET_ROOT."
      exit 0
    else
      echo "ERROR: failed to repair core.hooksPath in $TARGET_ROOT (was '$RAW') — clone is NOT protected. Check for a stale .git/config.lock, retry, or investigate the error above." >&2
      exit 4
    fi
    ;;

  foreign-git-dir:*)
    REST="${STATE#foreign-git-dir:}"
    RAW="${REST%%:*}"
    RESOLVED="${REST#*:}"
    if _ghp_set_hookspath "$TARGET_ROOT" "$HOOKS_DIR_NAME"; then
      echo "core.hooksPath repaired: was '$RAW' (resolves to $RESOLVED — a different clone's git hooks dir), now $HOOKS_DIR_NAME in $TARGET_ROOT."
      exit 0
    else
      echo "ERROR: failed to repair core.hooksPath in $TARGET_ROOT (was '$RAW') — clone is NOT protected. Check for a stale .git/config.lock, retry, or investigate the error above." >&2
      exit 4
    fi
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
    if _ghp_set_hookspath "$TARGET_ROOT" "$HOOKS_DIR_NAME"; then
      echo "core.hooksPath overwritten (--force): was '$RAW', now $HOOKS_DIR_NAME in $TARGET_ROOT."
      exit 0
    else
      echo "ERROR: failed to overwrite core.hooksPath in $TARGET_ROOT (was '$RAW') — clone is NOT protected. Check for a stale .git/config.lock, retry, or investigate the error above." >&2
      exit 4
    fi
    ;;

  *)
    echo "ERROR: internal — unrecognised core.hooksPath state '$STATE'." >&2
    exit 2
    ;;
esac
