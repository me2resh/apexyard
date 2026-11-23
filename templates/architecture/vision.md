<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

<!-- Source: ApexYard · templates/architecture/vision.md · github.com/me2resh/apexyard · MIT -->

# Architecture Vision: {Project Name}

> One page. It states the limits, principles and reuse choices that each design cites.
> Scope: [one sentence on the system or domain this vision covers].
> Owner: [name]. Last reviewed: [YYYY-MM-DD].
>
> Run `/tech-vision <project-name>` to write it. The skill drafts the factual sections from code and documents, with a source on each value. You confirm or correct each value. You write the drivers, principles and what we won't build.
>
> You need more depth? Add the optional Heavy appendix from [`vision-appendix.md`](vision-appendix.md). Do not add it by default.
>
> This page has no diagram. For the current context and containers, see `context.md` and `container.md` in the same folder, written by `/c4`. For the target state, use the Target state section of the appendix.

## Rules for this page

1. A section that does not apply says `Not relevant: <reason>`. Do not leave it empty.
2. Every number has a source and a date, or it is labelled `(estimate)`.
3. An unknown value is `not set (owner: <name>)`. Do not guess a value.

## Drivers

Rank the 3 to 5 forces that shape the architecture. Rank 1 wins a conflict.

1. [Driver, for example "Ship a paid pilot by Q1 with two engineers"]
2. [Driver, for example "Keep the monthly cloud bill under the budget"]
3. [Driver]

## Non-functional requirements

Each row needs a source for each number. Write `not set (owner: <name>)` for an unknown value.

| Requirement | Target | Today | How measured | Source and date |
|-------------|--------|-------|--------------|-----------------|
| [Peak load, for example requests per second] | [target] | [today] | [how and where you measure it] | [file, dashboard or document, and date] |
| [Latency, for example p95 for the main read] | [target] | [today] | [how measured] | [source and date] |
| [Availability] | [target] | [today] | [how measured] | [source and date] |
| [Monthly cost] | [target] | [today] | [how measured] | [source and date] |
| [Data volume and retention] | [target] | [today] | [how measured] | [source and date] |

Add or remove rows. Write `Not relevant: <reason>` in a row that does not apply.

## Principles

Write 3 to 7 one-line principles. Each one constrains a future design.

1. [For example: "Each service owns its data. Other services read it through a published API."]
2. [For example: "Every state-changing endpoint accepts an idempotency key."]
3. [Principle]

## Reuse and vendors

List each capability and what provides it. The last column asks one question: what already in place could replace it?

| Capability | What we use | Reuse, configure, buy or build | What already in place could replace it | Source and date |
|------------|-------------|--------------------------------|----------------------------------------|-----------------|
| [For example: authentication] | [Auth provider or library] | [kind] | [existing service, feature or library, or "nothing"] | [file or document, and date] |
| [For example: email] | [Vendor] | [kind] | [what could replace it] | [source and date] |
| [For example: data processor that holds user data] | [Vendor] | [kind] | [what could replace it] | [source and date] |

## What we won't build

List what the team chose not to build. Give a reason and a "reconsider when" trigger for each item.

- **[Item, for example "Multi-region active-active"]**: [reason]. Reconsider when: [a trigger that you can observe, for example "a second region has paying customers"].
- **[Item]**: [reason]. Reconsider when: [trigger].
