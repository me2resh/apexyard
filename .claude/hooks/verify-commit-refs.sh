#!/bin/bash
# PreToolUse hook on `git commit -m / -F`: scans the commit message for
# issue references (Closes #N, Refs #N, Fixes #N, Resolves #N, Related to #N)
# and blocks the commit if any reference points at an issue that doesn't
# exist in the tracker repo.
#
# Backstop for the ticket-vocabulary rule (.claude/rules/ticket-vocabulary.md).
# The primary enforcement is self-discipline: never use tracker notation for
# plan items that have no real issue behind them. This hook catches the
# downstream symptom — a fabricated #N that made it into a commit message
# on its way to becoming durable history.
#
# Interactive commits (no -m / -F) are NOT checked. Parsing .git/COMMIT_EDITMSG
# before the editor opens would race with git's own validation, and Claude
# rarely uses the interactive path anyway. Accepted gap.
#
# Tracker repo resolves in this order:
#   1. .claude/project-config.json `.tracker_repo`
#   2. origin remote (parsed from `git remote get-url origin`)
#
# Upstream awareness (me2resh/apexyard#207): when an `upstream` remote is
# configured (typical fork-of-apexyard layout), a #N reference that misses in
# the primary tracker is rechecked against `upstream` before being declared
# missing. This lets a fork's `Closes #150` validate when issue 150 lives on
# the upstream repo — and, more importantly, lets GitHub's auto-close fire on
# merge (auto-close requires BARE #N notation; the cross-repo workaround
# `Closes owner/repo#150` passes the hook but breaks auto-close).
#
# Short-circuit: try the primary tracker first, only fall back to upstream on
# miss. No double query for refs that resolve in origin.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Only check on git commit. Also recognizes `git -C <path> commit` (quoted
# or bare) — a bare `\bgit\s+commit\b` check misses this shape entirely
# (the `-C <path>` sits between "git" and "commit", so the two tokens are
# never adjacent), which meant a commit made via explicit `-C` — exactly
# the pattern a worktree-based sub-agent uses (me2resh/apexyard#1050) —
# skipped ref verification altogether, regardless of any cwd-resolution fix
# below. Round-3 review caught this: the WORKDIR resolver's `-C`-bound-to-
# commit priority level was otherwise unreachable in practice.
if ! echo "$COMMAND" | grep -qE '\bgit[[:space:]]+(-C[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)[[:space:]]+)?commit\b'; then
  exit 0
fi

# Extract the commit message. Try -m "..." / -m '...' first, then -F <file>.
# If neither is present, assume interactive commit — skip.
#
# IMPORTANT: Claude and humans both commonly use multi-line -m arguments via
# HEREDOC substitution like `git commit -m "$(cat <<EOF ... EOF)"`, which means
# the literal -m value spans multiple lines in the command string. We use awk
# with a line-by-line accumulator so the match runs against the whole logical
# command, not one physical line.
#
# Quoted-value regex is GREEDY and anchored on the next flag boundary
# (whitespace + `-<letter>`) or end-of-string. The earlier sed form
# `-m "([^"]*)"` truncated at the first embedded double quote
# (me2resh/apexyard#227), so commit messages whose body contained any
# `"` (admin-notice strings, status labels in quotes, prose like "current
# state") had their `Closes #N` / `Refs #N` references past the truncation
# point go unverified. awk + greedy + boundary anchor matches the closing
# `"` of the FLAG argument, not the first internal `"` inside the message.

extract_commit_msg() {
  # $1 = whole command string. Prints the extracted -m value, empty if none.
  printf '%s' "$1" | awk -v SQ="'" '
    { buf = (NR == 1 ? $0 : buf "\n" $0) }
    END {
      s = buf
      # Boundary terminator: whitespace + `-<letter>` (catches -F, -- flags,
      # and short flags like -S / -s) or end-of-string. -m is the only flag
      # before us in this branch, so any later -<letter> marks the end of
      # the -m value.
      # Single-quoted -m value, greedy.
      re = "-m[[:space:]]+" SQ "(.*)" SQ "([[:space:]]+-[a-zA-Z]|[[:space:]]*$)"
      if (match(s, re)) {
        chunk = substr(s, RSTART, RLENGTH)
        sub("^-m[[:space:]]+" SQ, "", chunk)
        sub(SQ "([[:space:]]+-[a-zA-Z].*)?$", "", chunk)
        sub(SQ "[[:space:]]*$", "", chunk)
        print chunk
        exit
      }
      # Double-quoted -m value, greedy.
      re = "-m[[:space:]]+\"(.*)\"([[:space:]]+-[a-zA-Z]|[[:space:]]*$)"
      if (match(s, re)) {
        chunk = substr(s, RSTART, RLENGTH)
        sub("^-m[[:space:]]+\"", "", chunk)
        sub("\"([[:space:]]+-[a-zA-Z].*)?$", "", chunk)
        sub("\"[[:space:]]*$", "", chunk)
        print chunk
        exit
      }
    }
  '
}

MSG=$(extract_commit_msg "$COMMAND")

# -F <file> / --file <file>
if [ -z "$MSG" ]; then
  COMMAND_FLAT=$(echo "$COMMAND" | tr '\n' ' ')
  MSG_FILE=$(echo "$COMMAND_FLAT" | sed -nE 's/.*(-F|--file)[[:space:]]+([^[:space:]]+).*/\2/p' | head -1)
  if [ -n "$MSG_FILE" ] && [ -f "$MSG_FILE" ]; then
    MSG=$(cat "$MSG_FILE")
  fi
fi

# No message found → interactive commit or parse failure. Skip.
if [ -z "$MSG" ]; then
  exit 0
fi

# Extract issue references. Patterns matched (case-insensitive):
#   Closes #N / Close #N / Closed #N
#   Fixes #N / Fix #N / Fixed #N
#   Resolves #N / Resolve #N / Resolved #N
#   Refs #N / Ref #N / References #N / Related to #N
# One reference per line is the common pattern; multiples in one line also work.
REFS=$(echo "$MSG" | grep -oEi '\b(close[sd]?|fix(e[sd])?|resolve[sd]?|ref(s|erences)?|related to)[[:space:]]+#[0-9]+' | grep -oE '#[0-9]+' | sort -u)

if [ -z "$REFS" ]; then
  exit 0
fi

# Resolve the WORKING DIRECTORY the `git commit` is actually executing in —
# NOT the hook process's own cwd (me2resh/apexyard#1050). In a
# split-portfolio / worktree-based sub-agent session, the harness's Bash cwd
# for this call can be a managed project's worktree while the hook process
# itself inherits a different cwd (typically the ops fork). Every
# cwd-relative git call below must run against the COMMIT's directory, not
# wherever this script happened to start.
#
# Priority (highest first) — corrected per PR #1073 review. The harness
# `.cwd` field is STRUCTURED: the harness itself sets it for this exact Bash
# call, and it cannot be influenced by anything the commit message says.
# Everything else is SCRAPED out of $COMMAND text, which can be tricked by
# the commit message's own prose, or by an unrelated LATER git invocation in
# the same compound command. Structured beats scraped, so `.cwd` goes first
# — this now correctly mirrors suggest-mcp-reindex-after-pull.sh (see its
# cwd-first fallback chain around lines 109-138: `.cwd` is "the common
# case", checked FIRST, with command-parsing only as a fallback). An earlier
# version of this fix put the scraped `-C`/`cd` parsing AHEAD of `.cwd` and
# justified it as "an explicit in-command override always wins" — that
# ordering is exactly what made these reachable:
#   - a commit MESSAGE containing the text `git -C <dir>` got scraped as
#     real shell syntax, silently disabling ref verification (if <dir>
#     isn't a git repo) or validating a real ref against the wrong repo (if
#     it is)
#   - `git commit -m "..." && git -C /other log` — a `-C` belonging to a
#     LATER, unrelated git invocation got treated as though it governed
#     this commit
#   - `cd /real && git -C /other status && git commit` — same shape,
#     discarding the real governing `cd /real`
#   - a relative `cd ../sibling` resolved against the HOOK's OWN cwd — the
#     very cwd this fix exists to distrust
#
# Priority now:
#   1. the harness-provided `.cwd` (`.tool_input.cwd`) for this Bash call.
#   2. `git -C <path>` bound DIRECTLY to this commit invocation
#      (`git -C <path> commit`), scraped from the command with the commit
#      MESSAGE stripped out first (so prose can never be read as syntax),
#      and matched only when the `-C` is the last thing before THIS
#      `commit` token — a `-C` on a different git invocation cannot bind.
#   3. the LAST `cd <path>` occurring before this commit invocation, same
#      message-stripped, same-invocation-only scoping.
#   4. fall back to the hook's own process cwd — IDENTICAL to the pre-fix
#      behavior, so a session with no worktree involved sees no change.
# Only ABSOLUTE paths are trusted out of (1)-(3); a relative path is
# ambiguous about what it's relative TO, so it's treated as absent rather
# than resolved against the hook's own cwd via a coincidental `-d` pass.

# Strip the commit message out of COMMAND before any scraping below — a
# literal, non-regex substring removal. Deliberately NOT `awk -v` on the raw
# content: POSIX awk's `-v`/command-line-operand assignment undergoes its
# own escape-sequence processing, which can silently mangle a message
# containing backslash sequences (a commit message describing THIS hook is
# exactly that kind of text — see #1073's review). Both values are piped in
# through stdin instead, joined by a private sentinel, and sliced with
# index()/substr() so nothing is ever regex- or escape-interpreted.
strip_message_from_command() {
  local cmd="$1" msg="$2" sep="__apexyard_1050_msg_boundary__"
  if [ -z "$msg" ]; then
    printf '%s' "$cmd"
    return
  fi
  printf '%s%s%s' "$cmd" "$sep" "$msg" | awk -v sep="$sep" '
    { buf = (NR == 1 ? $0 : buf "\n" $0) }
    END {
      sidx = index(buf, sep)
      if (sidx == 0) { printf "%s", buf; exit }
      c = substr(buf, 1, sidx - 1)
      m = substr(buf, sidx + length(sep))
      midx = index(c, m)
      if (midx > 0 && length(m) > 0) {
        printf "%s%s", substr(c, 1, midx - 1), substr(c, midx + length(m))
      } else {
        printf "%s", c
      }
    }
  '
}

# Extract a governing directory from the (message-stripped) command, bound
# to THIS commit invocation only. Only the portion of the command BEFORE
# the first `commit` TOKEN is considered — a `-C` / `cd` at or after that
# point belongs to a later command in the same compound line and must not
# be read as governing this one.
#
# The cut point MUST be a token boundary, not a bare substring search. An
# earlier version of this function used `${cmd%%commit*}`, which cuts at
# the first literal SUBSTRING "commit" — truncating mid-path for any
# directory name that merely CONTAINS that substring (`commitizen`,
# `pre-commit-hooks`, `commitlint`, `commits-repo`, ...). That failure is
# fail-OPEN: the truncated parent is usually not a git repo, so the caller
# falls through to the "could not resolve tracker repo — skipping" branch
# and ref verification is silently disabled (me2resh/apexyard#1050 review,
# round 3). A leading space is prepended so the boundary pattern
# `[[:space:]]commit([[:space:]]|$)` can require a preceding space
# uniformly, with no special case for "commit" occurring at position 0.
resolve_commit_workdir_from_command() {
  local cmd="$1" padded pos prefix dir
  padded=" $cmd"
  pos=$(printf '%s' "$padded" | awk '
    { buf = (NR == 1 ? $0 : buf "\n" $0) }
    END {
      if (match(buf, /[[:space:]]commit([[:space:]]|$)/)) {
        print RSTART
      } else {
        print 0
      }
    }
  ')
  if [ "$pos" -gt 1 ] 2>/dev/null; then
    # RSTART (1-based, in PADDED) points at the whitespace char immediately
    # before the "commit" token. padded[2..pos] == cmd[1..pos-1] — the
    # commit's own leading directory hints, with the artificial leading
    # space dropped.
    prefix=$(printf '%s' "$padded" | cut -c "2-${pos}")
  else
    # No bounded "commit" token found at all (e.g. it only ever appeared
    # inside the now-stripped message) — nothing to bound against; fall
    # through to scanning the whole (message-stripped) string, same as
    # before this token-boundary fix existed.
    prefix="$cmd"
  fi

  # `-C <path>` immediately preceding THIS commit (`git -C <path> commit`).
  # Anchored at the END of prefix so a `-C` on an earlier, unrelated git
  # invocation in the same compound command does not match.
  dir=""
  if echo "$prefix" | grep -qE 'git[[:space:]]+-C[[:space:]]+"[^"]*"[[:space:]]*$'; then
    dir=$(echo "$prefix" | sed -E 's/^.*git[[:space:]]+-C[[:space:]]+"([^"]*)"[[:space:]]*$/\1/')
  elif echo "$prefix" | grep -qE "git[[:space:]]+-C[[:space:]]+'[^']*'[[:space:]]*\$"; then
    dir=$(echo "$prefix" | sed -E "s/^.*git[[:space:]]+-C[[:space:]]+'([^']*)'[[:space:]]*\$/\1/")
  elif echo "$prefix" | grep -qE 'git[[:space:]]+-C[[:space:]]+[^[:space:]]+[[:space:]]*$'; then
    dir=$(echo "$prefix" | sed -E 's/^.*git[[:space:]]+-C[[:space:]]+([^[:space:]]+)[[:space:]]*$/\1/')
  fi
  if [ -n "$dir" ] && [ "${dir#/}" != "$dir" ]; then
    echo "$dir"
    return
  fi

  # Last `cd <path>` occurring anywhere before this commit invocation.
  dir=""
  if echo "$prefix" | grep -qE '(^|&&|;)[[:space:]]*cd[[:space:]]+"[^"]*"'; then
    dir=$(echo "$prefix" | grep -oE '(^|&&|;)[[:space:]]*cd[[:space:]]+"[^"]*"' | tail -1 | sed -E 's/^(&&|;)?[[:space:]]*cd[[:space:]]+"([^"]*)"$/\2/')
  elif echo "$prefix" | grep -qE "(^|&&|;)[[:space:]]*cd[[:space:]]+'[^']*'"; then
    dir=$(echo "$prefix" | grep -oE "(^|&&|;)[[:space:]]*cd[[:space:]]+'[^']*'" | tail -1 | sed -E "s/^(&&|;)?[[:space:]]*cd[[:space:]]+'([^']*)'\$/\2/")
  elif echo "$prefix" | grep -qE '(^|&&|;)[[:space:]]*cd[[:space:]]+[^[:space:]&|;]+'; then
    dir=$(echo "$prefix" | grep -oE '(^|&&|;)[[:space:]]*cd[[:space:]]+[^[:space:]&|;]+' | tail -1 | sed -E 's/^(&&|;)?[[:space:]]*cd[[:space:]]+//')
  fi
  if [ -n "$dir" ] && [ "${dir#/}" != "$dir" ]; then
    echo "$dir"
    return
  fi
}

PAYLOAD_CWD=$(echo "$INPUT" | jq -r '.cwd // .tool_input.cwd // empty' 2>/dev/null)
CMD_SANS_MSG=$(strip_message_from_command "$COMMAND" "$MSG")

# 1. Structured harness cwd wins outright when present and absolute.
# WORKDIR_SOURCE distinguishes "we resolved a hint" from "nothing resolved
# and we fell back" — used below to give the "could not resolve tracker
# repo" warning a sharper message when a HINT was found but didn't pan out
# (e.g. it resolved to a directory with no git origin at all), versus the
# unremarkable case where no hint existed and the fallback is expected.
WORKDIR=""
WORKDIR_SOURCE="fallback"
if [ -n "$PAYLOAD_CWD" ] && [ "${PAYLOAD_CWD#/}" != "$PAYLOAD_CWD" ]; then
  WORKDIR="$PAYLOAD_CWD"
  WORKDIR_SOURCE="payload_cwd"
fi
# 2 & 3. Only reached when .cwd is absent — scraped, message-stripped,
# same-invocation-only command parsing.
if [ -z "$WORKDIR" ]; then
  WORKDIR=$(resolve_commit_workdir_from_command "$CMD_SANS_MSG")
  if [ -n "$WORKDIR" ]; then
    WORKDIR_SOURCE="scraped_command"
  fi
fi
# 4. No hint resolved anything usable — fall back to this process's own cwd,
# exactly what every git call below did before this fix.
if [ -z "$WORKDIR" ] || [ ! -d "$WORKDIR" ]; then
  if [ -n "$WORKDIR" ]; then
    # A hint WAS found (payload .cwd or scraped command) but the directory
    # doesn't even exist — worth remembering for the warning below, since
    # this is exactly the shape a truncated/incorrect scrape produces.
    WORKDIR_SOURCE="${WORKDIR_SOURCE}_unresolvable:${WORKDIR}"
  fi
  WORKDIR="$PWD"
fi

# Resolve tracker repo.
#
# Two roots come into play:
#   - HOOK_DIR: where this script and the sibling libs live (always
#     resolvable, doesn't depend on cwd).
#   - CONFIG_ROOT: the ops fork holding .claude/project-config.json. When
#     the operator runs inside workspace/<project>/, `git rev-parse
#     --show-toplevel` resolves to the project clone, NOT the ops fork —
#     causing the tracker.kind to silently default to "gh" even when the
#     operator configured Linear / Jira / Asana / custom at the ops-fork
#     level (me2resh/apexyard#310). _lib-ops-root.sh walks up to the
#     ops-fork anchor (v2 marker or v1 pair) and is the right primitive.
#     Both REPO_ROOT and the resolve_ops_root walk now start from WORKDIR
#     (the commit's own directory) instead of $PWD — see above.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT=$(git -C "$WORKDIR" rev-parse --show-toplevel 2>/dev/null)
CONFIG_ROOT=""
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$HOOK_DIR/_lib-ops-root.sh"
  CONFIG_ROOT=$(resolve_ops_root "$WORKDIR")
fi
if [ -z "$CONFIG_ROOT" ]; then
  CONFIG_ROOT="$REPO_ROOT"
fi

TRACKER_REPO=""
if [ -n "$CONFIG_ROOT" ] && [ -f "${CONFIG_ROOT}/.claude/project-config.json" ]; then
  TRACKER_REPO=$(jq -r '.tracker_repo // empty' "${CONFIG_ROOT}/.claude/project-config.json" 2>/dev/null)
fi
if [ -z "$TRACKER_REPO" ]; then
  ORIGIN_URL=$(git -C "$WORKDIR" remote get-url origin 2>/dev/null)
  TRACKER_REPO=$(echo "$ORIGIN_URL" | sed -nE 's|.*[:/]([^/:]+/[^/]+)\.git$|\1|p; s|.*[:/]([^/:]+/[^/]+)$|\1|p' | head -1)
fi

# Load the tracker library (dispatches `gh issue view` by default; can be
# pointed at Linear / Jira / Asana / custom via `.tracker.kind`).
# Source via HOOK_DIR so this works regardless of cwd. The lib's own config
# reader resolves the ops fork for the actual config file.
TRACKER_KIND="gh"
if [ -f "$HOOK_DIR/_lib-tracker.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$HOOK_DIR/_lib-tracker.sh"
  # Resolve the kind for the OPERATION'S target repo so a per-project tracker
  # override (apexyard.projects.yaml) wins over the global block (#670). Empty
  # TRACKER_REPO → no-arg → global default (today's behaviour).
  TRACKER_KIND=$(tracker_kind "$TRACKER_REPO")
fi

# `tracker.kind = none` disables existence verification — there's no CLI to
# call against. We have nothing to check; bail out cleanly.
if [ "$TRACKER_KIND" = "none" ]; then
  exit 0
fi

# `tracker.kind = gh` (default) still requires an origin / configured repo;
# preserve today's behaviour. For non-gh kinds the {owner_repo} placeholder
# in the configured view_command may be unused, so we don't gate on it.
#
# The message distinguishes "no cwd/-C/cd hint existed at all" (WORKDIR_SOURCE
# = fallback; unremarkable, this is the ordinary interactive/local-repo case)
# from "a hint WAS resolved but it doesn't have a usable git origin"
# (payload_cwd / scraped_command, or the *_unresolvable:<dir> shape when the
# resolved directory didn't even exist) — the latter is worth a sharper
# signal, since a truncated or mis-scraped directory hint silently landing
# here (ref verification skipped, not blocked) is exactly the failure class
# a prior version of this fix introduced (me2resh/apexyard#1050 review,
# round 3: a path substring-matching "commit" got truncated mid-directory).
if [ "$TRACKER_KIND" = "gh" ] && [ -z "$TRACKER_REPO" ]; then
  case "$WORKDIR_SOURCE" in
    fallback)
      echo "WARN: verify-commit-refs.sh could not resolve tracker repo. Skipping." >&2
      ;;
    *)
      echo "WARN: verify-commit-refs.sh resolved a working-directory hint (source: ${WORKDIR_SOURCE}, dir: ${WORKDIR}) but it has no usable git origin — skipping ref verification. If this directory looks truncated or wrong, that's a bug in the cwd/-C/cd scraper, not a config problem." >&2
      ;;
  esac
  exit 0
fi

# Optional upstream fallback (see file header). Parse `git remote get-url
# upstream` into `owner/repo`; empty if no upstream remote is configured —
# in which case the validator behaves exactly as before (origin-only check).
#
# Upstream fallback only applies to the gh kind. Linear / Jira / Asana
# don't have a fork-of-a-tracker concept.
UPSTREAM_REPO=""
if [ "$TRACKER_KIND" = "gh" ] && git -C "$WORKDIR" remote get-url upstream >/dev/null 2>&1; then
  UPSTREAM_URL=$(git -C "$WORKDIR" remote get-url upstream 2>/dev/null)
  UPSTREAM_REPO=$(echo "$UPSTREAM_URL" | sed -nE 's|.*[:/]([^/:]+/[^/]+)\.git$|\1|p; s|.*[:/]([^/:]+/[^/]+)$|\1|p' | head -1)
  # Don't double-check if upstream resolves to the same repo as the primary
  # tracker (e.g. running INSIDE the framework repo itself, where origin and
  # upstream both point at me2resh/apexyard).
  if [ "$UPSTREAM_REPO" = "$TRACKER_REPO" ]; then
    UPSTREAM_REPO=""
  fi
fi

# Verify each referenced issue exists. Fabricated #N (issue not found) is
# BLOCKING — that's the failure mode the ticket-vocabulary rule targets.
# References to CLOSED issues are WARNED (not blocked) because a commit may
# legitimately reference the closed issue it just finished (e.g. a revert or
# a follow-up clarification commit after the closing PR already shipped).
# The PR-level hook (validate-pr-create.sh) is the right place to enforce
# "every PR needs its own OPEN ticket".
MISSING=""
CLOSED=""
SHAPE_ONLY=""
for REF in $REFS; do
  NUM=$(echo "$REF" | tr -d '#')
  # Dispatch via the tracker lib. For non-gh kinds `--repo` may be a no-op.
  ISSUE_JSON=$(tracker_view "$NUM" "$TRACKER_REPO" 2>/dev/null)
  # Short-circuit: only consult upstream when the primary tracker missed.
  if [ -z "$ISSUE_JSON" ] && [ -n "$UPSTREAM_REPO" ]; then
    ISSUE_JSON=$(tracker_view "$NUM" "$UPSTREAM_REPO" 2>/dev/null)
  fi
  if [ -z "$ISSUE_JSON" ] && [ "$TRACKER_KIND" != "gh" ]; then
    # Non-gh tracker (Linear / Jira / Asana / custom) returned nothing — the
    # tracker CLI is absent, unauthenticated, or not queryable from this
    # environment (#501). Do NOT block: the ref already passed the well-formed
    # shape extraction above, which is all we can assert without a working CLI.
    # Hard existence enforcement (adding to MISSING → exit 2) is retained ONLY
    # for tracker.kind == gh.
    SHAPE_ONLY="${SHAPE_ONLY}${REF} "
    continue
  fi
  if [ -z "$ISSUE_JSON" ]; then
    MISSING="${MISSING}${REF} "
    continue
  fi
  ISSUE_STATE=$(echo "$ISSUE_JSON" | jq -r '.state // empty' 2>/dev/null)
  # Closed-state recognition: gh emits "CLOSED"; non-gh trackers report
  # "Done" / "Closed" / "Resolved" / "Cancelled" depending on workflow.
  ISSUE_STATE_LC=$(echo "$ISSUE_STATE" | tr '[:upper:]' '[:lower:]')
  case "$ISSUE_STATE_LC" in
    closed|done|cancelled|canceled|resolved|completed)
      CLOSED="${CLOSED}${REF} " ;;
  esac
done

if [ -n "$MISSING" ]; then
  # Include the upstream repo in the error when one was consulted — makes the
  # blocked-because-it's-not-in-either-place case explicit.
  if [ -n "$UPSTREAM_REPO" ]; then
    LOCATION_MSG="${TRACKER_REPO} or upstream ${UPSTREAM_REPO}"
  else
    LOCATION_MSG="${TRACKER_REPO}"
  fi
  cat >&2 <<MSG
BLOCKED: Commit message references issues that do not exist in ${LOCATION_MSG}:
  ${MISSING}

This is the failure mode the ticket-vocabulary rule exists to prevent — do NOT
use tracker notation (Closes #N, Refs #N, etc.) for plan items that have no
real issue behind them. See .claude/rules/ticket-vocabulary.md.

If you intended to reference a real issue, verify the number(s).
If you were about to commit work that has no ticket yet, create one first:
  gh issue create --repo ${TRACKER_REPO} --title "..."
and use the returned number in your commit message.

If the reference is truly informational (cross-repo link that can't be verified
with \`gh issue view\`), write it as a plain URL instead of #N notation.
MSG
  exit 2
fi

if [ -n "$SHAPE_ONLY" ]; then
  echo "WARN: verify-commit-refs.sh: tracker '${TRACKER_KIND}' not queryable here — ${SHAPE_ONLY}accepted on shape only (no existence check). See #501." >&2
fi

if [ -n "$CLOSED" ]; then
  cat >&2 <<MSG
WARN: Commit message references CLOSED issue(s) in ${TRACKER_REPO}:
  ${CLOSED}
This commit is allowed through — a commit may legitimately reference the
issue it just closed. But at PR-create time the stricter rule applies: every
PR needs its own OPEN ticket. If this commit will end up in a PR that points
at the closed issue as its primary ticket, create a new open ticket first.
MSG
fi

exit 0
