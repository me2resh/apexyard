---
name: approve-merge
description: Record per-PR CEO approval for a specific PR merge. ONLY invoke this on an explicit user message that names the PR and says "approved" / "merge" / "ship it". NEVER invoke it on an umbrella "go" / "continue" / "execute the plan" that happens to include a merge step. The whole point of this skill is to make merge approval a discrete, auditable moment — if you are not certain the user's most recent message is an explicit per-PR merge nod, STOP and ask.
disable-model-invocation: false
argument-hint: "<pr-number>"
effort: low
---

# /approve-merge - Record CEO Per-PR Merge Approval

Writes `.claude/session/reviews/<pr>-ceo.approved` with the current HEAD SHA so the `block-unreviewed-merge.sh` hook will let a `gh pr merge` through. This is the **mechanical enforcement** of the "plan-level 'go' is not merge approval" rule in `.claude/rules/pr-workflow.md`.

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

## Process

### 1. Parse the PR number

Extract from `$ARGUMENTS`. If no argument is given, try to infer from:

- The current branch's open PR via `gh pr view --json number --jq '.number'`
- The user's most recent message, if it named a PR explicitly

If the PR number is ambiguous (multiple PRs on the branch, unclear which was approved), STOP and ask the user which PR.

### 2. Sanity-check the user's intent

Before writing the marker, re-read the user's most recent message. Ask yourself:

- Did the user explicitly name this PR, or can I point at a direct "Ready to merge PR #X — approved?" question from me that they are responding to?
- Is the user's message a standalone merge nod, or is it an umbrella "go" on a broader plan?
- If the latter — **STOP**. Reply with a per-PR explicit question instead:
  > "PR #X is ready to merge. Just confirming — explicit approval to merge PR #X, now?"

Only proceed past this step if the user has given an unambiguous per-PR approval.

### 3. Verify the PR state

Run `gh pr view <pr> --json state,isDraft,mergeable,reviewDecision`. Sanity checks:

- `state` must be `OPEN`. Refuse if it's `MERGED`, `CLOSED`, or `DRAFT`.
- `mergeable` should be `MERGEABLE` or `UNKNOWN` (GitHub hasn't computed yet). Refuse on `CONFLICTING`.
- `reviewDecision` is informational — the Rex marker is the ground truth for "code-reviewer approved." If Rex hasn't approved yet, refuse (the merge hook will block anyway, but failing fast is kinder).

### 4. Verify the Rex marker exists at current HEAD

The CEO approval is a stamp on top of a Rex-approved HEAD, not a standalone action. Check (using an absolute path anchored at the repo root, not a cwd-relative path):

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
REX="$REPO_ROOT/.claude/session/reviews/<pr>-rex.approved"
[ -f "$REX" ] && [ "$(tr -d '[:space:]' < "$REX")" = "$(git rev-parse HEAD)" ]
```

If Rex's marker is missing or its SHA doesn't match HEAD, refuse and tell the user to re-invoke the code-reviewer first. Do not write the CEO marker on a stale base.

### 5. Write the CEO marker

Construct the marker path from the repo root so it doesn't matter which subdirectory the skill was invoked from (you might be inside `workspace/<project>/` at the time). The `block-unreviewed-merge.sh` hook looks for markers at `$(git rev-parse --show-toplevel)/.claude/session/reviews/` — use the same anchor:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
mkdir -p "$REPO_ROOT/.claude/session/reviews"
git rev-parse HEAD > "$REPO_ROOT/.claude/session/reviews/<pr>-ceo.approved"
```

The file contains exactly one line: the 40-character HEAD SHA. **Never use a cwd-relative path** — a marker written to the wrong directory is a silent failure mode: the skill "succeeds", then the hook still blocks the merge with a confusing "CEO marker missing" message pointing at a path that technically exists somewhere else in the tree.

### 6. Confirm to the user

Output a single-line confirmation:

```
CEO approval recorded for PR #<pr> at <sha>. You can now run: gh pr merge <pr>
```

**Do NOT run `gh pr merge` yourself in the same turn.** The skill's job ends at recording the marker. The actual merge is a separate tool call that, per the rule, should also be treated as an explicit action. Confirming back to the user gives them a chance to interrupt if something is off (e.g. they approved but then realised they wanted to look at something else first).

## Notes

- The CEO marker is gitignored (`.claude/session/` is in the repo's `.gitignore`). It's session state, not code.
- Re-running `/approve-merge <pr>` on the same PR is idempotent — it overwrites the marker with the current HEAD, which is useful if the CEO re-approves after a rebase or a small follow-up.
- New commits to the PR after the marker is written invalidate the approval: the hook will refuse to merge because the SHA no longer matches HEAD. This is intentional — review + approval are bound to a specific commit.
- The skill intentionally does **not** automate "wait for the user's 'approved' and then run this." The skill exists to be invoked, not to poll.

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
You: *invokes /approve-merge X*
You: *runs gh pr merge X*
```

Two distinct moments. One is the plan authorization. The other is the merge authorization. They are not the same authorization.
