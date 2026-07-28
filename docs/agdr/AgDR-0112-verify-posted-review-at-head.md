---
id: AgDR-0112
timestamp: 2026-07-28T11:00:00Z
agent: claude (orchestrator)
model: claude-opus-5
trigger: user-prompt
status: executed
---

# Verify the code review server-side: an opt-in merge gate on a posted review at HEAD

> In the context of the review-marker backstop becoming advisory ([AgDR-0111](AgDR-0111-marker-gate-plain-advisory.md)), facing the fact that the merge gate's only evidence a review happened is a local file an agent can write, I decided to **add an opt-in merge-gate check that a review was actually posted to the PR at the same commit the marker names** — to achieve server-side verification of "Rex reviewed this", accepting that it is GitHub-only today and off by default.

## Context

The merge gate requires a `*-rex.approved` marker whose SHA matches the PR's forge-reported HEAD.
The SHA half is strong — it comes from the forge. The *existence* half is not: the marker is a
local file, and after AgDR-0111 nothing mechanically prevents an agent writing it.

The gap is narrow but real. A forged marker with the correct SHA passes the gate, and the human
approving the merge sees "Rex approved" with no review comment on the PR to read.

**AgDR-0062 considered this exact control and deferred it**, on the grounds that it is
"unsatisfiable in a single-account setup — GitHub refuses to let an account approve its own PR, so
an author-independence check can never be satisfied and would block every merge."

That reasoning is correct **for the `APPROVED` review state, and only for it.** It does not hold for
a `COMMENTED` review, which GitHub accepts from the PR's own author. Verified against a live
same-account PR (me2resh/apexyard#1049): reviews posted by the PR author return from
`GET /repos/{repo}/pulls/{pr}/reviews` with `state: COMMENTED` and a `commit_id`.

And the canonical reviewer flow **already posts exactly that shape**: per #587 / [AgDR-0075](AgDR-0075-code-reviewer-local-marker-is-gate-signal.md),
`/code-review` submits with `--comment` and states the verdict in the body, precisely because
`--approve` is unavailable single-account. So the artifact this control needs is already being
produced on every review. Nothing new is asked of adopters.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A — Do nothing** | No work; the human nod is still the control | Leaves "a review happened" inferred from a writable local file, immediately after AgDR-0111 removed the write guard |
| **B — Require an APPROVED review at HEAD** | Strongest signal | AgDR-0062's objection stands: unsatisfiable single-account, would block every merge |
| **C — Require ANY posted review at HEAD, opt-in (chosen)** | Satisfiable single-account; verifies server-side; uses an artifact the reviewer flow already produces; default-off so no adopter breaks | GitHub-only today; a determined agent could still post a fake review comment |
| **D — Structure the rex marker** | Raises the local bar | Rejected twice (AgDR-0062, AgDR-0109): "a determined build agent can still type out the fields; gives false confidence" |

## Decision

Chosen: **C**, behind `review_markers.require_posted_review` (default `false`).

`tracker_review_at_sha <repo> <pr> <sha>` in `_lib-tracker.sh` answers the question, with a
deliberately four-way contract so the caller can distinguish *checked, nothing there* from *could
not check*:

| rc | meaning | caller |
|----|---------|--------|
| 0 | a review exists at `<sha>` | proceed |
| 1 | query succeeded, no review at `<sha>` | **block** |
| 2 | query failed (network / auth / no CLI) | **block** — fail closed, per AgDR-0104 |
| 3 | this forge cannot be verified | **skip**, with a visible warning |

**Default off.** This changes merge behaviour for everyone who enables it, and an adopter whose
reviews predate the check would be blocked on their next merge. Opt-in is the honest default; the
config comment says what turning it on buys.

**GitHub only, stated plainly rather than faked.** GitLab exposes MR approvals and diff versions
rather than SHA-stamped review submissions; mapping those onto "a review at this commit" correctly
needs a live GitLab MR to verify against. Building it blind would be exactly the unverified-claim
failure this framework has repeatedly paid for. `glab`/`custom`/`none` therefore return 3 and the
gate skips with a warning rather than bricking those adopters.

## Consequences

- When enabled, "Rex reviewed this" becomes verifiable on the forge instead of inferred from a local
  file. The residual local-forgery exposure accepted in AgDR-0062/0109/0111 is closed for GitHub
  adopters who opt in.
- **Partially reverses AgDR-0062's deferral** — its objection is preserved for the APPROVED state
  and narrowed away from the COMMENTED one.
- A reviewer that writes its marker but fails to post (network) now blocks the merge instead of
  passing it. Correct, and the message says how to fix it.
- Not a proof of review *quality*: an agent that posts a real comment and writes the marker passes.
  This closes "no review happened at all", not "the review was any good". The human nod remains the
  control for the latter.
- One more forge round-trip per merge, only when enabled.

## Artifacts

- Ticket: me2resh/apexyard#1051
- Builds on [AgDR-0111](AgDR-0111-marker-gate-plain-advisory.md) (the backstop went advisory; this
  strengthens the control instead)
- **Narrows** [AgDR-0062](AgDR-0062-rex-marker-authenticity.md)'s deferral of the posted-review
  requirement to the APPROVED state only
- Relies on [AgDR-0075](AgDR-0075-code-reviewer-local-marker-is-gate-signal.md) — the comment-review
  flow that makes this satisfiable
- Tests: `.claude/hooks/tests/test_require_posted_review.sh` (8 cases, both directions)
