# /approve-architecture — Record Per-PR Design-Review Approval

Writes `.claude/session/reviews/<owner>__<repo>__<pr>-architecture.approved` (repo-qualified path, see AgDR-0060) with the current HEAD SHA so the `require-architecture-review.sh` merge-gate hook will let a design-artifact PR through. Without this marker, the hook blocks merges on any PR that touches a technical design, a migration AgDR, or a feature spec / PRD.

This skill is the architecture-review analog of `/approve-design` (UI gate) and `/approve-merge` (CEO gate). Same pattern, different gate. The reviewer is **Tariq (the Solution Architect)**.

## The one rule you must not break

**INVOKE THIS SKILL ONLY ON EXPLICIT, PER-PR, DESIGN-REVIEW APPROVAL.**

Normally Tariq writes the marker himself on an APPROVED verdict (see `.claude/agents/solution-architect.md`). This skill is the **operator path** to record the same marker — for when a human architect reviewed the design, or when you need to re-record after a rebase.

Valid invocation triggers:

- "design review passed" / "architecture approved" / "the design in #42 is sound" — **if and only if** the surrounding context clearly names a specific PR and the design has actually been reviewed against the architecture lens.
- "PR #42 architecture approved" — names the PR explicitly.
- A reply to your own "PR #42's design — architecture review approved?" message that consists of any affirmative token.

**Invalid triggers** (do NOT run this skill):

- "looks good" / "nice design" — when said about a whiteboard sketch, a Figma, or a verbal proposal that is not a specific PR's design artifact. Architecture review means reviewing the *committed design doc / AgDR / spec in a PR*, not a sketch.
- "the approach is fine" — when said in a planning context ("let's go with this approach") rather than a review context ("I've reviewed the design doc against the lens and it's sound").
- "go" / "continue" / "ship it" — umbrella responses to a multi-step plan. Same rule as `/approve-merge`.
- Your own inference that "the design is probably fine." NO. Stop and ask.

**If in doubt: STOP AND ASK.** "PR #X carries a technical design — has it been reviewed and approved against the architecture lens?" is one message. Building against an unsound design is much worse.

## Process

### 1. Parse the PR number

Extract from the argument. If none given, infer from the current branch's open PR (`gh pr view --json number --jq '.number'`) or the user's most recent message. If ambiguous, STOP and ask.

### 2. Sanity-check the user's intent

Re-read the user's most recent message:

- Did they explicitly name this PR, or can I point at a direct "PR #X architecture approved?" question I just asked?
- Was the *design artifact in the PR* reviewed, or just a sketch / verbal proposal?
- Is the approval for this specific PR's design, or for a general direction?

If any are unclear — STOP and ask a per-PR explicit question.

### 3. Verify the PR state

```bash
gh pr view <pr> --json state,isDraft,mergeable,headRefOid
```

- `state` must be `OPEN`. Refuse if `MERGED`, `CLOSED`, or `DRAFT`.
- `mergeable` should be `MERGEABLE` or `UNKNOWN`.
- Capture `headRefOid` — the marker must match the PR's GitHub HEAD.

### 4. Verify the Rex marker exists at current HEAD

Architecture sign-off is a stamp on top of a Rex-approved HEAD (the design PR still gets a normal code review for its prose / diff), not parallel to it. Resolve the ops fork root (NOT git toplevel — inside `workspace/<project>/` the markers live in the ops fork above) and source the marker path helper:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
OPS_ROOT=""
r="$REPO_ROOT"
while [ -n "$r" ] && [ "$r" != "/" ]; do
  if [ -f "$r/.apexyard-fork" ]; then OPS_ROOT="$r"; break; fi
  if [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ]; then OPS_ROOT="$r"; break; fi
  r=$(dirname "$r")
done
MARKER_HOME="${OPS_ROOT:-$REPO_ROOT}"
# shellcheck source=/dev/null
. "$MARKER_HOME/.claude/hooks/_lib-review-markers.sh"
PR_REPO=$(gh pr view <pr> --json headRepository --jq '.headRepository.nameWithOwner' 2>/dev/null)
REX=$(review_marker_path "$PR_REPO" <pr> rex "$MARKER_HOME")
[ -f "$REX" ] && [ "$(tr -d '[:space:]' < "$REX")" = "<headRefOid from step 3>" ]
```

If Rex's marker is missing or its SHA doesn't match HEAD, refuse and tell the user to run the code-reviewer first. Do not write the architecture marker on a stale base.

### 5. Verify the PR actually carries a design artifact

Check whether the PR's diff includes files that trigger the architecture-review gate (technical design, migration AgDR, PRD / spec). If it has none, the marker is unnecessary — tell the user and skip.

```bash
gh pr diff <pr> --name-only | grep -qiE '(docs/agdr/.*migration.*\.md|technical-design|tech-design|/designs/|/prds/|prd.*\.md|feature-spec)'
```

### 6. Write the architecture marker

Use the repo-qualified path via `_lib-review-markers.sh` (already sourced in step 4):

```bash
# (MARKER_HOME and PR_REPO already resolved in step 4 — reuse them here.)
mkdir -p "$MARKER_HOME/.claude/session/reviews"
ARCH=$(review_marker_path "$PR_REPO" <pr> architecture "$MARKER_HOME")
printf '%s\n' "<headRefOid>" > "$ARCH"
```

The file contains exactly one line: the 40-character HEAD SHA + newline. No labels, no JSON.

### 7. Confirm to the user

```
Architecture approval recorded for PR #<pr> at <sha>. The architecture-review merge gate will now allow this design PR through.
```

**Do NOT run `gh pr merge` yourself.** The skill's job ends at recording the marker. The merge is a separate action that still requires the CEO marker via `/approve-merge` plus an explicit merge instruction.

## Notes

- The marker is gitignored (`.claude/session/` is in `.gitignore`). Session state, not code.
- Re-running `/approve-architecture <pr>` is idempotent — overwrites with current HEAD.
- New commits after approval invalidate the marker (the gate compares SHAs) — re-request review.
- This skill does NOT invoke the Solution Architect role. It records approval *after* the design has been reviewed (by Tariq via `/design-review`, or by a human architect).

## Anti-pattern

```
Architect: "The approach we discussed sounds right, go for it"
You: *invokes /approve-architecture 42*  ← WRONG
```

A verbal approval of an *approach* is not a review of the *committed design artifact*. The correct flow:

```
Tech Lead: *commits the technical design to PR #42*
You: "PR #42 carries the technical design. Run /design-review to have Tariq review it against the architecture lens?"
... Tariq reviews, verdict APPROVED ...
You: *Tariq writes the marker automatically* — OR a human architect says "design in #42 reviewed and approved"
You: *invokes /approve-architecture 42*  ← CORRECT
```

## Relationship to other approval skills

| Skill | Marker (repo-qualified, see AgDR-0060) | Gate hook | Who invokes |
|-------|----------------------------------------|-----------|-------------|
| `/approve-merge` | `<owner>__<repo>__<pr>-ceo.approved` | `block-unreviewed-merge.sh` | On explicit CEO per-PR merge nod |
| `/approve-design` | `<owner>__<repo>__<pr>-design.approved` | `require-design-review-for-ui.sh` | On explicit designer per-PR design nod |
| **`/approve-architecture`** | **`<owner>__<repo>__<pr>-architecture.approved`** | **`require-architecture-review.sh`** | On explicit architect per-PR design-review nod (or Tariq writes it on APPROVED) |

All follow the same pattern: verify PR state → verify Rex marker → write marker at ops fork root → confirm → stop. None runs `gh pr merge`.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
