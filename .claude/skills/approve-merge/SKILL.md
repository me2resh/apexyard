---
name: approve-merge
description: Record per-PR CEO approval and merge in one turn. ONLY on an explicit per-PR "approved" — never on umbrella "go".
disable-model-invocation: false
argument-hint: "<pr-number> [--no-merge]"
effort: low
---

# /approve-merge — Record CEO Approval and Merge

Writes a structured marker at `.claude/session/reviews/<owner>__<repo>__<pr>-ceo.approved` (repo-qualified path, see AgDR-0060), then runs `gh pr merge <pr> --squash --delete-branch` in the same turn. The marker contains required key/value fields (not just a bare SHA) so a raw `echo SHA > file` from the model is mechanically rejected by `block-unreviewed-merge.sh`.

This is the **mechanical enforcement** of the "plan-level 'go' is not merge approval" rule in `.claude/rules/pr-workflow.md`. The load-bearing semantic is "every merge needs an explicit per-PR approval", **not** "every merge needs two user messages."

## The one rule you must not break

**INVOKE THIS SKILL ONLY ON EXPLICIT, PER-PR, USER-NAMED MERGE APPROVAL.**

The valid invocation triggers look like this:

- "approved" / "approve" / "merge" / "merge it" / "ship it" / "go ahead and merge" — **if and only if** the surrounding context clearly names a specific PR and the PR being asked about is known.
- "PR #42 is approved" / "yes, merge #42" / "ship #42" — names the PR.
- A reply to your own "Ready to merge PR #42 — approved?" message that consists of any affirmative token — because you just named the PR and the user is responding to that specific question.

**Invalid triggers** (do NOT run this skill):

- "go" / "continue" / "proceed" / "execute the plan" / "ship it" — **when these are said in response to a plan that happens to include a merge step but is not specifically about the merge**. This is the exact failure mode this skill exists to prevent. See the example in `.claude/rules/pr-workflow.md` § "Plan-level 'go' is NOT merge approval".
- "yes" / "ok" / "sure" — if you cannot point at a specific "Ready to merge PR #X?" question in the last two turns of conversation, these are too ambiguous.
- Your own inference that "the user probably wants the merge now because they said 'go' on the plan." NO. Stop and ask explicitly.

**If in doubt: STOP AND ASK.** The cost of one extra "PR #X ready — approved?" question is one message. The cost of a wrong merge is real work to revert.

The fact that this skill now runs the merge as part of its default flow does **not** weaken this rule — it sharpens it. The invocation moment IS the merge moment; you don't get a free second-message safety net to rethink. Invoke only when you're certain.

## Process

### 1. Parse the PR number and flags

Extract the PR number from `$ARGUMENTS`. If no number is given, try to infer from:

- The current branch's open PR via `gh pr view --json number --jq '.number'`
- The user's most recent message, if it named a PR explicitly

If the PR number is ambiguous (multiple PRs on the branch, unclear which was approved), STOP and ask the user which PR.

Recognise the optional `--no-merge` flag. When present, the skill writes the marker but does NOT run the merge. Useful for the rare cases below — see § "Notes" for when to use it.

### 2. Sanity-check the user's intent

Before doing anything, re-read the user's most recent message:

- Did the user explicitly name this PR, or can I point at a direct "Ready to merge PR #X — approved?" question from me that they are responding to?
- Is the user's message a standalone merge nod, or is it an umbrella "go" on a broader plan?
- If the latter — **STOP**. Reply with a per-PR explicit question instead:
  > "PR #X is ready to merge. Just confirming — explicit approval to merge PR #X, now?"

Only proceed past this step if the user has given an unambiguous per-PR approval.

### 3. Verify the PR state

```bash
gh pr view <pr> --repo <owner/repo> --json state,isDraft,mergeable,headRefOid
```

Sanity checks:

- `state` must be `OPEN`. Refuse if it's `MERGED`, `CLOSED`, or `DRAFT`.
- `mergeable` should be `MERGEABLE` or `UNKNOWN` (GitHub hasn't computed yet). Refuse on `CONFLICTING`.
- Capture `headRefOid` — this is the **PR's HEAD on GitHub**, which is the SHA both markers must match. Don't use `git rev-parse HEAD` from the local working tree — it's rarely the PR branch and the merge gate compares against the GitHub-reported HEAD.

### 4. Verify the Rex marker exists at the PR's HEAD

The CEO approval is a stamp on top of a Rex-approved HEAD, not a standalone action.

```bash
# Resolve the OPS FORK ROOT, not git toplevel. Inside workspace/<project>/,
# git toplevel is the project clone; markers live in the ops fork above.
# See me2resh/apexyard#229 + #230.
REPO_ROOT=$(git rev-parse --show-toplevel)
OPS_ROOT=""
r="$REPO_ROOT"
while [ -n "$r" ] && [ "$r" != "/" ]; do
  if [ -f "$r/.apexyard-fork" ]; then OPS_ROOT="$r"; break; fi
  if [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ]; then
    OPS_ROOT="$r"; break
  fi
  r=$(dirname "$r")
done
MARKER_HOME="${OPS_ROOT:-$REPO_ROOT}"

# Source the marker path helper — repo-qualified naming (#485, AgDR-0060).
# shellcheck source=/dev/null
. "$MARKER_HOME/.claude/hooks/_lib-review-markers.sh"
PR_REPO=$(gh pr view <pr> --json headRepository --jq '.headRepository.nameWithOwner' 2>/dev/null)
REX=$(review_marker_path "$PR_REPO" <pr> rex "$MARKER_HOME")
[ -f "$REX" ] && [ "$(tr -d '[:space:]' < "$REX")" = "<headRefOid from step 3>" ]
```

If Rex's marker is missing or its SHA doesn't match the PR HEAD, refuse and tell the user to re-invoke the code-reviewer first. Do not write the CEO marker on a stale base.

### 5. Write the structured CEO marker

The marker is a key/value file with required fields. The format:

```
sha=<40-char hex — must be the PR HEAD from step 3>
approved_by=user
approved_at=<ISO-8601 UTC timestamp, e.g. 2026-05-03T13:25:42Z>
skill_version=2
approval_summary="<truncated user approval message, ≤200 chars>"
```

Required fields the merge gate verifies:

| Field | Why |
|-------|-----|
| `sha=<HEAD>` | Binds the approval to a specific commit. SHA must match the PR's GitHub HEAD. |
| `approved_by=user` | Marker that distinguishes a skill-written marker from a model-fabricated raw `echo SHA > file`. |
| `skill_version=2` (or higher) | Format version. Bare-SHA legacy markers (no `skill_version=`) are rejected by the new gate. Version bump signals a behaviour change to anyone reading the file. |

Optional fields the gate stores but doesn't validate:

| Field | Use |
|-------|-----|
| `approved_at=<ISO>` | Audit-log timestamp. Helpful when reviewing past merges. |
| `approval_summary=<text>` | First ≤200 chars of the user's approval message, sanitised (no shell metachars). Audit trail for "what did the user say when they approved this." |

Use the **ops fork root** as the path anchor (NOT git toplevel — see #229 + #230 for the workspace-clone bug this avoids). Reuse the same MARKER_HOME and the `_lib-review-markers.sh` helper (already sourced in step 4):

```bash
# (MARKER_HOME and PR_REPO already resolved in step 4 — reuse them here.)
mkdir -p "$MARKER_HOME/.claude/session/reviews"
ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Sanitise: drop newlines, drop shell-special chars, truncate to 200.
summary=$(echo "<user approval message>" | tr '\n' ' ' | tr -d '"`$\\' | cut -c1-200)

CEO=$(review_marker_path "$PR_REPO" <pr> ceo "$MARKER_HOME")
cat > "$CEO" <<EOF
sha=<headRefOid>
approved_by=user
approved_at=${ts}
skill_version=2
approval_summary="${summary}"
EOF
```

### 6. Determine merge strategy

Before running the merge, check whether this is a **sync-class PR**. A PR is sync-class if either:

- Its head branch matches `sync/main-to-dev-after-*` (the canonical `/release-sync` branch prefix), OR
- Its PR title starts with `sync(` (the canonical `/release-sync` PR title prefix)

```bash
PR_HEAD_BRANCH=$(gh pr view <pr> --repo <owner/repo> --json headRefName -q '.headRefName' 2>/dev/null)
PR_TITLE=$(gh pr view <pr> --repo <owner/repo> --json title -q '.title' 2>/dev/null)

MERGE_STRATEGY="--squash"  # default for all other PRs
if echo "$PR_HEAD_BRANCH" | grep -qE '^sync/main-to-dev-after-' || \
   echo "$PR_TITLE" | grep -qE '^sync\('; then
  MERGE_STRATEGY="--merge"
fi
```

**Why auto-detect instead of a flag:** a `--merge-strategy` flag would require the operator to remember to pass it on every sync PR merge. Sync PRs squashed silently — the v2.2.0 incident — show that operator ceremony is not a reliable safeguard. Auto-detection makes the correct behaviour the default; an operator who wants to override can do so via the CLI directly. See `AgDR-0053`.

**Why `--merge` for sync PRs:** the sync branch's top commit is a true two-parent merge commit (branch = dev, second parent = main's release squash). That two-parent relationship is the ancestry link that makes future `dev → main` release PRs conflict-free. Squash-merging discards the second parent permanently, defeating the skill's entire purpose. See `AgDR-0053`.

### 7. Run the merge — DEFAULT FLOW

Unless `--no-merge` was passed, run the merge in the same turn using the strategy determined in step 6:

```bash
gh pr merge <pr> --repo <owner/repo> ${MERGE_STRATEGY} --delete-branch
```

The merge command is gated by the existing `block-unreviewed-merge.sh`, `block-merge-on-red-ci.sh`, and `require-design-review-for-ui.sh` PreToolUse hooks. The `block-unreviewed-merge.sh` hook also includes a guard that refuses `--squash` on `sync/`-prefixed PRs — so even a direct `gh pr merge <sync-pr> --squash` will be blocked, protecting against both accidental and deliberate strategy errors. If anything else is wrong, the merge fails with the same error message the user would see if they ran `gh pr merge` themselves. The CEO marker stays on disk so the user can retry the merge after fixing the cause without re-approving.

After a successful merge, capture and report the merge commit SHA:

```bash
gh pr view <pr> --repo <owner/repo> --json mergeCommit -q '.mergeCommit.oid'
```

### 8. Report

Single-line confirmation (include the merge strategy used so the operator can see it):

```
✓ Merged PR #<pr> as commit <sha> (strategy: --squash). Branch deleted.
```

or for sync PRs:

```
✓ Merged PR #<pr> as commit <sha> (strategy: --merge, auto-detected sync PR — ancestry preserved). Branch deleted.
```

If the merge gate blocked, surface the exact error and tell the user how to retry:

```
✗ Merge blocked: <reason from gate>. Marker still on disk at <CEO path from review_marker_path> — run `gh pr merge <pr> --repo <owner/repo> <strategy> --delete-branch` once the issue is fixed (no need to re-invoke /approve-merge).
```

### 9. Optional: post-merge child-issue closure

If the PR's merge commit / PR body contains `Closes <owner/repo>#<N>` references that GitHub's auto-closer didn't catch (squash merges with cross-repo refs sometimes silently miss), you can offer to close them with a comment. This is **out of scope for the default flow** — only do it if the user explicitly asks. Don't auto-close child issues; that's another externally-visible action that needs its own per-issue confirmation.

## --no-merge opt-out

`/approve-merge <pr> --no-merge` writes the marker and stops. Useful when:

- CI is still running and you want to record approval before the green light, then merge later
- You want to record approval but defer the merge for a batch
- You want the marker on disk to unblock a teammate who'll do the merge themselves
- A regulated environment requires temporal separation between approval and execution

The skill never writes the marker AND defers the merge in any other case. The default IS auto-merge.

## Notes

- The marker is gitignored (`.claude/session/` is in `.gitignore`). It's session state, not code.
- Re-running `/approve-merge <pr>` on the same PR is idempotent — overwrites with current HEAD/timestamp. Useful for a small follow-up (rebase, comment-only fixup) where re-running Rex isn't needed.
- New commits after the marker is written invalidate the approval — the hook refuses to merge because `sha=` no longer matches PR HEAD. Re-run Rex + `/approve-merge`.
- The marker format is **versioned**. A bare-SHA legacy marker (skill_version absent) is rejected by the merge gate as of `block-unreviewed-merge.sh` v2 — same release as this skill. Adopters with stale legacy markers from earlier sessions just re-run `/approve-merge` once.
- The skill intentionally does **not** wait/poll for "the user's 'approved'." The skill exists to be invoked, not to poll.

## Why this default changed

Earlier versions of this skill stopped after writing the marker and required a second user message ("merge it" / "go") before running `gh pr merge`. The split was procedural ceremony, not safety: by the time the skill ran, the user had explicitly named the PR, both Rex and CEO markers were on disk with matching SHAs, and the mechanical merge gates would catch any failure. The second message added latency on every merge for a hypothetical "user changes their mind in 30 seconds" case that almost never happened.

The hardened structured-marker format (introduced in the same change) closes the bypass surface that the two-message ceremony was indirectly hedging against — the model writing a marker via raw `echo` to short-circuit approval. Once that bypass is mechanically blocked, the second message has no work left to do.

See AgDR-0012 for the full trade-off.

## Anti-pattern

```
You: "I'll execute the plan. Step 1: approve-merge, Step 2: gh pr merge."
CEO: "go"
You: *invokes /approve-merge*  ← FAILURE
```

The CEO's "go" was on the plan. It was not a per-PR approval for the merge. The correct flow:

```
You: *executes the non-merge steps*
You: "All other steps done. PR #X ready to merge — approved?"
CEO: "approved"
You: *invokes /approve-merge X*  ← writes marker AND merges in one turn
```

The discrete approval moment is **the invocation of /approve-merge**, not a separate "now do the merge" message. Treat the invocation with the seriousness the merge warrants.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
