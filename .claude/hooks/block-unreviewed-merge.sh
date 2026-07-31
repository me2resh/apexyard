#!/bin/bash
# CLASS: CONTROL (AgDR-0104 labelling, AgDR-0109). This hook decides on
# STRUCTURED STATE, not on the text of a command: a marker file's contents vs the PR HEAD reported by the forge.
# That is what makes it trustworthy where a text-matching backstop like
# warn-review-marker-write.sh is not. Keep it fail-closed: if it cannot
# evaluate its precondition it must block, never allow (AgDR-0104).
#
# PreToolUse hook on `gh pr merge` AND `gh api .../pulls/<N>/merge`: blocks
# merging a PR that does not have BOTH required approval markers in place.
#
# Both merge shapes are covered — see _lib-extract-pr.sh for the parser and
# #47 for why the API-shape bypass was a gap worth closing.
#
# Enforces workflow-gates rule #5 ("2 reviews — agent + human, CI green,
# commit SHA matches review") at the merge boundary, mechanically. Two
# markers are required:
#
#   .claude/session/reviews/<pr>-rex.approved
#     Written by the code-reviewer agent (Rex) after a successful review.
#     Contents: the commit SHA Rex reviewed.
#
#   .claude/session/reviews/<pr>-ceo.approved
#     Written ONLY by the /approve-merge <pr> skill on explicit user
#     invocation. Contents: the commit SHA the CEO approved.
#
# Both markers must exist, and both SHAs must match the live HEAD. Any
# commits pushed after approval invalidate both — re-review and re-approve.
#
# The CEO marker is the mechanical enforcement of the "plan-level 'go' is
# NOT merge approval" rule in .claude/rules/pr-workflow.md. An umbrella
# "go" on a plan does not produce this file — only the /approve-merge
# skill does, and the skill is defined to run only on explicit user
# invocation that names the PR.
#
# The CEO marker is **structured** (key/value format) so the model
# cannot pass the gate by writing a bare SHA via `echo SHA > file`. The
# hook requires:
#
#   sha=<40-char hex>           # must match the PR's GitHub HEAD
#   approved_by=user            # signals "this was a human, not the model"
#   skill_version=<N>           # N >= 2; bare-SHA legacy markers rejected
#
# Other fields (approved_at, approval_summary) are written by the skill
# but not validated by the hook — they're an audit trail, not a check.
#
# Claude could in principle still forge the structured fields. But the
# act of typing out `approved_by=user` etc. is a visible, auditable,
# grep-able rule violation — much more obvious than an `echo $SHA`. See
# me2resh/apexyard#48 for the design rationale.
#
# The Rex marker is unchanged (still bare-SHA) because Rex's marker is
# written by the code-reviewer agent's automated review flow, not an
# explicit human-authorization moment. Different threat model.

INPUT=$(cat)

# Shared merge-shape detector + PR-number parser (see _lib-extract-pr.sh).
# Handles `gh pr merge <N>` and `gh api repos/<owner>/<repo>/pulls/<N>/merge`.
# Sourced BEFORE the jq-based command parse below (moved up from its
# original position after the parse) so is_merge_command is available as
# the jq-independent fallback detector when the parse can't be trusted —
# see #965.
. "$(dirname "$0")/_lib-extract-pr.sh"
# Repo-qualified marker path helper (#485).
. "$(dirname "$0")/_lib-review-markers.sh"

# Parse .tool_input.command via jq. #965: this used to be the ONLY parse
# path, and an empty/failed result — jq missing from PATH, or jq erroring
# on unexpected input — fell straight through to `exit 0`, silently
# ALLOWING the merge command through completely ungated. A security gate
# must fail CLOSED when it can't evaluate its own precondition, not fail
# open.
#
# But this hook's PreToolUse matcher is `Bash` (every Bash call this
# session runs, not just merges — see .claude/settings.json), so the fix
# can't be "exit 2 whenever jq is unavailable": that would block every
# unrelated Bash command for the rest of the session the moment jq broke,
# which is worse than the bug it replaces. The resolution below keeps the
# jq-unparseable case a no-op EXCEPT when the raw payload text itself
# looks merge-shaped — in that narrower case we cannot safely let the
# command through, so we fail closed instead.
COMMAND=""
if command -v jq >/dev/null 2>&1; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
fi

if [ -z "$COMMAND" ]; then
  # jq is missing, OR jq is present but the parse produced nothing — a
  # genuinely empty command (legitimate no-op) or jq choking on
  # malformed/unexpected JSON. Those two cases are indistinguishable from
  # a parsed field alone, so fall back to a parser-independent scan: reuse
  # is_merge_command (plain grep/sed, no jq dependency) directly against
  # the RAW JSON payload text instead of the parsed command. The command
  # text's own words (`gh`, `pr`, `merge`, digits, spaces) survive JSON
  # string-encoding unchanged, so this is the exact same tested
  # merge-shape detector used below — not a second, drift-prone regex.
  #
  # #973: the command's SEPARATORS do not always survive unchanged — a
  # literal tab (or other JSON-escaped whitespace) encodes as a
  # multi-character escape sequence (`\t`, `\uXXXX`) that `is_merge_command`'s
  # `\s+` regex class won't recognise as whitespace. Normalize the small set
  # of escapes that matter BEFORE scanning, so a merge command with
  # JSON-escaped separators is caught exactly like a space-separated one —
  # see `_normalize_json_escapes` in _lib-extract-pr.sh for the decode and
  # why it's only ever applied on this raw-payload path, never on COMMAND.
  #
  # A payload that isn't merge-shaped at all is a genuine no-op — exit 0,
  # unchanged behaviour for the overwhelming majority of Bash calls this
  # hook sees. A payload that DOES look merge-shaped but that we can't
  # safely parse/verify fails CLOSED (exit 2) instead of silently letting
  # an ungated merge through.
  if is_merge_command "$(_normalize_json_escapes "$INPUT")"; then
    echo "BLOCKED: merge gate cannot evaluate this command — jq is unavailable or .tool_input.command could not be parsed, but the raw input looks merge-related. Refusing to merge until this can be verified. Restore jq (see .claude/hooks/check-jq-installed.sh) and retry." >&2
    exit 2
  fi
  exit 0
fi

if ! is_merge_command "$COMMAND"; then
  exit 0
fi

# --- Configurable human-approver DISPLAY title (me2resh/apexyard#957) ---
# DISPLAY ONLY: this substitutes the printed word for the human per-PR
# merge approver in the messages below. It does NOT affect the marker
# filename (still "-ceo.approved"), the structured fields (sha=,
# approved_by=user, skill_version=), or any gate logic — those are parsed
# and compared exactly as before, regardless of this value. Default "CEO"
# is a zero-behaviour-change no-op.
# shellcheck source=/dev/null
. "$(dirname "$0")/_lib-read-config.sh" 2>/dev/null || true
if command -v config_get_or >/dev/null 2>&1; then
  APPROVER_TITLE=$(config_get_or '.review_markers.human_approver_title' 'CEO')
else
  APPROVER_TITLE="CEO"
fi
[ -z "$APPROVER_TITLE" ] && APPROVER_TITLE="CEO"

# Parse --repo (for `gh pr merge --repo owner/repo`). The API-shape encodes
# the repo in its URL path so we don't need the flag there — downstream
# `gh pr view` / `gh pr checks` calls still benefit when the flag was passed.
CMD_REPO=$(echo "$COMMAND" | sed -nE 's/.*--repo[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
# If the command uses the API shape, recover owner/repo from the URL path
# so other gh calls below can still be scoped correctly.
if [ -z "$CMD_REPO" ]; then
  CMD_REPO=$(echo "$COMMAND" | grep -oE 'repos/[^/[:space:]]+/[^/[:space:]]+/pulls/[0-9]+/merge' | sed -nE 's|repos/([^/]+/[^/]+)/pulls/.*|\1|p' | head -1)
fi

PR_NUMBER=$(extract_pr_number "$COMMAND")
# Also extract the repo so markers are scoped to (repo, pr) — #485.
# CMD_REPO already parsed above; resolve via helper if blank (e.g. current-branch fallback).
# NOTE (#765): approval markers are keyed on the PR's BASE repo. CMD_REPO is the base
# for the sanctioned paths — the --repo value of `gh pr merge --repo` (you cannot merge
# a fork's copy) and the `gh api .../pulls/N/merge` path. The extract_repo_from_command
# fallback below resolves headRepository (the FORK) for a no---repo current-branch merge;
# that residual path is NOT produced by /approve-merge (which always passes --repo), so it
# only affects unsanctioned manual merges. Left as-is to keep the gate core untouched.
if [ -z "$CMD_REPO" ]; then
  CMD_REPO=$(extract_repo_from_command "$COMMAND")
fi

if [ -z "$PR_NUMBER" ]; then
  echo "BLOCKED: Could not determine PR number for merge. Run from a PR branch or pass an explicit PR number." >&2
  exit 2
fi

# --- Sync-PR squash guard (apexyard#459) ---
# /release-sync PRs MUST be merged with --merge (true merge, two parents).
# Squash-merging destroys the second parent (pointing at the release squash
# on main), so the release squash is never an ancestor of dev, and the
# squash-divergence the skill exists to fix is silently re-introduced.
#
# Detection: if the PR's head branch starts with `sync/main-to-dev-after-`,
# refuse a squash/rebase merge on BOTH command shapes:
#   - `gh pr merge <N> --squash` / `--rebase`
#   - `gh api .../pulls/<N>/merge -f merge_method=squash` (or rebase)
# The `gh api` shape is the silent-bypass route that motivated #47, so the
# guard must match `merge_method=squash|rebase` as well as the `--squash`
# flag. The head-branch lookup is delegated to resolve_pr_head_branch (#764) so
# it is forge-aware (gh `.headRefName` / glab `.source_branch`) — a separate API
# call from the HEAD-SHA lookup further down, not the same one.
# On network failure we skip the guard and let the merge proceed — an
# unavailable forge API is not a reason to permanently block all syncs.
if echo "$COMMAND" | grep -qE '(--squash|--rebase|merge_method=squash|merge_method=rebase)'; then
  _SYNC_BRANCH=$(resolve_pr_head_branch "$PR_NUMBER" "$CMD_REPO")
  if echo "$_SYNC_BRANCH" | grep -qE '^sync/main-to-dev-after-'; then
    cat >&2 <<MSG
BLOCKED: Sync PR #${PR_NUMBER} (branch: ${_SYNC_BRANCH}) cannot be squash-merged.

/release-sync PRs MUST be merged with --merge (true merge that preserves both
parents). Squash-merging destroys the second parent (pointing at the release
squash commit on main), so the release squash is NOT made an ancestor of dev —
defeating the entire purpose of /release-sync.

Use --merge instead:
  gh pr merge ${PR_NUMBER} --repo ${CMD_REPO:-<owner/repo>} --merge --delete-branch

Or have the human approver run /approve-merge ${PR_NUMBER} — it auto-detects sync
PRs and uses --merge. That skill is human-only (#1042); the model cannot invoke it.

See AgDR-0053 for the full rationale.
MSG
    exit 2
  fi
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
# Resolve the ops fork root (where session markers live), not the
# workspace clone's git toplevel. Inside `workspace/<project>/`,
# REPO_ROOT is the project clone — markers live in the ops fork
# above it. See me2resh/apexyard#229 + #230.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-ops-root.sh"
  OPS_ROOT=$(resolve_ops_root "$REPO_ROOT")
fi
MARKER_HOME="${OPS_ROOT:-${REPO_ROOT:-.}}"
# Repo-qualified marker paths — scoped to (CMD_REPO, PR_NUMBER) so same-numbered
# PRs in different repos never collide. See AgDR-0060 + me2resh/apexyard#485.
REX_APPROVAL=$(review_marker_path "${CMD_REPO:-unknown}" "$PR_NUMBER" rex "$MARKER_HOME")
CEO_APPROVAL=$(review_marker_path "${CMD_REPO:-unknown}" "$PR_NUMBER" ceo "$MARKER_HOME")

# Resolve the PR's real HEAD via GitHub, not local git (see #55). The local
# HEAD is rarely the PR's HEAD — usually main or an unrelated feature
# branch. Asking gh directly removes the need for `gh pr checkout <N>`
# before every `gh pr merge <N>`.
#
# If the forge call fails we BLOCK (#1091). Falling back to the local HEAD
# would compare markers against an agent-controlled value, which is exactly
# the property this gate exists to deny.
CURRENT_SHA=$(resolve_pr_head "$PR_NUMBER" "$CMD_REPO")
if [ -z "$CURRENT_SHA" ]; then
  cat >&2 <<MSG
BLOCKED: could not resolve PR #${PR_NUMBER}'s HEAD from the forge.

This gate compares the recorded approval SHA against the PR's HEAD **as the
forge reports it** — state that a local file write cannot fabricate. That
comparison IS the property the gate exists to provide.

Until me2resh/apexyard#1091 this fell back to the LOCAL HEAD
(\`git rev-parse HEAD\`) with only a warning. That substituted an
agent-controlled value for the one value in this system an agent cannot
author, so on any forge hiccup the gate silently stopped meaning anything.
A gate that cannot evaluate its precondition must BLOCK, not guess — the same
principle already applied to the jq-unavailable path in #965 (AgDR-0104).

Likely causes: expired or absent forge token, network failure, API rate
limit, or the forge CLI not installed.

To unblock:
  1. Check auth — \`gh auth status\` (or \`glab auth status\`), re-login if needed
  2. Confirm connectivity to the forge
  3. Retry the merge — no approval needs re-recording; the markers are still valid
MSG
  exit 2
fi

# --- Rex marker check ---
if [ ! -f "$REX_APPROVAL" ]; then
  cat >&2 <<MSG
BLOCKED: PR #${PR_NUMBER} has no recorded code-reviewer (Rex) approval.

ApexYard requires two reviews before merge (workflow-gates rule #5):
  1. Code Reviewer agent (Rex) — automated, recorded in .claude/session/reviews/
  2. Human approver (${APPROVER_TITLE}) — recorded by the /approve-merge skill

Missing file:
  ${REX_APPROVAL}

To unblock:
  1. Run the code review on this PR (/code-review ${PR_NUMBER}) — since #1042
     this skill IS model-invocable, so you can do this yourself
  2. When Rex returns "approved", it records the approval automatically
  3. Tell the ${APPROVER_TITLE} the PR is ready and ask THEM to run
     /approve-merge ${PR_NUMBER} — that skill is human-only, you cannot
  4. Their invocation records the approval and performs the merge

Never skip this check — even for typo fixes. See .claude/rules/pr-workflow.md.
MSG
  exit 2
fi

REX_SHA=$(tr -d '[:space:]' < "$REX_APPROVAL")
if [ -n "$REX_SHA" ] && [ -n "$CURRENT_SHA" ] && [ "$REX_SHA" != "$CURRENT_SHA" ]; then
  cat >&2 <<MSG
BLOCKED: Code-reviewer approved commit ${REX_SHA:0:7} but HEAD is now ${CURRENT_SHA:0:7}.

New commits were pushed after the Rex review. Re-invoke Rex on the latest
HEAD before merging.
MSG
  exit 2
fi

# --- Posted-review check (OPT-IN, me2resh/apexyard#1051) ---
# The Rex marker above is a LOCAL FILE. An agent can write it. This optional
# check asks the forge whether a review was actually posted at the same commit,
# turning "Rex reviewed this" from an inferred claim into a verified one.
#
# Off by default: it changes merge behaviour for every adopter and is currently
# GitHub-only. See .claude/project-config.defaults.json → review_markers
# .require_posted_review, and tracker_review_at_sha in _lib-tracker.sh.
# Read the flag. jq is a hard prerequisite of this framework (43 hooks call it,
# and check-jq-installed.sh warns at SessionStart when it's missing) — so this
# does NOT hand-roll a JSON parser for the jq-less case. A merge with jq absent
# is already refused by the #965 guard above, which cannot parse the command and
# fails closed at :113.
REQUIRE_POSTED_REVIEW=false
if command -v config_get_or >/dev/null 2>&1; then
  REQUIRE_POSTED_REVIEW=$(config_get_or '.review_markers.require_posted_review' 'false')
elif [ -f "${MARKER_HOME}/.claude/project-config.json" ] || \
     [ -f "${MARKER_HOME}/.claude/project-config.defaults.json" ]; then
  # config_get_or is undefined — _lib-read-config.sh is missing from a fork that
  # HAS config files. We cannot read the flag, so we cannot know whether this
  # control was supposed to run. Defaulting to false would silently skip it on
  # an operator who turned it on. Fail closed, same as the missing-tracker-lib
  # guard below. This is not a JSON parser (that was the over-engineered version
  # #1051 removed) — it is four lines refusing to guess.
  echo "BLOCKED: .claude/hooks/_lib-read-config.sh is missing, so review_markers.require_posted_review cannot be read. This gate will not assume the check is off — restore the file (a partial install or bad sync usually explains it) and retry." >&2
  exit 2
fi
if [ "$REQUIRE_POSTED_REVIEW" = "true" ]; then
  # Fail closed when the library that performs the check is missing. An
  # `if [ -f … ]` with no else would silently ALLOW the merge here — "couldn't
  # check" masquerading as "checked, fine", which is the one outcome this
  # control exists to prevent (AgDR-0104, and this feature's own AgDR-0112).
  # The operator asked for verification; not being able to verify is a block.
  if [ ! -f "$HOOK_DIR/_lib-tracker.sh" ]; then
    cat >&2 <<MSG
BLOCKED: review_markers.require_posted_review is enabled, but the library that
performs the check is missing:

  ${HOOK_DIR}/_lib-tracker.sh

This control cannot evaluate its precondition, so it denies rather than allows.
Restore the file (a partial install or a bad sync usually explains it), or set
review_markers.require_posted_review to false in .claude/project-config.json if
you deliberately want the server-side check off.
MSG
    exit 2
  fi
  # (The guard above already exited when the lib is absent, so no -f test here.)
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-tracker.sh"
  # Sourcing can succeed on a truncated/corrupt file without defining the
  # function. Fail closed on that too, rather than letting `command not found`
  # produce a rc the case below would misread.
  if ! command -v tracker_review_at_sha >/dev/null 2>&1; then
    echo "BLOCKED: require_posted_review is enabled but tracker_review_at_sha is undefined after sourcing ${HOOK_DIR}/_lib-tracker.sh (truncated or corrupt file). This control cannot evaluate its precondition, so it denies." >&2
    exit 2
  fi
  tracker_review_at_sha "$CMD_REPO" "$PR_NUMBER" "$CURRENT_SHA"
  case $? in
      0) : ;;   # verified — a review exists at this exact commit
      3)
        # SKIP, not block — and the distinction is principled, not a loophole.
        # rc=2 means "I should have been able to check and could not" (broken
        # auth, network, missing CLI): a precondition failure, so it blocks.
        # rc=3 means "this forge is outside my jurisdiction at all" — there is
        # no check to have failed. This is the same distinction AgDR-0109 drew
        # between ambiguity about whether an action is AUTHORISED (block) and
        # ambiguity about whether the action EXISTS (decline). Blocking here
        # would brick every GitLab adopter who enables the flag, in exchange
        # for no security: the check was never available to them.
        #
        # The honest cost, stated here and in the config comment: on a non-gh
        # forge this flag is a NO-OP. Do not enable it and believe you are
        # protected. Tracked for GitLab support in me2resh/apexyard#1051.
        echo "WARN: require_posted_review is enabled but this forge cannot be verified (GitHub only today) — the check is a NO-OP for PR #${PR_NUMBER}; do not rely on it here." >&2
        ;;
      2)
        cat >&2 <<MSG
BLOCKED: could not verify with the forge whether PR #${PR_NUMBER} has a posted
review at ${CURRENT_SHA:0:7}.

review_markers.require_posted_review is enabled, so this check is a CONTROL and
fails closed rather than assuming the review happened (AgDR-0104).

Usually this is a network or \`gh auth\` problem. Fix that and retry. If you
need to merge without the server-side check, set
review_markers.require_posted_review to false in .claude/project-config.json
— deliberately, and knowing the Rex marker is then a local file only.
MSG
        exit 2
        ;;
      *)
        cat >&2 <<MSG
BLOCKED: PR #${PR_NUMBER} has a Rex approval marker at ${CURRENT_SHA:0:7}, but NO
code review was actually posted to the PR at that commit.

The marker is a local file; this check asks the forge. They disagree, which
means one of:

  - the review agent wrote the marker without posting its review, or
  - a review was posted against an EARLIER commit and new work has landed
    since (post a fresh review at HEAD), or
  - the marker was written by something that never reviewed anything.

To unblock: run /code-review ${PR_NUMBER} so a real review is posted at the
current HEAD, then merge.
MSG
        exit 2
        ;;
  esac
fi

# --- CEO marker check ---
# If the marker file doesn't exist on disk, check whether the COMMAND
# itself will create it (compound command: `cat > marker && gh pr merge`).
# PreToolUse hooks fire BEFORE execution, so in a compound command the
# marker write hasn't happened yet. We validate the inline content
# in-memory and let the command through if it's valid. See #426.
_INLINE_CEO_MARKER=""
if [ ! -f "$CEO_APPROVAL" ]; then
  # Look for inline marker content in the command targeting this PR's
  # approval file. Match heredoc, printf, or echo writing to *-ceo.approved.
  # Match both the new repo-qualified basename and the bare-number legacy form
  # so compound commands from /approve-merge are recognised correctly. The
  # SHA-match check below provides the safety backstop.
  CEO_BASENAME=$(basename "$CEO_APPROVAL")
  if echo "$COMMAND" | grep -qE "(${CEO_BASENAME}|${PR_NUMBER}-ceo\.approved)"; then
    # Extract sha=, approved_by=, skill_version= from the command string.
    _inline_sha=$(echo "$COMMAND" | grep -oE 'sha=[0-9a-f]{40}' | head -1 | cut -d= -f2)
    _inline_approved_by=$(echo "$COMMAND" | grep -oE 'approved_by=[a-z]+' | head -1 | cut -d= -f2)
    _inline_skill_version=$(echo "$COMMAND" | grep -oE 'skill_version=[0-9]+' | head -1 | cut -d= -f2)
    if [ -n "$_inline_sha" ] && [ "$_inline_approved_by" = "user" ] && \
       [ -n "$_inline_skill_version" ] && [ "$_inline_skill_version" -ge 2 ] 2>/dev/null; then
      _INLINE_CEO_MARKER="valid"
      CEO_SHA="$_inline_sha"
      CEO_APPROVED_BY="$_inline_approved_by"
      CEO_SKILL_VERSION="$_inline_skill_version"
    fi
  fi
  if [ "$_INLINE_CEO_MARKER" != "valid" ]; then
    cat >&2 <<MSG
BLOCKED: PR #${PR_NUMBER} has Rex approval but no ${APPROVER_TITLE} approval marker.

Plan-level "go" / "continue" / "ship it" does NOT authorize a merge. Each
merge requires an explicit per-PR, per-merge ${APPROVER_TITLE} approval that
names the PR. See .claude/rules/pr-workflow.md § "Plan-level 'go' is NOT
merge approval" for the full rationale.

Missing file:
  ${CEO_APPROVAL}
  (filename stays "-ceo.approved" regardless of the configured approver
   title above — only the printed word changes, never the marker name.)

To unblock:
  1. Stop and tell the ${APPROVER_TITLE} the PR is ready, naming it:
     "PR #${PR_NUMBER} is ready to merge."
  2. Ask THEM to run the skill. Since #1042 it is human-only
     (disable-model-invocation: true) — you cannot invoke it:
       /approve-merge ${PR_NUMBER}
  3. Their invocation writes the structured marker AND runs the merge in
     one turn. Your job ends at step 1.

NEVER create this marker yourself. You have no path to it, and that is the
point: the invocation IS the approval, so it must come from a human.
EVER. This is the exact failure this hook exists to prevent.
MSG
    exit 2
  fi
fi

# Parse the structured CEO marker — from file unless already extracted
# from inline command content (compound-command path, see #426 above).
if [ "$_INLINE_CEO_MARKER" != "valid" ]; then
  # Required fields (#48):
  #   sha=<40-char hex>
  #   approved_by=user
  #   skill_version=<N>  with N >= 2
  #
  # Bare-SHA legacy markers (single line, no `=`) fail the parse and are
  # rejected with a clear "stale format" message pointing at /approve-merge.
  ceo_field() {
    grep -E "^${1}=" "$CEO_APPROVAL" 2>/dev/null \
      | head -1 \
      | sed -E "s/^${1}=//" \
      | sed -E 's/^"(.*)"$/\1/'
  }

  CEO_SHA=$(ceo_field sha)
  CEO_APPROVED_BY=$(ceo_field approved_by)
  CEO_SKILL_VERSION=$(ceo_field skill_version)
fi

# Reject the bare-SHA legacy format. A marker with no `sha=` line is either
# a pre-#132 plain-SHA file or something the model fabricated via raw echo
# without the structured fields. Either way: not acceptable.
if [ -z "$CEO_SHA" ]; then
  cat >&2 <<MSG
BLOCKED: PR #${PR_NUMBER} ${APPROVER_TITLE} marker is in a stale or unrecognised format.

The marker at (filename is always "-ceo.approved", regardless of the
configured approver title):
  ${CEO_APPROVAL}

does not contain the required \`sha=<HEAD>\` line. Either it's a pre-#132
bare-SHA marker, or it was written by something other than the
/approve-merge skill (e.g. a raw \`echo\` or \`touch\`).

Re-record the approval with the current skill:
  /approve-merge ${PR_NUMBER}

The new skill writes a structured marker AND runs the merge in one turn,
so you don't need to re-confirm separately. See me2resh/apexyard#48 +
me2resh/apexyard#132 for the design rationale.
MSG
  exit 2
fi

if [ "$CEO_APPROVED_BY" != "user" ]; then
  cat >&2 <<MSG
BLOCKED: PR #${PR_NUMBER} ${APPROVER_TITLE} marker is missing the \`approved_by=user\` field.

The marker at ${CEO_APPROVAL} has \`approved_by=${CEO_APPROVED_BY:-<empty>}\`,
but the merge gate requires exactly \`approved_by=user\`. This field
distinguishes a skill-written marker from a model-fabricated one. (The
marker filename stays "-ceo.approved" regardless of the configured title.)

Re-record via /approve-merge ${PR_NUMBER} (which writes the field
correctly) — never edit the marker by hand.
MSG
  exit 2
fi

# skill_version must be present and >= 2. The version exists so a future
# format change can bump it without breaking existing markers in flight.
if [ -z "$CEO_SKILL_VERSION" ] || [ "$CEO_SKILL_VERSION" -lt 2 ] 2>/dev/null; then
  cat >&2 <<MSG
BLOCKED: PR #${PR_NUMBER} ${APPROVER_TITLE} marker has skill_version=${CEO_SKILL_VERSION:-<missing>}.

The merge gate requires skill_version >= 2 (the structured-marker format
introduced in me2resh/apexyard#48 + #132). Older markers are no longer
accepted — re-record via /approve-merge ${PR_NUMBER}.
MSG
  exit 2
fi

if [ -n "$CEO_SHA" ] && [ -n "$CURRENT_SHA" ] && [ "$CEO_SHA" != "$CURRENT_SHA" ]; then
  cat >&2 <<MSG
BLOCKED: ${APPROVER_TITLE} approved commit ${CEO_SHA:0:7} but HEAD is now ${CURRENT_SHA:0:7}.

New commits were pushed after the ${APPROVER_TITLE} approval. Re-request
${APPROVER_TITLE} approval via /approve-merge ${PR_NUMBER} on the new HEAD
before merging.
MSG
  exit 2
fi

exit 0
