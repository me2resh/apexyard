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

**AgDR-0062 considered a related control and deferred it.** Its option was *"require at least one
review at the PR HEAD SHA **by an independent reviewer (not the PR author)**"*, deferred because in
a single-maintainer setup "an author-independence check can never be satisfied and would block every
merge."

**That reasoning is correct and this decision does not overturn it.** What ships here is a
deliberately **weaker** control: it requires that *a review exists at HEAD*, and drops the
author-independence requirement entirely. That is why it is satisfiable where AgDR-0062's version
was not — not because AgDR-0062 was wrong, but because this is a different, lesser check.

Being explicit about what that costs: a review posted by the PR's own account satisfies this gate.
It therefore does **not** deliver separation of duties, and must never be described as doing so —
the honest-naming correction from AgDR-0104 § 2 applies here unchanged. What it does deliver is
narrow and real: the review must **exist on the forge, at this commit**, which a local file write
cannot fabricate. It closes "no review happened at all," nothing more.

The mechanism is available because GitHub accepts a `COMMENTED` review from the PR's own author and
returns it with a `commit_id` — verified against a live same-account PR (me2resh/apexyard#1049),
where the PR author's reviews come back from `GET /repos/{repo}/pulls/{pr}/reviews` with
`state: COMMENTED` and a populated `commit_id`. (GitHub refuses only self-*approval*, i.e. the
`APPROVED` state.)

And the canonical reviewer flow **already posts exactly that shape**: per #587 / [AgDR-0075](AgDR-0075-code-reviewer-local-marker-is-gate-signal.md),
`/code-review` submits with `--comment` and states the verdict in the body, precisely because
`--approve` is unavailable single-account. So the artifact this control needs is already being
produced on every review. Nothing new is asked of adopters.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A — Do nothing** | No work; the human nod is still the control | Leaves "a review happened" inferred from a writable local file, immediately after AgDR-0111 removed the write guard |
| **B — AgDR-0062's version: a review at HEAD by an INDEPENDENT reviewer (not the PR author)** | True separation of duties | Its objection stands unchanged: unsatisfiable single-account, would block every merge. Still the right control once a separate reviewer identity exists |
| **C — Require ANY posted review at HEAD, author included, opt-in (chosen)** | Satisfiable single-account; verifies server-side; uses an artifact the reviewer flow already produces; default-off so no adopter breaks | Strictly weaker than B — **no author-independence, so NOT separation of duties**; GitHub-only today; a determined agent could still post a fake review comment |
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
  file. The local-forgery exposure accepted in AgDR-0062/0109/0111 is **raised in cost and made
  auditable — not closed.** An agent with `gh` auth can still satisfy this gate by posting a stub
  `--comment` review at HEAD, and can disable the check outright by editing
  `.claude/project-config.json` (untracked by design, so that edit leaves no git trace). Treat this
  as an **integrity and auditability check, not an anti-adversary barrier**: it catches the
  forged-marker case that actually occurred (#843), catches a stale review after new commits, and
  forces an artifact a human can read on the PR. It does not stop a determined agent.
- **Does NOT reverse AgDR-0062's deferral.** Its independent-reviewer control stays deferred on its
  original terms, and remains the right target once a separate reviewer identity exists. This ships
  a lesser check alongside it.
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
- **Does not supersede** [AgDR-0062](AgDR-0062-rex-marker-authenticity.md) — its independent-reviewer
  gate stays deferred, unchanged; this is a weaker sibling that is satisfiable today
- Relies on [AgDR-0075](AgDR-0075-code-reviewer-local-marker-is-gate-signal.md) — the comment-review
  flow that makes this satisfiable
- Tests: `.claude/hooks/tests/test_require_posted_review.sh` (12 cases, both directions; every fail-open shape is mutation-verified — reverting a fix drops the suite by exactly the case that names it)
