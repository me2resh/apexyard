---
id: AgDR-0106
timestamp: 2026-07-22T00:00:00Z
agent: claude (Tech Lead — Hisham)
model: claude-opus-4-8[1m]
trigger: user-prompt
status: executed
---

# UI design-gate authority: UI Designer owns the routine gate, Head of Design is the escalation

> In the context of an agent-spec audit ([#984](https://github.com/me2resh/apexyard/issues/984)) finding three shared docs disagreeing on who holds UI merge sign-off — the design role files said Head of Design while `workflows/code-review.md` assigned the conditional design reviewer to the UI Designer — facing a genuine ambiguity in who reviews a routine UI PR versus who owns the design system, we decided the **UI Designer (Nour) owns the routine per-PR design gate and the Head of Design (Maha) is the escalation path**, to achieve a single consistent authority statement across `role-triggers.md`, `workflows/code-review.md`, and the design role files, accepting that a UI PR whose design concern genuinely exceeds a practitioner's scope now takes one extra hop to the Head of Design.

## Context

- The audit surfaced a three-doc contradiction: `roles/design/*` implied the Head of Design signs off UI PRs, while `workflows/code-review.md` already listed the **UI Designer** as the conditional design reviewer and `workflows/sdlc.md` named the UI Designer as the design gate. Readers couldn't tell who actually holds the merge-blocking `require-design-review-for-ui.sh` gate.
- ApexYard already runs a **practitioner-reviews / head-escalates** shape everywhere else: Rex (Code Reviewer) does the routine code review and escalates architecture calls to the Head of Engineering; Tariq (Solution Architect) reviews design artifacts and escalates to the Head of Engineering. UI design review is the same shape with no reason to differ.
- The `/approve-design` skill and `require-design-review-for-ui.sh` gate are the mechanical surface; they record a per-PR design approval, which is a routine, per-diff act — the kind of work a practitioner reviewer owns, not the org's most senior designer.
- A parallel ticket (#980) aligns the design **role files** to this same resolution; this AgDR + the shared-docs edits ([#984](https://github.com/me2resh/apexyard/issues/984)) own the cross-cutting docs side.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A — Head of Design owns all UI sign-off** | Single senior owner; strong consistency of taste | Bottlenecks every UI PR on the org's most senior designer; contradicts `workflows/code-review.md`'s existing conditional-reviewer assignment; breaks the practitioner-reviews shape used for code (Rex) and design artifacts (Tariq) |
| **B — UI Designer owns routine gate, Head of Design escalation (chosen)** | Mirrors Rex/Tariq → Head-of-Engineering; keeps routine review fast; matches the existing code-review.md + sdlc.md wording; leaves a clear escalation for design-system / cross-product / disagreement cases | One extra hop when a routine UI PR turns out to carry a design-system-level concern |

## Decision

Chosen: **Option B — UI Designer owns the routine per-PR design gate; Head of Design is the escalation path**, because it matches the practitioner-reviews / head-escalates pattern already used for code review (Rex → Head of Engineering) and design-artifact review (Tariq → Head of Engineering), keeps routine UI review off the most senior designer's desk, and aligns with the wording `workflows/code-review.md` and `workflows/sdlc.md` already carried.

Concretely:

- **UI Designer (Nour)** — reviews the implementation diff on any UI-touching PR and records approval via `/approve-design` (the `require-design-review-for-ui.sh` merge gate). This is the routine, per-PR design gate.
- **Head of Design (Maha)** — the escalation path, not the default reviewer: design-system changes, cross-product visual standards, disagreements on a design call, or when no UI Designer is available.

## Consequences

- One authority statement now holds across `.claude/rules/role-triggers.md` (activation table, handoff table, and the "Two authority splits" note), `workflows/code-review.md` (Roles table + Approval Requirements), and — via #980 — the design role files.
- A `UI Designer → Head of Design` escalation leg is added to the role-triggers handoff table, and the Head of Design activation row now names "escalation from a UI Designer (design gate)".
- The generic "On inbound escalation" convention (added to role-triggers.md § Activation Protocol) covers the receiving side: the Head of Design acknowledges the escalation in its activation marker, decides within scope or escalates further, and hands the call back.
- No mechanical change to `require-design-review-for-ui.sh` — the gate already records a per-PR design approval regardless of which designer supplies it; this AgDR fixes the *documented authority*, not the hook.

## Artifacts

- [#984](https://github.com/me2resh/apexyard/issues/984) — the audit ticket
- PR: `chore(#984): cross-cutting agent-spec audit fixes`
- Edited: `.claude/rules/role-triggers.md`, `workflows/code-review.md`
