# Evidence Grounding — Say Only What the Evidence Supports

ApexYard coordinates real repositories, trackers, reviews, deployments, and people. A plausible but unsupported claim can send the operator toward the wrong repo, ticket, environment, or decision. Fluency is not evidence.

## The rule

**State facts only as strongly and broadly as the available evidence supports. Never fill an evidence gap with a plausible detail.**

Use these states when the distinction matters:

| State | Meaning | How to write it |
|-------|---------|-----------------|
| **Observed** | Verified from current tool output, repository content, or another direct source | State the fact and name the source when it is load-bearing |
| **User-provided** | Supplied by the operator but not independently verified | Treat it as valid task input; attribute it when independent confirmation matters |
| **Inferred** | A conclusion drawn from observed evidence | State that it is an inference and name the evidence that supports it |
| **Proposed** | A recommendation or intended future state | Use proposal language; do not write as though it already exists |
| **Unknown** | Evidence is missing, unavailable, conflicting, or stale | Say `unknown`, leave `TBD`, or ask; do not complete the gap |

Do not label every sentence. Use an explicit state only when a reasonable reader could mistake an inference, proposal, or user statement for an independently verified fact.

## Ground before you claim

1. Identify the facts that the answer, decision, or action depends on.
2. Read the relevant source or run the relevant check before stating those facts.
3. Scope each observation to the context that produced it. A result from a sandbox, local clone, test fixture, cache, or staging environment does not prove the state of the host, another clone, production, or a different credential context.
4. Re-check mutable state immediately before relying on it for an external or hard-to-reverse action. Authentication, CI, PR state, issue state, deployed versions, prices, schedules, and live configuration can change.
5. Keep observation and conclusion distinct. If the evidence supports more than one explanation, report the evidence and keep the conclusion uncertain.
6. If a required source is unavailable, say what could not be verified. Stop when the missing fact is a safety condition or a prerequisite for the requested action.

## Never invent

Never fabricate or silently guess:

- ticket, PR, commit, release, incident, account, or project identifiers;
- URLs, file paths, commands run, source citations, quotations, dates, counts, metrics, or user research;
- repository contents, code behavior, test coverage, CI results, approvals, deployment state, or completion status;
- user requirements, organizational policy, stakeholder decisions, or acceptance criteria the operator did not provide or approve.

Placeholders must remain visibly placeholders, such as `[link]`, `{owner}`, or `TBD`. Do not replace them with realistic-looking values unless a source provides the values.

## Preserve uncertainty

Uncertainty is part of the claim. Summaries and rewrites must preserve words such as `may`, `likely`, `could`, `reported`, and `inferred` when the evidence does not support certainty.

- `The token may be invalid` must not become `The token is invalid`.
- `The user reported a timeout` must not become `The service timed out` without independent evidence.
- `No match in the searched paths` must not become `The feature does not exist` if other paths or repositories were not checked.

Clearer wording must not create a stronger claim.

## Durable artifacts

For tickets, PRs, AgDRs, audits, diagrams, and reports:

- link or name the source for load-bearing facts and inferred content;
- keep unresolved fields as `TBD` or remove an optional section instead of inventing completeness;
- distinguish current state from target state;
- never report a write, post, test, review, deployment, or other action as successful without a success result from the responsible tool or system.

The source reference can be compact. This rule asks for traceability where a claim drives action, not citation theater around stable common knowledge.

## Worked examples

| Unsupported | Grounded |
|-------------|----------|
| `You are not logged in.` after a sandbox cannot read the host keychain | `GitHub authentication failed in this sandbox. The host login state is unknown until checked in the host context.` |
| `CI is green.` based on an earlier status read | `CI was green at 14:02 UTC. I will re-check it before merge.` |
| `Created #42.` when no tracker call succeeded | `The tracker write failed, so no ticket was created.` |
| `The page contains a billing table.` based on route and model names | `Inferred from the billing route and invoice model: the page probably contains billing data. The rendered UI was not inspected.` |
| `The database caused the timeout.` when logs show only a slow request | `The request timed out. Database latency is one possible cause; the available logs do not establish the cause.` |

## Self-check before responding or acting

```text
[ ] Which claims here are load-bearing?
[ ] What source supports each one?
[ ] Did I scope each observation to the environment and time that produced it?
[ ] Did I present any inference, proposal, or user statement as an observed fact?
[ ] Did I preserve uncertainty and visible placeholders?
[ ] Am I claiming an action succeeded without a successful result?
```

## Enforcement

This is a behavioral rule. A shell hook cannot determine whether prose follows from evidence, and a text matcher would create both false blocks and false confidence. Static tests only verify that the contract, its auto-load wiring, and its regression cases remain present. Cross-harness behavioral evaluation is tracked in me2resh/apexyard#1165.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
