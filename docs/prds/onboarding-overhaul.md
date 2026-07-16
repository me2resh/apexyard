<!-- Source: ApexYard · docs/prds/onboarding-overhaul.md · github.com/me2resh/apexyard · MIT -->

# PRD: Guided First-Run Onboarding + Teach-in-Context

**Status**: Draft
**Author**: Mariam (Product Manager)
**Created**: 2026-07-15
**Last Updated**: 2026-07-15 (CEO refinement: standalone re-entry point added)
**Ticket**: [me2resh/apexyard#902](https://github.com/me2resh/apexyard/issues/902)

---

## Overview

### Problem Statement

ApexYard's only first-run entry point today is `/setup` — a 3-exchange bootstrap that fills in `onboarding.yaml` (company, stack, tracker) and, optionally, seeds LSP and a first registered project. It does exactly one job well: get the *configuration file* correct. It does not tell a brand-new adopter what the framework can actually do, it does not ask the single most consequential first-run question — "are you adopting a codebase you already have, or starting something new?" — and it does not walk anyone to a first success. `/handover` (adopt an existing repo) and the various ticket-creation skills (`/feature`, `/bug`, `/task`, …) all exist and all work, but a first-time adopter has no way to discover them except by reading `CLAUDE.md` end to end or asking.

Two independent adopter signals surfaced this gap from opposite ends of the technical spectrum:

1. **A technical adopter** found `/setup` too thin. They wanted: a step-by-step that surfaces what the framework can do (roles, skills, gates — not just the config file), an explicit first branch between *"hand over an existing repo"* and *"start a new project"* (today the adopter has to already know `/handover` exists and type it themselves), and a guided first win — a concrete "try requesting a feature" nudge that ends in a visible "🎉 you made your first feature" moment, rather than a silent return to the prompt.
2. **A non-technical adopter** got stuck on vocabulary, not process. They did not know what an *issue*, a *ticket*, a *PR*, or a *merge* were — the words the whole SDLC is built from (`workflows/sdlc.md`, every skill's output, every hook message) assume the reader already has this vocabulary. Nothing in the framework explains these terms at the moment the adopter first encounters them; the assumption baked into every doc and skill is a working engineer.

The two signals point at two different, non-overlapping gaps:

- The technical adopter is missing a **flow** (what do I do first, and what happens after).
- The non-technical adopter is missing **vocabulary** (what does this word even mean).

A single onboarding surface has to solve both without making the technical adopter sit through a glossary they don't need, and without dropping the non-technical adopter into workflow language they can't parse yet.

### Target User

**Primary**: A brand-new ApexYard adopter with software engineering background — comfortable with git, GitHub, and the SDLC vocabulary, but unfamiliar with *this framework's* specific roles, skills, and gates. Wants a fast, information-dense first-run flow that surfaces capability, not hand-holding.

**Secondary**: A brand-new ApexYard adopter with **no** software engineering background — e.g. a non-technical founder or product owner running Claude Code directly. Comfortable directing an agent in plain language, but has never used the words "issue," "ticket," "pull request," "merge," "branch," or "CI" in a working sense before. Needs the *same* underlying SDLC (a ticket exists, a PR gets reviewed, CI has to pass) explained in plain language, at the moment they hit each concept — not up front as a wall of definitions they'll forget before they're needed.

### Goals

1. A first-run session gives every adopter — regardless of technical background — a clear answer to "what happens first" within the first exchange: a capability tour, then an explicit branch between handing over an existing repo and starting fresh.
2. Every adopter reaches one guided, successful first action (e.g. filing a first feature ticket) inside their first session, with a visible confirmation moment when it lands.
3. A non-technical adopter can look up any of the six core SDLC terms (issue, ticket, PR, merge, branch, CI) in plain language *at the point they first encounter it in framework output* — without leaving the conversation or reading a separate doc end-to-end.
4. Onboarding depth visibly adapts to the adopter's declared/inferred technical level — terse and capability-dense for an engineer, narrated and vocabulary-taught for a non-technical user — without forking into two entirely separate skills to maintain.
5. The overhaul ships incrementally: a thin, end-to-end first slice lands before the full vision, so the gap starts closing in weeks, not quarters.
6. The teach-in-context layer is not a one-time, first-run-only event. Every adopter can deliberately re-open the capability tour and the plain-language glossary at any later point — via a standalone entry point, independent of re-running `/setup` — so a lesson missed (or forgotten) on day one isn't gone for good.

### Non-Goals (Out of Scope)

- Replacing or removing `/setup` (config bootstrap) or `/handover` (repo adoption) — this PRD extends the first-run *experience wrapping* those skills, it does not re-architect what they configure.
- A GUI, web dashboard, or any interface outside the Claude Code conversational surface. This is a conversational (skill + rule + hook) design, matching every other ApexYard surface.
- Any change to who is allowed to do what (permissions, approval gates, CEO merge gate). The teach-in-context layer explains the existing gates in plain language; it does not loosen or change them.
- Translating the framework into non-English languages. Plain-language English is in scope; localization is a separate initiative.
- An in-depth interactive tutorial / course product. The guided first-win is one concrete action with one visible success moment, not a multi-lesson curriculum — and the standalone re-entry point (US-6) re-opens that same tour/glossary content on demand, it does not grow into a separate lesson sequence.
- Long-term retention/engagement mechanics (streaks, badges, progress bars). Scope here is *first-run clarity*, not gamification.

### Success Metrics

| Metric | Target | How Measured |
|--------|--------|--------------|
| First-session completion of the guided first win | ≥ 80% of fresh forks that run the new first-run flow reach a completed first ticket/PR action in the same session | Session-log inspection / adopter self-report during rollout |
| Non-technical adopter vocabulary lookups resolved in-context (no context switch to an external doc) | 100% of the six core terms answerable in-thread on first encounter | Manual walkthrough test with a non-technical persona script |
| Time-to-first-action (fresh fork → first ticket filed) | Reduced vs. current baseline (today: unmeasured / ad hoc) | Compare adopter session transcripts before/after |
| Adopter-reported clarity ("did you understand what happened after each step?") | Qualitative "yes" from both a technical and a non-technical test adopter | Structured feedback interview per persona, pre-GA |

---

## User Stories

### US-1: Capability tour on first session

> As a brand-new adopter (either technical background), I want a short tour of what ApexYard can actually do — roles, skills, gates — so that I know what's available before I have to guess or read `CLAUDE.md` cold.

**Acceptance Criteria**:

- [ ] On a genuinely fresh fork (no `onboarding.yaml`, no registered projects — the same detection `/setup` already uses), the first-run flow opens with a short, scannable capability tour: what a role is, what a skill is, what a gate is, framed in one or two sentences each with a concrete example (not the full 64-skill table).
- [ ] The tour is skippable in one word ("skip") for an adopter who already knows the framework (e.g. re-running on a second fork).
- [ ] The tour does not require reading `docs/multi-project.md` or `CLAUDE.md` in full — it is self-contained.

---

### US-2: The handover-vs-new-project branch

> As a brand-new adopter, I want to be asked up front whether I'm adopting an existing repo or starting something new, so that I'm routed to the right skill (`/handover` vs a fresh project flow) instead of having to already know both exist.

**Acceptance Criteria**:

- [ ] Immediately after the capability tour (or immediately, if skipped), the flow asks one explicit branching question: "Are you handing over a repo you already have, or starting something new?"
- [ ] Answering "handing over" routes into `/handover` with the adopter's repo path/URL, inheriting all of `/handover`'s existing behavior (clone, harnessability assessment, registry entry) unchanged.
- [ ] Answering "starting new" routes to a lightweight "new project" path — registers a project entry, points at `/write-spec` or `/idea` as the natural next step, and does not require the adopter to already have a codebase.
- [ ] The branch question and its two destinations are additive: neither `/handover` nor any new-project skill has its existing behavior changed by this PRD, only reached via a clearer front door.

---

### US-3: Guided first win

> As a brand-new adopter, I want to be walked through one small, successful action — like filing my first feature ticket — so that I see something real happen and know the loop works before committing more time.

**Acceptance Criteria**:

- [ ] After the branch in US-2 resolves (handover assessment written, or new project registered), the flow offers a single, concrete next action sized to finish in one exchange — the framework's existing recommendation is "try requesting a feature" via `/feature`.
- [ ] If the adopter accepts, the flow runs the suggested skill with the adopter, using whatever skeleton/example content fits their stated project.
- [ ] On successful completion (ticket filed, real issue number returned), the flow prints a visible, unambiguous success moment (e.g. "🎉 First feature ticket filed — #<N>. That's the whole loop: idea → ticket → (later) PR → review → merge.").
- [ ] If the adopter declines the guided first win, the flow says what they can run later (the same skill name) and exits the first-run flow without forcing the action.
- [ ] The guided first win never itself creates a placeholder/fake ticket — it uses the real ticket-creation skill (`/feature`), so the "win" is a real tracker artifact, not a simulation. (This keeps the guided flow consistent with the ticket-vocabulary rule — no fabricated `#N` references.)

---

### US-4: Teach-in-context education layer

> As a non-technical adopter, I want core software terms — issue, ticket, PR, merge, branch, CI — explained in plain language exactly when I first hit them, so that I can follow what's happening without stopping to go look things up.

**Acceptance Criteria**:

- [ ] A plain-language glossary exists for at least: issue/ticket, PR (pull request), merge, branch, CI (continuous integration checks). Each entry is 1-3 sentences, no jargon-on-jargon (a definition of "PR" must not itself require knowing what "a repo" or "a diff" means without also explaining those inline).
- [ ] The glossary is surfaced **just-in-time**: the first time framework output would use one of these terms toward a non-technical adopter (e.g. the first time a ticket is created, the first time a PR is opened on their behalf, the first time a merge gate blocks them), a short plain-language aside accompanies it — not a wall of definitions up front.
- [ ] The just-in-time aside is a single short parenthetical or a one-line explanatory sentence, not a mode switch that derails the actual task — e.g. "I've opened a ticket for this (a ticket is just a tracked to-do item you and I can both refer back to by number)."
- [ ] A technical adopter (US-1/US-2 path) does not see these asides by default — see US-5 for the adaptivity mechanism.
- [ ] The same six terms are also available on demand — an adopter can ask "what's a merge?" at any point in any session, technical-level notwithstanding, and get the plain-language answer.

---

### US-5: Onboarding depth adapts to technical level

> As an adopter, I want the onboarding experience to match how much I already know, so that I'm not bored with explanations I don't need, or lost in vocabulary I haven't learned yet.

**Acceptance Criteria**:

- [ ] The first-run flow infers or asks (briefly, non-invasively) the adopter's technical comfort level — e.g. inferred from how they describe their stack in `/setup`'s existing "tell me about your company and tech stack" question (a fluent stack description implies engineer-level comfort), or asked directly with a low-friction question ("Have you used git/GitHub before?") when the inference is ambiguous.
- [ ] Two depth modes exist on the *same* underlying flow (US-1 through US-4), not two forked skills: a **terse mode** (capability tour condensed to a few lines, no teach-in-context asides, assumes SDLC vocabulary) and a **guided mode** (fuller tour, teach-in-context asides active by default, more explicit "here's what just happened and why" narration after each step).
- [ ] The adopter can override the inferred mode at any time in plain language ("explain things more" / "skip the explanations") and the change takes effect immediately, not just on the next session.
- [ ] Depth adaptation is purely a UX/communication-style setting — it does not change what gates apply, what a role can or cannot do, or any permission. A non-technical adopter in guided mode still goes through the same PR/CEO-approval/QA gates as anyone else; the only difference is how those gates are explained to them.

---

### US-6: Re-open the tutorial anytime (standalone entry point)

> As any adopter — technical or non-technical — I want to re-open the guided capability tour and teach-in-context glossary at any point after my first session, so that I can review the vocabulary or the framework's capabilities again without re-running `/setup` or pretending my fork is fresh.

This is a **first-class requirement**, not a sub-step buried inside `/setup`. The teach-in-context layer must be invokable in two independent ways: (1) automatically, as part of the guided first-run path (US-1 through US-4), and (2) standalone, on demand, at any later point in the fork's life.

**Acceptance Criteria**:

- [ ] A standalone entry point exists (e.g. a `/tutorial` or `/learn` skill) that is entirely independent of `/setup` — invoking it does not read or write `onboarding.yaml`, does not re-trigger fresh-fork detection, and does not require answering the handover-vs-new-project branch again.
- [ ] The standalone entry point re-opens the same capability tour and teach-in-context glossary content the first-run flow uses, rendered in the adopter's current depth mode (inferring or asking for a mode if none is set for this session, per US-5).
- [ ] The standalone entry point is discoverable without already knowing its name: the first-run flow's closing message mentions it explicitly (e.g. "come back anytime with `/tutorial`"), and it is listed in the framework's skill index alongside every other skill.
- [ ] Running the standalone entry point is read/teach-only — it never re-runs `/setup`'s or `/handover`'s side effects (no `onboarding.yaml` rewrite, no duplicate registry entry, no repeated guided-first-win ticket creation unless the adopter explicitly asks to redo that part).
- [ ] The standalone entry point works identically whether the adopter went through the guided first-run flow originally, skipped it, or is on a fork configured before this PRD's flow existed — it does not depend on first-run session state to function.

---

### Edge Cases

| Scenario | Expected Behavior |
|----------|-------------------|
| Adopter re-runs the first-run flow on an already-configured fork | Detect via the same "already configured" check `/setup` uses (`onboarding.yaml` present with real values) — skip the capability tour and branch question by default, offer to re-run only if explicitly asked (mirrors `/setup`'s existing re-run behavior). |
| Non-technical adopter asks a vocabulary question mid-`/handover` or mid-`/setup` (skills this PRD doesn't rewrite) | The on-demand glossary lookup (US-4, last bullet) works globally, not just inside the new first-run flow — any session, any skill in progress. |
| Adopter answers the handover-vs-new question ambiguously ("both", "not sure") | Ask one clarifying follow-up ("Do you have an existing codebase you want ApexYard to manage?") before defaulting; if still ambiguous, default to the new-project path (lower-commitment, reversible) and mention `/handover` is available later. |
| Guided first win (US-3) fails partway (e.g. `/feature` hits a hook block for an unrelated reason) | Surface the real error plainly, do not fabricate a fake success message, offer to retry or skip — same honesty standard as the rest of the framework (see ticket-vocabulary rule: never claim a ticket exists that doesn't). |
| Adopter explicitly states a technical level up front ("I'm a non-technical founder", "I'm a senior engineer") | Skip the inference/ask step in US-5 entirely and honor the stated level immediately. |
| Terse-mode adopter later brings on a non-technical teammate to the same fork | Depth mode is a per-session/per-conversation setting, not a permanent fork-wide config flip — the teammate's own session can independently run in guided mode. |
| Adopter invokes the standalone entry point (US-6) on a fork that never ran the new first-run flow at all (e.g. configured before this PRD shipped, or via `--all`-style scripted `/setup`) | The standalone entry point must still work — it does not depend on any state the first-run flow would have written. Treat it as a cold invocation: infer/ask depth mode fresh, show the tour and glossary from scratch. |
| Adopter invokes the standalone entry point mid-way through an unrelated active ticket/session | Treat it as a self-contained side conversation — it doesn't touch the active-ticket marker or any in-progress build state; the adopter picks back up where they left off once done. |

---

## Requirements

### Functional Requirements

| ID | Requirement | Priority | Notes |
|----|-------------|----------|-------|
| FR-1 | A new first-run flow (skill or extension of `/setup`'s Step 1 detection) presents a capability tour before any config questions, on a genuinely fresh fork | Must | Ties into `/setup`'s existing fresh-fork detection (`.claude/skills/setup/SKILL.md` Step 1) |
| FR-2 | The flow asks the explicit handover-vs-new-project branch question and routes accordingly | Must | Reuses `/handover` unchanged; "new project" path is new but lightweight |
| FR-3 | The flow offers and can execute a guided first-win action ending in a visible success message | Must | Uses the real `/feature` skill — no simulated/fake ticket creation |
| FR-4 | A plain-language glossary for issue/ticket, PR, merge, branch, CI exists and is reusable across skills, not locked inside the new flow | Must | On-demand lookup must work outside the new flow too (see Edge Cases) |
| FR-5 | Teach-in-context asides trigger just-in-time on first encounter of each of the five terms, only in guided mode | Must | Terse-mode adopters see zero asides by default |
| FR-6 | A technical-level signal (inferred from stack description, or asked directly) sets terse vs. guided mode for the session | Must | Adopter can override in plain language at any time |
| FR-7 | The thin first slice (see Design → walking-skeleton scope below) ships as a single, mergeable, end-to-end unit before the full vision's remaining pieces | Must | Matches the framework's own walking-skeleton discipline — kept, not throwaway |
| FR-8 | The on-demand glossary lookup ("what's a merge?") works in any session regardless of which skill is active | Should | Distinct from FR-10: this is a single-term lookup mid-conversation, not the full standalone re-entry point |
| FR-9 | Depth-mode preference is visible to the adopter on request ("what mode am I in?") | Could | Small transparency affordance, not core to the loop |
| FR-10 | A standalone entry point (e.g. `/tutorial` or `/learn`) re-opens the full capability tour + teach-in-context glossary independent of `/setup`, at any point after the first session | Must | First-class requirement, not a `/setup` sub-step (see US-6) — CEO-directed refinement on this PRD |

**Priority Key**: Must (required for launch) | Should (important) | Could (nice to have)

### Non-Functional Requirements

| Category | Requirement | Target |
|----------|-------------|--------|
| Consistency | Guided-mode explanations must not contradict the precise mechanical behavior described elsewhere in the framework's rules (e.g. what a merge gate actually checks) | Plain-language aside is a simplification, never a misstatement, of the mechanism in `.claude/rules/pr-workflow.md` et al. |
| Accessibility of language | Glossary entries readable by someone with no CS background | No jargon-on-jargon (see US-4 AC) |
| Reversibility | Depth-mode switch and first-win skip must be instantaneous and lossless | No config file needs editing to change mode mid-session |
| Backward compatibility | `/setup` and `/handover` behavior is unchanged for adopters who don't engage the new first-run flow (e.g. scripted / `--all`-style invocations) | Existing automation continues to work byte-for-byte |

---

## Design

### User Flow

```
[Fresh fork detected — same check /setup Step 1 already uses]
    |
    v
[Capability tour — what's a role / skill / gate, 1-2 lines each]
    |  (adopter can say "skip")
    v
[Technical-level signal: infer from stack description, or ask directly]
    |
    +---> engineer-comfort inferred/stated -----> [terse mode]
    |
    +---> unfamiliar / non-technical stated ----> [guided mode: teach-in-context ON]
    |
    v
[Branch: "handing over an existing repo, or starting new?"]
    |
    +---> "handing over" --------> [/handover runs unchanged]
    |
    +---> "starting new" --------> [lightweight new-project registration]
    |
    v
[Guided first win offered: "try requesting a feature"]
    |
    +---> accept --> [/feature runs] --> [🎉 first feature filed — #N]
    |
    +---> decline --> [note: "run /feature anytime" — exit flow]
    |
    v
[Closing message mentions: "come back anytime with /tutorial"]
```

Teach-in-context asides (US-4) attach to this flow wherever a core term first appears — e.g. the first time "ticket" appears in the capability tour (guided mode only), the first time a PR would be opened, the first time a merge gate is mentioned.

**Standalone re-entry (US-6) — independent of the flow above:**

```
[Adopter runs /tutorial (or /learn) — any time, any session]
    |
    v
[Depth mode: use current session's mode, or infer/ask fresh]
    |
    v
[Same capability tour + teach-in-context glossary content]
    |
    v
[Exit — no onboarding.yaml touched, no registry entry touched,
 no re-run of /setup or /handover side effects]
```

This second diagram is deliberately disconnected from the first — the standalone entry point does not require having gone through the first-run flow, does not depend on any state it would have set, and does not feed back into it.

### Wireframes / Mockups

Not applicable — conversational surface only, no visual UI. See User Flow above for the shape of the interaction; individual prompt copy is an implementation detail for the authoring skill, not this PRD.

---

## Technical Notes

### Dependencies

| Dependency | Type | Status | Owner |
|------------|------|--------|-------|
| `/setup` skill (fresh-fork detection, Step 1) | Internal | Ready — reused, not replaced | Platform / skill author |
| `/handover` skill (existing repo adoption) | Internal | Ready — reused unchanged | Platform / skill author |
| `/feature` skill (ticket creation) | Internal | Ready — used for the guided first win | Platform / skill author |
| `onboarding-check.sh` SessionStart hook (detects unconfigured fork) | Internal | Ready — likely extension point for triggering the new flow | Platform Engineer |
| Ticket-vocabulary rule (`.claude/rules/ticket-vocabulary.md`) | Internal | Ready — guided first win must not fabricate tracker state | N/A (governs implementation) |
| New standalone entry-point skill (e.g. `/tutorial` or `/learn`, FR-10 / US-6) | Internal | New — to be authored, name TBD in tech design | Product Manager + skill author |

### Technical Constraints

- The new first-run flow must not introduce a second, competing fresh-fork detection mechanism — it extends the one `/setup` already uses (`onboarding.yaml` absent or placeholder).
- No new tracker vocabulary may be used for anything other than real, created tickets (per `.claude/rules/ticket-vocabulary.md`) — the guided first win's "🎉" moment must reference a real filed ticket number, never a placeholder.
- Teach-in-context asides are additive text, not new gates or permission changes — implementation must not alter any existing hook's blocking behavior.
- Whatever skill/rule combination implements this (a new skill, or an extension to `/setup`) should be authored following the Tech Lead → Solution Architect design-review gate (3b) given the cross-cutting nature of touching first-run flow, `/handover` routing, and a new education-layer surface.

---

## Launch Plan

### Rollout Strategy

- [ ] Phased rollout — the thin first slice ships first as a walking-skeleton-class ticket (kept, not throwaway): capability tour + handover-vs-new branch + guided first win, terse mode only, no teach-in-context glossary content yet — but the standalone entry point skill (US-6) ships in this slice too, re-opening the capability tour on demand. This alone closes the technical adopter's signal, plus makes "not one-time-only" true from day one.
- [ ] The teach-in-context glossary (US-4) and depth adaptivity (US-5) ship as a second increment once the first slice is validated with a real adopter session — the same standalone entry point from increment 1 grows to serve the fuller glossary + guided-mode content, rather than a new entry point being introduced later.
- [ ] Both increments go through the normal SDLC (PRD → tech design → Solution Architect review → build → Rex review → QA) — no exemption; this is user-facing product surface, not a spike/prototype.

### Thin First Slice vs. Full Vision

| | Thin first slice (walking-skeleton) | Full vision |
|---|---|---|
| Capability tour | Yes — condensed, terse-mode only | Yes — same, plus a guided-mode fuller version |
| Handover-vs-new branch | Yes | Yes (unchanged) |
| Guided first win | Yes — `/feature` only | Yes — potentially other suggested first actions |
| Standalone re-entry point (US-6 / FR-10) | Yes — re-opens the capability tour only | Yes — re-opens capability tour + full teach-in-context glossary, respecting depth mode |
| Teach-in-context glossary | No | Yes — all five core terms, just-in-time |
| Technical-level adaptivity | No — single terse mode for everyone | Yes — full terse/guided split with override |
| On-demand glossary lookup (any session) | No | Yes (FR-8) |

The first slice alone directly answers the technical adopter's signal (US-1, US-2, US-3 in terse form) — and, per the CEO's refinement, ships the standalone re-entry point (US-6) from the start, so "re-open the tour" is never a first-run-only affordance even before the fuller education layer exists. It deliberately defers the non-technical adopter's vocabulary signal (US-4, US-5) to the second increment — shipping *something* end-to-end quickly, per the framework's own walking-skeleton discipline, rather than holding the whole PRD for the harder education-layer design.

---

## Open Questions

| Question | Owner | Status | Resolution |
|----------|-------|--------|------------|
| Should technical-level inference default to "ask directly" or "infer silently from stack description," when both signals are weak/absent? | Product Manager + Tech Lead | Open | To be resolved during tech design |
| Does the guided first win need a project already registered (post-branch), or can it run before the branch resolves, using placeholder project context? | Tech Lead | Open | To be resolved during tech design — likely: after, so the filed ticket lands somewhere real |
| Should the on-demand glossary (FR-8, "Should" priority) ship in increment 1 or 2? | Product Manager | Open | Currently scoped to increment 2 with US-4; revisit if increment 1 build cost leaves headroom |
| Where does the plain-language glossary content live — a new `docs/` reference file, inline in the skill, or a shared data file multiple skills read? | Tech Lead | Open | To be resolved during tech design; must support FR-8's "any session" reuse |
| What's the standalone entry point named — `/tutorial`, `/learn`, or an admin "Learn" action — and does it live as its own skill or as a mode of an existing one? | Product Manager + Tech Lead | Open | To be resolved during tech design (US-6 / FR-10); either name works functionally, this is a naming/discoverability call |

---

## Timeline

| Milestone | Target Date | Status |
|-----------|-------------|--------|
| PRD Approved | TBD | Draft |
| Tech Design (increment 1 — thin slice) | TBD | Not started |
| Solution Architect review (increment 1) | TBD | Not started |
| Increment 1 build + QA | TBD | Not started |
| Increment 1 launch | TBD | Not started |
| Tech Design (increment 2 — teach-in-context + adaptivity) | TBD | Not started |
| Increment 2 build + QA | TBD | Not started |
| Increment 2 launch | TBD | Not started |

---

## Approvals

| Role | Name | Date | Status |
|------|------|------|--------|
| Product Manager | Mariam | 2026-07-15 | Author |
| Head of Product | | | Pending |
| Tech Lead | | | Pending |
| Head of Design | | | Pending |
