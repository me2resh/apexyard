# The Contrarian — an advisory premise-level adversary

> In the context of a framework rich in artifact reviewers (Rex/code, Hakim/security, Tariq/design) but with no role that challenges whether an idea is worth doing at all, facing the failure mode of ideas sailing into Build because no one was tasked to argue against them, I decided to add **The Contrarian (Naqid)** — an on-demand, advisory-only adversarial agent that steelmans then challenges a premise — to achieve earned rather than assumed confidence before build effort is sunk, accepting that it is non-blocking and therefore relies on the operator actually invoking it.

## Context

ApexYard already adversarially verifies *built artifacts*: Rex reviews code, Hakim reviews security, Tariq reviews design soundness — each gates a merge. But nothing in the framework challenges the **premise**: *should we build this, is it scoped right, is there a cheaper path, what are we assuming?* That critique today happens (if at all) ad-hoc, in the same voice that proposed the idea — which is exactly when motivated reasoning is strongest. The "play devil's advocate" reflex existed only as an unstructured prompt.

The request (#704): a first-class adversarial role that can be pointed at an idea, feature, spec, decision, plan, or AgDR and reliably argue the other side — *before* the idea hardens into committed work.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Advisory on-demand agent (chosen)** | Cheap to invoke, no new gate to slow delivery, fits the existing utility-agent pattern (Rex/Tariq), human keeps the call | Relies on the operator remembering to invoke it; a skipped challenge catches nothing |
| Blocking gate (challenge required before Build) | Guarantees every idea is challenged | Wrong tool for a *premise* — there's no objective pass/fail; would devolve into rubber-stamping and add friction to every feature; premises aren't artifacts a SHA can pin |
| Auto-fire on diffs (like the role-trigger hooks) | No need to remember | The premise isn't in a diff — by the time code exists, the cheap-to-change moment has passed; path-matching can't detect "this idea is questionable" |
| Fold into Tariq (Solution Architect) | One fewer role | Conflates "is the design sound?" (Tariq) with "should we do this at all?" (Contrarian) — different questions, different lens; Tariq reviews an authored design, the Contrarian attacks an unbuilt premise |

## Decision

Chosen: **an advisory-only, on-demand agent (`contrarian`, persona Naqid) + a `/challenge` skill**, because the thing being reviewed (a premise) is subjective and best-attacked *early*, where a blocking gate is the wrong shape and auto-firing is impossible. Two design commitments make it useful rather than noisy:

1. **Steelman-first method (load-bearing).** The agent must state the strongest honest case *for* the idea before any objection. This converts it from a naysayer into a thinking partner and is the single rule that determines whether the output is trusted.
2. **Advisory, never blocking.** No Write/Edit tools, no markers, no gate. It informs a human decision; it never vetoes one. This is the deliberate difference from Rex/Hakim/Tariq, who gate their artifacts.

The persona **Naqid** (ناقد, "the critic") is new and non-colliding with the existing 25-name roster.

## Consequences

- A repeatable `/challenge <idea | #N | path | plan>` move replaces the ad-hoc "play devil's advocate" prompt; output is structured (Steelman · Hidden assumptions · Failure modes · Strongest objections by severity · Cheaper alternatives · What-would-have-to-be-true · Verdict).
- Because it is non-blocking, value depends on adoption — mitigated by prompted triggers ("challenge this", "play devil's advocate") and an *optional* advisory offer at high-stakes moments (`/decide`, `/write-spec`, plan-mode exit). The offer is a nudge, never forced.
- Adds one agent (→ roster count) and one skill (→ `/challenge`); registered in `CLAUDE.md`, `.claude/rules/role-triggers.md`.
- Risk: a poorly-calibrated Contrarian that manufactures dissent to justify itself. Mitigated by explicit rules — be brief where the idea is sound, calibrate severity honestly, offer a path not just a wall.

## Artifacts

- Agent: `.claude/agents/contrarian.md`
- Skill: `.claude/skills/challenge/SKILL.md`
- Ticket: me2resh/apexyard#704
- Registration: `CLAUDE.md`, `.claude/rules/role-triggers.md`
