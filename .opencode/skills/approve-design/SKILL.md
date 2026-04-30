---
name: approve-design
description: Record per-PR design-review approval so the design-review merge gate lets the PR through. ONLY invoke this on an explicit designer/user message that names the PR and says the UI changes are approved. NEVER invoke on an umbrella "looks good" about a Figma file, a mockup, or a conversation that didn't name a specific PR. The whole point is to make design approval a discrete, auditable moment tied to a specific PR at a specific commit SHA.
disable-model-invocation: false
argument-hint: "<pr-number>"
effort: low
---

# /approve-design - Record Per-PR Design-Review Approval

Writes `.claude/session/reviews/<pr>-design.approved` with the current HEAD SHA so the `require-design-review-for-ui.sh` merge-gate hook will let a UI PR through. Without this marker, the hook blocks merges on any PR that touches `.tsx`, `.jsx`, `.vue`, `.svelte`, `.css`, `.scss`, `.sass`, `.less`, or `design-tokens*` files.

This skill is the design-review analog of `/approve-merge` (which writes the CEO marker for the merge gate). Same pattern, different gate.

## The one rule you must not break

**INVOKE THIS SKILL ONLY ON EXPLICIT, PER-PR, DESIGN-REVIEW APPROVAL.**

The valid invocation triggers look like this:

- "design approved" / "UI looks good" / "design review passed" — **if and only if** the surrounding context clearly names a specific PR and the designer has actually reviewed the PR's visual changes.
- "PR #42 design approved" / "the UI in #42 looks right" — names the PR explicitly.
- A reply to your own "PR #42 has UI changes — design review approved?" message that consists of any affirmative token — because you just named the PR and the user/designer is responding to that specific question.

**Invalid triggers** (do NOT run this skill):

- "looks good" / "nice" / "approved" — **when said about a Figma mockup, a design spec, a screenshot, or any artifact that is not a specific PR's diff**. Design review means reviewing the *actual code changes in a PR*, not a mockup. A mockup approval and a PR approval are different moments.
- "the design is fine" — **when said in a planning context** ("let's go with this design approach") rather than a PR-review context ("I've looked at the PR diff and the implementation matches the design"). The skill is for the latter.
- "go" / "continue" / "ship it" — when these are umbrella responses to a multi-step plan. Same rule as `/approve-merge`.
- Your own inference that "the designer probably approves because they liked the mockup earlier." NO. Mockup approval ≠ implementation approval. Stop and ask.

**If in doubt: STOP AND ASK.** "PR #X has UI changes — has the design been reviewed and approved?" is one message. Merging a PR with incorrect UI that needs a follow-up revert is much worse.

## Process

### 1. Parse the PR number

Extract from `$ARGUMENTS`. If no argument is given, try to infer from:

- The current branch's open PR via `gh pr view --json number --jq '.number'`
- The user's most recent message, if it named a PR explicitly

If the PR number is ambiguous, STOP and ask.

### 2. Sanity-check the user's intent

Before writing the marker, re-read the user's most recent message. Ask yourself:

- Did the user/designer explicitly name this PR, or can I point at a direct "PR #X design approved?" question from me that they are responding to?
- Did the designer review the *PR diff* (code changes), or just a mockup / screenshot / Figma link?
- Is the approval for the design aspects of this specific PR, or for a general design direction?

If any of these are unclear — **STOP**. Reply with a per-PR explicit question:
> "PR #X touches UI files (.tsx/.css/etc). Has the design review been completed on the actual PR diff — approved?"

### 3. Verify the PR state

Run `gh pr view <pr> --json state,isDraft,mergeable`. Sanity checks:

- `state` must be `OPEN`.
- Refuse if `MERGED`, `CLOSED`, or `DRAFT`.
- `mergeable` should be `MERGEABLE` or `UNKNOWN`.

### 4. Verify the Rex marker exists at current HEAD

Design review is a stamp on top of a Rex-approved HEAD, not parallel to code review. Check (using an absolute path anchored at the repo root):

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
REX="$REPO_ROOT/.claude/session/reviews/<pr>-rex.approved"
[ -f "$REX" ] && [ "$(tr -d '[:space:]' < "$REX")" = "$(git rev-parse HEAD)" ]
```

If Rex's marker is missing or its SHA doesn't match HEAD, refuse and tell the user to re-invoke the code-reviewer first. Do not write the design marker on a stale base.

### 5. Verify the PR actually touches UI files

Check whether the PR's diff includes files that would trigger the design-review gate. If the PR has NO UI files, the marker is unnecessary — tell the user and skip.

```bash
gh pr diff <pr> --name-only | grep -qE '\.(tsx|jsx|vue|svelte|css|scss|sass|less)$|design-tokens'
```

### 6. Write the design marker

Construct the path from the repo root (same lesson as `/approve-merge` — never use cwd-relative paths):

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
mkdir -p "$REPO_ROOT/.claude/session/reviews"
git rev-parse HEAD > "$REPO_ROOT/.claude/session/reviews/<pr>-design.approved"
```

The file contains exactly one line: the 40-character HEAD SHA.

### 7. Confirm to the user

Output a single-line confirmation:

```
Design approval recorded for PR #<pr> at <sha>. The design-review merge gate will now allow this PR through.
```

**Do NOT run `gh pr merge` yourself in the same turn.** The skill's job ends at recording the marker. The merge is a separate action that still requires the CEO marker via `/approve-merge` plus an explicit merge instruction.

## Notes

- The design marker is gitignored (`.claude/session/` is in `.gitignore`). It's session state, not code.
- Re-running `/approve-design <pr>` is idempotent — it overwrites the marker with the current HEAD.
- New commits after the design approval invalidate the marker: the hook will refuse to merge because the SHA no longer matches HEAD. This is intentional — a new commit might change the UI. Re-request design review.
- This skill does NOT invoke the UI Designer role. It records the approval *after* the designer has reviewed. The review itself happens through whatever process the team uses (role activation, human review, Figma comparison, etc.).

## Anti-pattern

```
Designer: "The mockup in Figma looks great, ship it"
You: *invokes /approve-design 42*  ← WRONG
```

The designer approved a **mockup**, not the **PR's implementation of that mockup**. The implementation might differ from the mockup. The correct flow:

```
Designer: "The mockup in Figma looks great, ship it"
You: *implements the mockup in PR #42*
You: "PR #42 implements the approved mockup. Can you review the PR diff to confirm the implementation matches?"
Designer: "Reviewed PR #42, implementation matches the mockup. Design approved."
You: *invokes /approve-design 42*  ← CORRECT
```

Two distinct moments. One is mockup approval (design phase). The other is implementation-review approval (code-review phase). They are not the same approval.

## Relationship to other approval skills

| Skill | Marker | Gate hook | Who invokes |
|-------|--------|-----------|-------------|
| `/approve-merge` | `<pr>-ceo.approved` | `block-unreviewed-merge.sh` | On explicit CEO per-PR merge nod |
| **`/approve-design`** | `<pr>-design.approved` | `require-design-review-for-ui.sh` | On explicit designer per-PR design nod |

Both skills follow the same pattern: verify PR state → verify Rex marker → write marker at repo root → confirm → stop. Both refuse to write on a stale Rex base. Both are invalidated by new commits. Neither runs `gh pr merge`.

The merge flow for a UI PR requires **three** markers before the merge-gate hooks allow through:

1. `<pr>-rex.approved` — from the code-reviewer agent
2. `<pr>-design.approved` — from this skill
3. `<pr>-ceo.approved` — from `/approve-merge`
