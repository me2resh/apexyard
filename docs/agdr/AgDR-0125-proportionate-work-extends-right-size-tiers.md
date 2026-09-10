# Proportionate work as an extension of the right-size tiers

> In the context of ApexYard already classifying changes as Lean, Standard, or Heavy for review ceremony, facing agents that still over-plan, over-build, and over-document small tasks before review begins, I decided to extend the existing right-size rule to planning, implementation, and artifact creation with four working rules and a small regression corpus, to make the smallest sufficient change the default, accepting that enforcement stays behavioral and that the Heavy safeguards stay exactly as they are.

## Context

- `right-size-ceremony.md` (AgDR-0107) applies the three tiers to the review chain only. Nothing in the framework says how large the plan, the change, or the artifact set should be for a given tier.
- The observed failures happen before review: a helper module for one call site, a new dependency where one already in the manifest would do, a plan document for a typo fix, an AgDR or design document written in answer to a question.
- The milestone's kill criterion (me2resh/apexyard#1163) says to cancel a broad rule change if a smaller prompt correction already produces proportionate work. The smallest correction is therefore the correct first move.
- The Heavy safeguards for security, trust-chain edits, migrations, and ambiguous work must not change (initiative anti-scope).

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Extend `right-size-ceremony.md` with a "Proportionate work" section** | One source of truth for tiers; reuses the file that already owns the topic; smallest change that meets the acceptance criteria | Adds length to an existing rule; the four phases share one file with the review guidance |
| Add a new `proportionate-work.md` rule | Clean separation; easier to link | A twenty-first rule file for a topic the existing file already names; the tier definitions would be duplicated or cross-referenced; contradicts the rule it would introduce |
| Edit every agent and skill prompt to say "smallest change" | Explicit at each runtime surface | Large duplicated surface; wording drifts; every new agent must remember to copy it (the same objection recorded in AgDR-0124) |
| Add a diff-size or file-count hook | Appears enforceable | A hook can count files but cannot judge need; it would block legitimate Heavy work and pass a needless one-file abstraction; a blocking classifier reintroduces the rigidity AgDR-0107 removed |

## Decision

Chosen: **extend `right-size-ceremony.md`**, because the tiers already exist there, the acceptance criteria ask for reuse of existing files and patterns before adding new ones, and a new rule file would be the exact kind of undemonstrated artifact the change is meant to prevent.

The extension adds a phase-by-tier table (planning, implementation, artifact creation, review) and four working rules: start with the smallest change that satisfies the acceptance criteria; reuse before adding; require a demonstrated need for every new dependency, abstraction, service, or durable artifact; and keep advice and quick assessments conversational unless a gate or the operator requires a durable artifact. The two rails from AgDR-0107 apply unchanged: security, trust chain, and migrations are Heavy at any diff size, and ambiguity rounds up.

The auto-loaded surfaces (`CLAUDE.md`, `AGENTS.md`, `SYSTEM.md`, the generated Cursor bridge) carry one sentence each and point to the rule. Seven human-adjudicated regression cases record the observable failure and pass for each working rule and for both rails. A static test pins the rule text, wiring, cases, and this record. Behavioral scoring belongs to me2resh/apexyard#1165.

## Consequences

- Agents read the tier once and apply it to the whole task, not only to the review at the end.
- "Smallest sufficient" is measured against the acceptance criteria and the Heavy safeguards together. A material decision still gets an AgDR at any diff size (`agdr-decisions.md`).
- No new rule file, agent, hook, or dependency is added. The framework's rule count stays at twenty.
- If #1165 shows the corpus still failing after this correction, the milestone's kill criterion has not fired, and a broader change can be reconsidered with that evidence.
- The `enforce-budget.sh` token meter remains premium-only; the OSS framework's disproportion watch stays the agent's judgment (me2resh/apexyard#1044).

## Artifacts

- Ticket: me2resh/apexyard#1163
- Regression successor: me2resh/apexyard#1165
- Prior decision: [AgDR-0107](AgDR-0107-right-size-ceremony.md) (review tiers), [AgDR-0116](AgDR-0116-lean-tier-reachable.md) (Rex runs at every tier)
- Sibling contract: [AgDR-0124](AgDR-0124-universal-evidence-grounding-contract.md)
