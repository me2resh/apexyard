#!/bin/bash
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
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Shared merge-shape detector + PR-number parser (see _lib-extract-pr.sh).
# Handles `gh pr merge <N>` and `gh api repos/<owner>/<repo>/pulls/<N>/merge`.
. "$(dirname "$0")/_lib-extract-pr.sh"
# Repo-qualified marker path helper (#485).
. "$(dirname "$0")/_lib-review-markers.sh"

if ! is_merge_command "$COMMAND"; then
  exit 0
fi

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
# flag. (We make our own `gh pr view --json headRefName` call here — it is a
# separate API call from the HEAD-SHA lookup further down, not the same one.)
# On network failure we skip the guard and let the merge proceed — an
# unavailable gh API is not a reason to permanently block all syncs.
if echo "$COMMAND" | grep -qE '(--squash|--rebase|merge_method=squash|merge_method=rebase)'; then
  _SYNC_BRANCH=""
  if [ -n "$CMD_REPO" ]; then
    _SYNC_BRANCH=$(gh pr view "$PR_NUMBER" --repo "$CMD_REPO" \
      --json headRefName -q '.headRefName' 2>/dev/null)
  else
    _SYNC_BRANCH=$(gh pr view "$PR_NUMBER" \
      --json headRefName -q '.headRefName' 2>/dev/null)
  fi
  if echo "$_SYNC_BRANCH" | grep -qE '^sync/main-to-dev-after-'; then
    cat >&2 <<MSG
BLOCKED: Sync PR #${PR_NUMBER} (branch: ${_SYNC_BRANCH}) cannot be squash-merged.

/release-sync PRs MUST be merged with --merge (true merge that preserves both
parents). Squash-merging destroys the second parent (pointing at the release
squash commit on main), so the release squash is NOT made an ancestor of dev —
defeating the entire purpose of /release-sync.

Use --merge instead:
  gh pr merge ${PR_NUMBER} --repo ${CMD_REPO:-<owner/repo>} --merge --delete-branch

Or invoke /approve-merge ${PR_NUMBER} — it auto-detects sync PRs and uses --merge.

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
# Fallback to local HEAD if the gh call fails, with a visible warning, so
# a transient network / auth issue doesn't brick merges entirely.
CURRENT_SHA=$(resolve_pr_head "$PR_NUMBER" "$CMD_REPO")
if [ -z "$CURRENT_SHA" ]; then
  echo "WARN: Could not resolve PR #${PR_NUMBER} HEAD via gh — falling back to local HEAD. If this merge fails, run 'gh pr checkout ${PR_NUMBER}' first or re-authenticate gh." >&2
  CURRENT_SHA=$(git rev-parse HEAD 2>/dev/null)
fi

# --- Rex marker check ---
if [ ! -f "$REX_APPROVAL" ]; then
  cat >&2 <<MSG
BLOCKED: PR #${PR_NUMBER} has no recorded code-reviewer (Rex) approval.

ApexYard requires two reviews before merge (workflow-gates rule #5):
  1. Code Reviewer agent (Rex) — automated, recorded in .claude/session/reviews/
  2. Human approver (CEO) — recorded by the /approve-merge skill

Missing file:
  ${REX_APPROVAL}

To unblock:
  1. Invoke the code-reviewer agent on this PR
  2. When Rex returns "approved", it records the approval automatically
  3. Then run /approve-merge ${PR_NUMBER} for the CEO approval
  4. Retry the merge

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
BLOCKED: PR #${PR_NUMBER} has Rex approval but no CEO approval marker.

Plan-level "go" / "continue" / "ship it" does NOT authorize a merge. Each
merge requires an explicit per-PR, per-merge CEO approval that names the
PR. See .claude/rules/pr-workflow.md § "Plan-level 'go' is NOT merge
approval" for the full rationale.

Missing file:
  ${CEO_APPROVAL}

To unblock:
  1. Stop and ask the CEO explicitly: "PR #${PR_NUMBER} ready to merge — approved?"
  2. When the CEO says "approved" / "merge it" / "ship it" naming PR #${PR_NUMBER},
     invoke the /approve-merge skill:
       /approve-merge ${PR_NUMBER}
  3. The skill writes the structured marker AND runs the merge in one turn

NEVER create this marker yourself from an umbrella "go" on a plan.
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
BLOCKED: PR #${PR_NUMBER} CEO marker is in a stale or unrecognised format.

The marker at:
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
BLOCKED: PR #${PR_NUMBER} CEO marker is missing the \`approved_by=user\` field.

The marker at ${CEO_APPROVAL} has \`approved_by=${CEO_APPROVED_BY:-<empty>}\`,
but the merge gate requires exactly \`approved_by=user\`. This field
distinguishes a skill-written marker from a model-fabricated one.

Re-record via /approve-merge ${PR_NUMBER} (which writes the field
correctly) — never edit the marker by hand.
MSG
  exit 2
fi

# skill_version must be present and >= 2. The version exists so a future
# format change can bump it without breaking existing markers in flight.
if [ -z "$CEO_SKILL_VERSION" ] || [ "$CEO_SKILL_VERSION" -lt 2 ] 2>/dev/null; then
  cat >&2 <<MSG
BLOCKED: PR #${PR_NUMBER} CEO marker has skill_version=${CEO_SKILL_VERSION:-<missing>}.

The merge gate requires skill_version >= 2 (the structured-marker format
introduced in me2resh/apexyard#48 + #132). Older markers are no longer
accepted — re-record via /approve-merge ${PR_NUMBER}.
MSG
  exit 2
fi

if [ -n "$CEO_SHA" ] && [ -n "$CURRENT_SHA" ] && [ "$CEO_SHA" != "$CURRENT_SHA" ]; then
  cat >&2 <<MSG
BLOCKED: CEO approved commit ${CEO_SHA:0:7} but HEAD is now ${CURRENT_SHA:0:7}.

New commits were pushed after the CEO approval. Re-request CEO approval
via /approve-merge ${PR_NUMBER} on the new HEAD before merging.
MSG
  exit 2
fi

exit 0
