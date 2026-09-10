# Universal evidence-grounding contract as prose plus regression cases

> In the context of ApexYard carrying several narrow honesty rules but no framework-wide contract for factual claims, facing agent outputs that can generalise a local observation, invent plausible state, or silently turn an inference into a fact, I decided to add one universal evidence-grounding rule, wire it into each auto-loaded instruction surface, and back it with a small human-adjudicated regression corpus to make grounded output the default without pretending a shell hook can verify reasoning, accepting that enforcement remains behavioral until cross-harness evaluation provides stronger evidence.

## Context

- Ticket vocabulary, debugging, handover, inferred mockups, and the agent-review corpus already contain evidence disciplines, but each applies only inside its own workflow.
- The failure is often a scope error rather than a fabricated sentence. A command can prove what happened in one sandbox without proving the state of the host, production, or another credential context.
- Mutable facts such as authentication, CI, PR state, and deployed behavior can become stale between observation and action.
- The contract must cover the main agent, role agents, and skills without copying a long checklist into every prompt.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Repeat grounding instructions in every agent and skill | Each runtime prompt is explicit; local wording can match the workflow | Large duplicated surface; wording drifts; every new agent or skill must remember to copy it |
| **One universal rule + concise auto-load wiring + regression cases** | Single source of truth; applies across workflows; small change; cases make failures concrete | Behavioral rather than mechanically enforced; non-native harnesses depend on their advisory bridge loading correctly |
| Add a claim-verification hook | Appears enforceable; could block before durable writes | A shell hook cannot see a claim's evidence or reasoning context; text matching would miss real errors and block valid uncertainty |
| Add regression cases only | Measures behavior without adding more instruction text | Detects failures after they occur but does not establish the expected default behavior |

## Decision

Chosen: **one universal rule, concise auto-load wiring, and a small regression corpus**, because it gives every framework workflow the same epistemic contract while keeping one maintainable source of truth and avoiding an unsound mechanical gate.

The rule uses five states when the distinction matters: observed, user-provided, inferred, proposed, and unknown. It does not require labels on every sentence. It requires agents to preserve uncertainty, scope observations to the environment that produced them, re-check mutable state before relying on it, and never invent identifiers, links, counts, dates, quotes, results, or completion status.

The initial regression corpus covers execution-context leakage, stale mutable state, invented tracker identifiers, inference presented as observation, lost modality, and tool failure reported as success. The corpus is human-adjudicated in this milestone. Cross-harness automation and release gating belong to me2resh/apexyard#1165.

## Consequences

- `evidence-grounding.md` becomes the single detailed contract. `CLAUDE.md`, `AGENTS.md`, `SYSTEM.md`, and generated advisory bridges carry only the concise invariant and point to the rule.
- Role agents and skills inherit the contract through the framework instructions. Workflow-specific rules can remain stricter, but they must not weaken the universal contract.
- The framework does not add a blocking hook. Static tests verify that the rule, wiring, and regression cases remain present; they do not claim to prove model behavior.
- Load-bearing claims should name their evidence, but ordinary stable facts do not need citation theater. Explicit `Observed` / `Inferred` labels are required only when a reader could mistake one state for another.
- The rule treats preserved modality as factual integrity: `may`, `likely`, and `could` must not become certainty during summarisation or rewriting.

## Artifacts

- Ticket: me2resh/apexyard#1162
- Regression successor: me2resh/apexyard#1165
- Narrow precedents: [AgDR-0036](AgDR-0036-inferred-mockups-honesty.md), [AgDR-0028](AgDR-0028-tech-vision-skill-design.md), and `.claude/rules/ticket-vocabulary.md`
