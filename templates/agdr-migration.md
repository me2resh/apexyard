# {Short Title}

> In the context of {context}, facing {concern}, I decided to execute {migration type} affecting {tables/entities} to achieve {goal}, accepting {tradeoff}.

**Migration type**: schema | data | sql | orm
**Affected tables / entities**: {comma-separated}
**Estimated downtime**: none | seconds | minutes | hours — {reasoning}
**Data volume**: {rough row/item count, or "unknown"}
**Target environment(s)**: staging → prod | prod-only | dev-only

## Context

{Why this migration is needed. What changed about the requirements, data model, or external constraints that prompted it. Non-obvious context only — don't re-derive what's already in the ticket.}

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| {option 1} | {pros} | {cons} |
| {option 2} | {pros} | {cons} |

## Decision

Chosen: **{option}**, because {justification}.

## Rollback Plan

**Explicit rollback steps** — write these out concretely, in order. A migration without a tested rollback is not ready for production.

1. {step one — e.g. "Run `DROP TABLE foo_new` to reverse the split"}
2. {step two}
3. {step three}

**Rollback tested against**: {staging | copy of prod | unit fixture | not tested — must fix before shipping}
**Rollback window**: {how long after apply is rollback safe? e.g. "24h — after that, new-shape writes accumulate and the reverse mapping loses fidelity"}

## Cross-Service Consumers

Every service that reads or writes the affected tables/entities must be coordinated. List them explicitly.

- {service A} — {how it accesses this data, deploy order constraint}
- {service B} — {…}
- **none** — {if truly none, say so; this makes review easier}

Deploy-order constraint (if any):

- {e.g. "backend must deploy before the ETL job picks up the new column"}

## Testing Plan

- **Dev smoke**: {local command / test case that exercises the migration path}
- **Staging verify**: {steps + expected state change + query to confirm}
- **Canary / phased rollout**: {if applicable — which slice first, what threshold to proceed}

## Observability

What metrics / logs will confirm the migration succeeded and did not degrade the service?

- **During apply**: {query latency, lock contention, error-rate deltas}
- **Post-apply**: {business metric that should be unchanged, new metric that should now exist}
- **Alerts armed**: {specific thresholds on specific dashboards — "p99 answers query > 500ms for 5m"}

## Consequences

- {consequence 1 — e.g. new shape enables feature X}
- {consequence 2 — e.g. removes option to do Y without another migration}
- {consequence 3 — e.g. increases cold-start DB size by Z GB}

## Artifacts

- Ticket: {#N in tracker repo}
- Commits / PRs: {filled in as the migration ships}
- Staging-run log: {link to CI job or manual run output}
- Post-apply dashboard snapshot: {link once done}
