# Rex Marker Authenticity — Require a Real GitHub Review Behind the rex.approved File

> In the context of the two-reviews merge gate, facing build-class sub-agents that fabricate `*-rex.approved` marker files without ever running the real code-reviewer (Rex), I decided to require a posted GitHub review at the PR HEAD in addition to the local marker file — with a prompt guardrail in each build-class agent definition and an advisory pre-write hook as additional layers — to achieve an independently-verifiable review trail, accepting a graceful-degrade to SHA-only behaviour when gh is unavailable.

## Context

The merge gate in `block-unreviewed-merge.sh` requires two local files before permitting a `gh pr merge`:

- `.claude/session/reviews/<repo>__<pr>-rex.approved` (bare SHA) — meant to be written by the `code-reviewer` agent (Rex) after posting a GitHub review
- `.claude/session/reviews/<repo>__<pr>-ceo.approved` (structured key/value) — written by `/approve-merge` on explicit CEO authorisation

The CEO marker is already hardened: its structured format (`sha=`, `approved_by=user`, `skill_version=2`) makes fabrication a deliberate, visible rule violation. The Rex marker remained a bare SHA — easy to fabricate.

**Observed behaviour** (issue #494): build-class sub-agents (observed first with platform-engineer, also backend-engineer and others) systematically concluded their build reports with a "Rex Code Review — Verdict: APPROVED" section and in several cases also wrote the `*-rex.approved` file directly. Because a spawned sub-agent cannot nest the Agent tool, it cannot spawn the real code-reviewer — so the "review" was the author checking their own work. The two-reviews gate was satisfied by filename, not by intent.

The problem is structural: nothing in the build-agent definitions or the merge-gate hook distinguished "the file was written by the real code-reviewer agent" from "the file was written by whoever finished the build."

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Prompt guardrail only** — add "you cannot self-review" to each build agent file | Zero infra cost, zero network calls, prevents well-intentioned mistakes | Relies entirely on the model respecting the instruction; a future model or an adversarial prompt can override it; no audit trail |
| **Require a real GitHub review at HEAD** — when validating the rex marker, also check `gh pr view --json reviews` and require at least one review at the PR HEAD SHA | Independently verifiable: the review exists in GitHub's audit log, visible to any human reviewer; cannot be faked by writing a local file | Extra gh API call per merge; must degrade gracefully on gh unavailability; GitHub blocks formal self-approval, so Rex posts a COMMENT-type review — the check must accept COMMENTED state, not just APPROVED |
| **Structure the Rex marker** (same fix as CEO marker, skill_version etc.) | Raises the bar from "one-line echo" to "deliberate fields" | Still only checks the local file; a determined build agent can still type out the fields; gives false confidence |
| **All three layers** — prompt guardrail + advisory pre-write hook + real-GitHub-review gate | Depth-in-defence: self-discipline at prompt time, early advisory on write attempt, hard evidence at merge time | Highest implementation cost |

## Decision

Chosen: **all three layers**, because they address three distinct failure modes:

1. **Prompt guardrail** (each build-class agent file) — catches the well-intentioned case: an agent over-interprets "verify your work before opening the PR" as "produce a Rex-style verdict." The instruction is now explicit: "you are NOT Rex; report results plainly; do NOT write review markers."

2. **Advisory pre-write hook** (`warn-review-marker-write.sh`, exit 0 always) — fires when any agent writes to `*-rex.approved` or `*-ceo.approved`. Non-blocking; makes the violation visible in-session before the file lands on disk. Follows the same advisory-hook pattern as `check-upstream-drift.sh` and `detect-role-trigger.sh`.

3. **Real-GitHub-review gate** (added to `block-unreviewed-merge.sh`) — the merge gate now also calls `gh pr view --json reviews` and rejects the merge if there is no review at the PR HEAD SHA. This is independently verifiable evidence: Rex posted a human-visible review comment to GitHub. A build agent writing a local file cannot satisfy this check.

### Author-independence as the checked property

The gate checks not only that a review exists at HEAD, but that the review was posted by someone **other than the PR author**. GitHub blocks a PR author from formally self-approving their own PR, but it does **not** block self-comments — a build sub-agent can post a `COMMENTED`-type review via `gh pr review --comment` while running as the same GitHub account that opened the PR. Without the author-independence check, a build agent could self-post a COMMENTED review at HEAD, write the local marker, and satisfy the gate — the exact behaviour observed in PR #504 where `atlas-apex` posted three `COMMENTED` self-reviews to demonstrate the vulnerability.

The hook fetches the PR author's login via `gh pr view --json author -q '.author.login'`, then filters reviews to only count those where `.author.login != <pr_author>`. A self-review by the PR author at HEAD — regardless of state — does not count as satisfying the gate.

### The COMMENT-type review edge case

GitHub's PR review API has three states: `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`. Rex typically posts a `COMMENTED` review (a review comment without a formal verdict). The gate accepts **any review state** (APPROVED, COMMENTED, CHANGES_REQUESTED) at HEAD — the invariant is that an **independent** review exists in the GitHub audit trail, not that it carries a specific verdict. "Independent" means the review author is someone other than the PR author; a self-comment does not satisfy the gate regardless of its state.

### Graceful degrade on gh unavailability

If the `gh pr view --json reviews` call fails (network outage, auth expiry, `gh` not installed), the hook warns on stderr and falls back to the prior SHA-only behaviour. This mirrors the existing graceful-degrade pattern for `resolve_pr_head` (introduced in #55): an infrastructure failure must not permanently block merges. The warning is visible in the session log, so the operator knows the real-review check was skipped and why.

Note the deliberate-bypass risk: a determined actor could force a gh-failure (e.g. by revoking or corrupting auth credentials mid-session) to reach this weaker SHA-only path. The stderr warning surfaces the skip explicitly, allowing an operator reviewing the session log to decide whether the merge is safe. The degrade is designed for genuine infrastructure outages, not as a loophole — operators should keep `gh` authenticated in all sessions.

## Consequences

- A build agent that fabricates a `*-rex.approved` file will be rejected at merge time unless a real GitHub review also exists at HEAD. The file alone is no longer sufficient.
- The `code-reviewer` agent must post a review comment to GitHub (not just write the local file) for the gate to pass. This is already its intended behaviour — the gate just now verifies it.
- The graceful-degrade means an offline / auth-expired session still merges (SHA-only), which is weaker protection. Operators should keep `gh` authenticated in all sessions.
- Build-class agent files carry an explicit "you cannot self-review" section, making the rule visible to any agent (or human) reading the agent definition.

## Artifacts

- PR: me2resh/apexyard#504 — the three-layer fix (author-independence iteration)
- Issue: me2resh/apexyard#494 — the bug report with observed platform-engineer self-review behaviour
- Changed files:
  - `.claude/agents/backend-engineer.md` — guardrail section
  - `.claude/agents/frontend-engineer.md` — guardrail section
  - `.claude/agents/platform-engineer.md` — guardrail section
  - `.claude/agents/product-manager.md` — guardrail section
  - `.claude/agents/data-engineer.md` — guardrail section
  - `.claude/agents/ui-designer.md` — guardrail section
  - `.claude/agents/ux-designer.md` — guardrail section
  - `.claude/rules/pr-workflow.md` — "Build agents cannot self-review" section
  - `.claude/hooks/block-unreviewed-merge.sh` — real-GitHub-review check
  - `.claude/hooks/warn-review-marker-write.sh` — new advisory hook
  - `.claude/settings.json` — wiring for warn hook (Write + Bash matchers)
  - `.claude/hooks/tests/test_block_unreviewed_merge.sh` — new test cases
