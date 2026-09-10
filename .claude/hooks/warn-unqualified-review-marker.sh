#!/bin/bash
# Advisory detector: a review-approval marker landed at a GATE-INVISIBLE path.
#
# THE GAP THIS CLOSES (me2resh/apexyard#1144)
# -------------------------------------------
# Approval markers are keyed repo-qualified since AgDR-0060 / #485:
#
#   .claude/session/reviews/<owner>__<repo>__<pr>-<role>.approved
#
# Every gate that reads a marker resolves that path through
# `review_marker_path` in _lib-review-markers.sh. There is no bare-number
# fallback on any on-disk marker lookup.
#
# #746 fixed the PRODUCER side: code-reviewer.md, security-reviewer.md, and
# solution-architect.md all resolve their own marker path correctly now. What
# #746 did not close is the ORCHESTRATOR side. When the agent that spawns a
# reviewer includes a literal marker path in the spawn prompt — "on APPROVED,
# write .claude/session/reviews/<N>-rex.approved" — the reviewer obeys the
# prompt over its own (correct) resolution logic. The marker lands bare-number.
#
# The result is silent in the dangerous direction. `ls .claude/session/reviews/`
# shows a file named `<N>-rex.approved`, which reads to a human as a perfectly
# good approval. Nothing notices until a merge is attempted, and the gate then
# reports the marker as MISSING — which is true of the path it looks at and
# false of what an operator can see on disk.
#
# That mismatch is where the real cost sits. The obvious repair in the moment
# is to move the file to the qualified path. That is marker forging: it records
# a gate signal for a review the current session cannot vouch for, which is
# precisely what .claude/rules/pr-workflow.md § "Build agents cannot
# self-review" forbids. This hook exists to name the problem AND the wrong fix
# at the moment the marker appears, hours before the merge attempt that would
# otherwise be the first sign of trouble.
#
# WHAT IT DOES
# ------------
# Scans <ops_root>/.claude/session/reviews/ for files whose basename is a bare
# `<digits>-<role>.approved` with no `<owner>__<repo>__` prefix. Offenders written
# in the last 24h are named individually (that is the live #1144 case); older ones
# are collapsed into a single "pre-AgDR-0060 leftovers" line, because any fork that
# predates #485 still has a pile of them and re-listing that pile every session is
# how an advisory hook trains an operator to ignore it. Full reasoning at the
# RECENT-vs-LEGACY comment below.
#
# CONSTRAINTS
# -----------
# - ADVISORY ONLY. Always exits 0. Never blocks, never deletes, never renames.
#   Deleting would destroy a legitimate reviewer's work product on a false
#   positive; renaming would BE the forgery this hook warns about.
# - Wired on two events, for two different jobs:
#     PostToolUse (Write | Edit | MultiEdit | Bash) — catches the marker at the
#       moment it is written, in the same turn, while the reviewer that wrote it
#       is still in context. Gated on a cheap payload substring so the common
#       case (every other Write/Bash in a session) costs one grep.
#     SessionStart — sweeps offenders left behind by a previous session, which
#       is the case the PostToolUse path structurally cannot see.
# - Says nothing when the reviews dir is absent or holds only qualified markers.
#
# NOT A SECURITY CONTROL. A bare-number marker is invisible to the gates, so its
# presence cannot cause an unreviewed merge — the failure mode this addresses is
# fail-CLOSED (a blocked merge on a genuinely approved PR) plus the forgery
# pressure that follows. Treat this as diagnosis, in the same family as
# warn-stale-review-markers.sh and check-upstream-drift.sh.

set -u

# -------- PostToolUse fast path: skip unless the payload smells relevant ------
# SessionStart delivers no tool_input, so an empty/absent payload falls through
# to the scan (that is the sweep). A PostToolUse payload that never mentions a
# marker path exits immediately — this hook must not add measurable cost to
# every Write and Bash call in a session.
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
fi

if [ -n "$INPUT" ]; then
  HOOK_EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
  if [ "$HOOK_EVENT" != "SessionStart" ]; then
    PAYLOAD=$(printf '%s' "$INPUT" | jq -r '[.tool_input.command // "", .tool_input.file_path // "", .tool_input.content // ""] | join(" ")' 2>/dev/null)
    # No jq / unparseable payload → fall through and scan. Scanning is harmless
    # (read-only, exit 0); skipping would silently disable the detector on any
    # payload shape we failed to parse.
    if [ -n "$PAYLOAD" ] && ! printf '%s' "$PAYLOAD" | grep -q '\.approved'; then
      exit 0
    fi
  fi
fi

# -------- Resolve the ops fork root (where session markers live) --------------
HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -n "$HOOK_DIR" ] || exit 0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)

ROOT=""
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-ops-root.sh"
  ROOT=$(resolve_ops_root "$REPO_ROOT" 2>/dev/null)
fi
if [ -z "$ROOT" ]; then
  cur="${REPO_ROOT:-$PWD}"
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    if [ -f "$cur/.apexyard-fork" ] || \
       { [ -f "$cur/onboarding.yaml" ] && [ -f "$cur/apexyard.projects.yaml" ]; }; then
      ROOT="$cur"
      break
    fi
    cur=$(dirname "$cur")
  done
fi
[ -n "$ROOT" ] || exit 0

REVIEWS_DIR="$ROOT/.claude/session/reviews"
if [ -f "$HOOK_DIR/_lib-review-markers.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-review-markers.sh"
  REVIEWS_DIR=$(review_markers_dir "$ROOT" 2>/dev/null || printf '%s/.claude/session/reviews' "$ROOT")
fi
[ -d "$REVIEWS_DIR" ] || exit 0

# -------- Scan for bare-number (unqualified) markers -------------------------
# A qualified marker's basename always contains `__` (the owner/repo separator;
# GitHub slugs use only [A-Za-z0-9._-], so `__` cannot appear inside one). An
# offender is therefore exactly: digits, a dash, a known role, `.approved`, and
# no `__` anywhere.
#
# RECENT vs LEGACY — why this hook does not shout about every offender
# -------------------------------------------------------------------
# Any fork that predates AgDR-0060 / #485 still has its old bare-number markers
# sitting in this directory: on the framework's own fork, 15 of them, for PRs
# merged long ago. Those are archaeology, not a live problem — the PRs they
# belong to shipped years of tickets back.
#
# A sweep that lists all of them on every SessionStart is 15 lines of noise per
# session, forever, and an advisory hook that cries wolf is an advisory hook the
# operator learns to scroll past. That would cost more than the bug it reports.
#
# So the hook splits on file mtime. A marker written inside RECENT_WINDOW_SECS
# is the case #1144 describes — a reviewer that just wrote to a path it was
# handed, for a PR someone is about to merge — and gets named individually.
# Anything older is summarised in one line as deletable legacy. The dangerous
# marker is always the fresh one; the old ones only need to stop being confusing.
RECENT_WINDOW_SECS="${APEXYARD_UNQUALIFIED_MARKER_RECENT_SECS:-86400}"   # 24h
MAX_LISTED=10

# Portable mtime. Try GNU (`stat -c %Y`) first, then BSD/macOS (`stat -f %m`),
# and VALIDATE the result is all digits before accepting it — a plain
# `a || b` chain is not enough here, because GNU's `-f` means --file-system and
# happily exits 0 while printing `?` for an unknown specifier, which would then
# be compared as if it were an epoch.
_file_mtime() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null)
  case "$m" in ''|*[!0-9]*) m=$(stat -f %m "$1" 2>/dev/null) ;; esac
  case "$m" in ''|*[!0-9]*) m="" ;; esac
  printf '%s' "$m"
}
NOW=$(date +%s 2>/dev/null || printf '0')

RECENT_NAMES=""
RECENT_COUNT=0
LEGACY_COUNT=0

shopt -s nullglob 2>/dev/null
for MARKER in "$REVIEWS_DIR"/*.approved; do
  [ -f "$MARKER" ] || continue
  NAME=$(basename "$MARKER")
  case "$NAME" in
    *__*) continue ;;
  esac
  if ! printf '%s' "$NAME" | grep -qE '^[0-9]+-(rex|ceo|security|architecture|design)\.approved$'; then
    continue
  fi

  MTIME=$(_file_mtime "$MARKER")
  # An unreadable mtime is treated as RECENT — under-reporting a live offender
  # is the worse failure, and it is the one this hook exists to catch.
  if [ -z "$MTIME" ] || [ "$NOW" = "0" ] || [ $((NOW - MTIME)) -le "$RECENT_WINDOW_SECS" ]; then
    RECENT_COUNT=$((RECENT_COUNT + 1))
    RECENT_NAMES="${RECENT_NAMES}${NAME}"$'\n'
  else
    LEGACY_COUNT=$((LEGACY_COUNT + 1))
  fi
done

if [ "$RECENT_COUNT" -gt 0 ]; then
  cat >&2 <<'BANNER'

⚠ Gate-invisible approval marker(s) written in .claude/session/reviews/

  Markers are keyed <owner>__<repo>__<pr>-<role>.approved (AgDR-0060). Every
  merge gate resolves that exact path; a bare-number file is read by nothing,
  even though `ls` makes it look like a valid approval.
BANNER

  LISTED=0
  while IFS= read -r NAME; do
    [ -n "$NAME" ] || continue
    if [ "$LISTED" -ge "$MAX_LISTED" ]; then
      echo "  • …and $((RECENT_COUNT - MAX_LISTED)) more" >&2
      break
    fi
    PR="${NAME%%-*}"
    ROLE="${NAME#*-}"
    ROLE="${ROLE%.approved}"
    echo "  • ${NAME}  →  no gate reads this; expected <owner>__<repo>__${PR}-${ROLE}.approved" >&2
    LISTED=$((LISTED + 1))
  done <<EOF
$RECENT_NAMES
EOF

  cat >&2 <<'FOOTER'

  Do NOT rename or move these into place. Relocating a file to satisfy a gate
  records a review this session cannot vouch for — see .claude/rules/pr-workflow.md
  § "Build agents cannot self-review". Delete each one and re-run the real
  review (/code-review, /security-review, /design-review).

  The cause is almost always a literal marker path in the reviewer's spawn
  prompt. Never pass one: the reviewer resolves its own path via
  review_marker_path. See me2resh/apexyard#1144.
FOOTER

  if [ "$LEGACY_COUNT" -gt 0 ]; then
    echo "  (${LEGACY_COUNT} older bare-number marker(s) are also present — pre-AgDR-0060 leftovers, safe to delete.)" >&2
  fi
  echo >&2
elif [ "$LEGACY_COUNT" -gt 0 ]; then
  # Nothing fresh. One quiet line, so a fork with pre-#485 history isn't
  # lectured every session about markers whose PRs merged long ago.
  echo "⚠ ${LEGACY_COUNT} bare-number approval marker(s) in .claude/session/reviews/ are read by no gate (pre-AgDR-0060 leftovers, safe to delete). See me2resh/apexyard#1144." >&2
fi

exit 0
