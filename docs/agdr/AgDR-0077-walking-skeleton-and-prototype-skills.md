# Walking-Skeleton + Prototype skills — completing the early-work taxonomy

> In the context of ApexYard's early-SDLC scaffolding (which shipped only `/spike` for pre-build exploration), facing two recurring gaps — no first-class home for throwaway **UX/demo** exploration and no scaffold for a **kept** thin end-to-end slice — I decided to add `/prototype` (+ `/prototype-close`) and `/walking-skeleton` as two new skills sitting on the same two axes as `/spike` (throwaway-vs-kept × technical-vs-UX), accepting a +3 skill count (59 → 62) and the maintenance cost of keeping the prototype exemption logic in lockstep with the spike exemption logic.

## Context

ApexYard already shipped `/spike` for hypothesis-driven, time-boxed, throw-away **technical** exploration ("will it work?"), with `/spike-close` as its disposition gate and surgical AgDR + coverage exemptions (see AgDR-0017). Two adjacent kinds of early work had no first-class scaffold:

1. **Throwaway UX/demo exploration** — a clickable mockup or demo flow that answers *"what should this look and feel like?"*. Teams were filing these as features (wrong bar — they get held to production gates they should be exempt from) or as spikes (wrong vocabulary — a spike answers a technical question, not a UX-direction one).
2. **A kept thin end-to-end slice** — the thinnest happy path wired through every architectural layer (UI → API → domain → store → deploy → back), proving integration and architecture early, then grown into the product. This is the deliberate *opposite* of a spike: minimal but **production-shaped and kept**, so it must be held to the FULL SDLC. There was no scaffold guiding in-scope (the wiring) vs out-of-scope (features built later on top).

The early-work space is naturally a 2×2 (throwaway-vs-kept × technical-vs-UX). `/spike` filled one cell; two cells were empty.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Add `/prototype` (+`/prototype-close`) and `/walking-skeleton` as new skills, mirroring the spike pattern** | Completes the 2×2 taxonomy; prototype reuses the proven spike exemption shape; walking-skeleton gets explicit "kept, full SDLC, NOT exempt" framing to prevent accidental promotion of throwaway work | +3 skills to maintain; the prototype exemption logic must track the spike exemption logic in two hooks |
| Overload `/spike` with a `--ux` / `--skeleton` flag | No new skill files | Conflates three different lifecycles + disposition rules behind one command; flags hide the kept-vs-throwaway distinction that is the whole point; `/walking-skeleton` is NOT exempt, so it can't share the spike's exemption gates |
| Document the taxonomy in prose only (no scaffolds) | Zero code | No structured ticket bodies, no gate wiring, no disposition gate — the same author-avoidance failure mode `/spike` was created to fix |

## Decision

Chosen: **add `/prototype` + `/prototype-close` + `/walking-skeleton`**, because completing the taxonomy with real scaffolds (structured ticket templates, gate wiring, a disposition gate for the throwaway one) is what makes the distinction enforceable rather than aspirational.

- **`/prototype`** scaffolds a throwaway `[Prototype]` UX/demo ticket (DISCARD-by-default), with **`/prototype-close`** as the disposition gate mirroring `/spike-close`. It shares the spike AgDR + coverage exemptions; code review (Rex) and security still apply.
- **`/walking-skeleton`** scaffolds a `[Feature]`-class ticket for the thinnest kept end-to-end slice. It is held to the FULL SDLC (tests, >80% coverage on the slice's domain logic, Rex, all gates) and is explicitly **NOT** exempt — preventing the expensive confusion where throwaway exploration is accidentally promoted into production.

The two AgDR exemption hooks (`require-agdr-for-arch-pr.sh`, `require-agdr-for-arch-changes.sh`) now recognise the prototype exemption the same three ways as spike: `prototype(...)` PR type, `[Prototype]` ticket prefix, `prototype/` branch. The walking skeleton deliberately gets no exemption.

## Consequences

- Skill count rises **59 → 62** (`/prototype`, `/prototype-close`, `/walking-skeleton`); CLAUDE.md, README.md, and `loop-mode.md`'s "62 slash commands" prose updated to match.
- `project-config.defaults.json` gains `Prototype` in the ticket-prefix whitelist (+ `required_sections`) and `prototype` in the branch / commit / PR-title type whitelists; `git-conventions.md` documents the new type.
- `workflows/sdlc.md` Phase 1 gains a taxonomy sidebar; `workflow-gates.md` spike-exemption section notes prototype shares the exemption and walking-skeleton does not.
- Ongoing maintenance coupling: any future change to the spike exemption detection must be mirrored for prototype in both AgDR hooks (covered by the new test cases in `test_require_agdr_for_arch_pr.sh`).

## Artifacts

- Re-landed on me2resh/apexyard (canonical) from the retired atlas fork PR #2 (`feat(#672): add /walking-skeleton + /prototype skills`).
- Closes #672, #673.
- Skills: `.claude/skills/{walking-skeleton,prototype,prototype-close}/SKILL.md`; template: `templates/tickets/prototype.md`.
