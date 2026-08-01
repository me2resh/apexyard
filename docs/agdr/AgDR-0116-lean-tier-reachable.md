---
id: AgDR-0116
timestamp: 2026-08-01T12:00:00Z
agent: claude (Platform Engineer — Adel)
model: claude-sonnet-5
trigger: user-prompt
status: executed
---

# The Lean tier's ceremony is "reduced-scope Rex", not "no Rex" — the merge gate is a control and stays unconditional

> In the context of me2resh/apexyard#1064 (the Lean tier's own rule prescribed "no review sub-agent" for a class of change the merge gate mechanically requires a Rex marker for, making the tier's defining instruction unfollowable in practice), facing a maintainer-scoped choice between four directions surfaced by a Solution-Architect design and stress-tested by a Contrarian challenge, I decided to **accept and document that the merge gate's Rex-marker requirement is unconditional by design (Direction 3), and layer a reduced-scope Rex pass on top for diffs that clear a strict, rail-1-gated eligibility bar (Option 4)** — to achieve a Lean tier the framework can actually deliver work through, without adding any new forgeable gate-relaxing surface, accepting that the shipping-speed benefit is now bounded by "cheaper Rex, not absent Rex" and that for a pure-docs PR the Lean/Standard distinction is mostly about suppressing the role chain, not the merge gate itself.

## Context

- me2resh/apexyard#1064: `right-size-ceremony.md`'s Lean tier prescribed *"inline check + one approval, no review sub-agent"*, but `block-unreviewed-merge.sh` refuses every merge — Lean, Standard, or Heavy — without a `*-rex.approved` marker at HEAD. A documented tier the framework's own delivery path could not satisfy.
- Observed cost on one static-HTML, docs-only session: 4 PRs, 6 Rex sub-agent runs, ~850k review-agent tokens, ~41 minutes of review wall-clock, entirely on copy/presentation changes with no runtime behavior. SHA-bound markers compounded this — two of the four PRs paid for a full second review to land a one-word wording fix.
- `block-unreviewed-merge.sh` is a CONTROL in the AgDR-0104 sense: it reads structured state (a marker's recorded SHA vs. the PR's HEAD **as the forge reports it**) rather than pattern-matching command text. That is exactly the property that makes it trustworthy, and exactly the property that makes it structurally incapable of inspecting the diff's own content to decide a tier — tier classification needs to read the diff; the gate deliberately does not.
- The issue itself named the trap: any direction that lets the gate skip the marker on a self-declared "Lean" attestation mints a **new forgeable surface** — the same shape of hole #843, #1011, and #1026 spent multiple rounds closing. Rail 1 (security / trust-chain / migration never Lean) has to hold **mechanically**, not just in prose, for any tier-aware gate change to be acceptable — and a marker whose trustworthiness depends on the model's own tier self-report cannot deliver that.
- A Solution-Architect design pass and a Contrarian challenge (`/challenge`) were run on the four directions before this decision; the Contrarian's central point survives into this record as the "Honesty note" below.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **1 — Tier-aware attestation marker.** A new marker kind recording "checked inline by the orchestrator, Lean tier, path class X" that the gate accepts in place of a Rex marker. | Makes the rule's own prescription literally executable; cheapest ceremony reduction | **Rejected.** A self-issued attestation is exactly the gate-relaxing forgeable surface #843/#1011/#1026 spent multiple rounds closing. The party best positioned to mis-tier a change under token/time pressure is the same party issuing the attestation that exempts it. |
| **2 — Path-class exemption.** Config-listed path globs whose PRs never require a Rex marker. | Cheap, inspectable, no new marker kind | **Rejected.** Still a gate-relaxing surface — a config edit (or a diff that merely touches a listed path alongside something else) becomes a merge-gate bypass. Rail 1 would have to be re-implemented as a second, independent path-exclusion check inside the merge gate itself, duplicating logic the gate doesn't currently need to have. Both 1 and 2 are deferred as explicit **Heavy** trust-chain projects, pursued only if re-review churn proves intolerable, and only under the AgDR-0104/0111/0112 constraints: forge-derived tier (never self-reported), fail-closed to full ceremony on any doubt, rail 1 enforced *inside* the gate itself (not just in prose), the CEO nod preserved, and a paired adversarial bypass test before merge, not after. |
| **3 — Accept & document. (CHOSEN)** Decide the marker requirement is unconditional by design; amend `right-size-ceremony.md` so the Lean tier stops promising something the gates will not permit. | Cheapest, safest, adds zero new gate-relaxing surface, honest about what the rule actually controls | Loses the shipping-speed benefit the rule was written to deliver, on its own — see Option 4 |
| **4 — Reduced-scope Rex on Lean diffs. (CHOSEN, layered on 3)** Rex runs a focused pass (correctness read + the mandatory checks) instead of the full deep review, when a diff clears a strict eligibility bar. | Recovers most of the token/latency cost Option 3 alone leaves on the table, without touching the gate at all — the reduction lives entirely inside Rex's own review depth, a decision Rex already makes every run | The eligibility bar is itself agent judgment (Rex's own classification), same enforcement shape as the rest of `right-size-ceremony.md` — bounded by rail 1 stated explicitly in Rex's own instructions, and by rail 2 (ambiguity falls back to the full review) |

## Decision

Chosen: **Direction 3 (accept & document) + Option 4 (reduced-scope Rex), layered.**

The merge gate (`block-unreviewed-merge.sh`) requires a Rex marker **regardless of tier — unconditionally, by design, unchanged by this decision.** It is a control, and a control that reads structured state (marker SHA vs. forge-reported HEAD) cannot also be the thing deciding whether a diff qualifies for lighter treatment; letting it try would mean trusting either a self-issued attestation (Option 1) or a config-path allowlist (Option 2) to gate a merge — both rejected above as new forgeable surfaces.

What *does* change: `right-size-ceremony.md`'s Lean-tier ceremony is redefined from "no review sub-agent" (unfollowable, per #1064) to "no role chain — no design / security / architecture review sub-agents — one lightweight Rex pass + the human merge nod." Rex's own instructions (`.claude/agents/code-reviewer.md`) gain a reduced-scope mode: on a diff that clears a strict, rail-1-gated eligibility bar (docs/config-text only, small, trivially reversible, no behavior change, AND — non-negotiably — no security / trust-chain / migration path touched, with ambiguity always falling back to the full review), Rex runs a focused correctness read instead of the full architecture/quality/testing/performance pass. The **required outputs never shrink**: the human-visible review is still posted, the `*-rex.approved` marker is still written in the exact same format, on the exact same conditions, at the exact same gate. Only the *depth* of the review varies.

`auto-code-review.sh`'s banner is updated to say this precisely: Rex runs on every PR, full stop, unconditionally — that instruction stays crisp and is not softened. What is now tier-conditional is the **role chain** layered around Rex (Security Auditor / Solution Architect / UI Designer), which already only activates on its own triggers.

### Honesty note (from the Contrarian challenge)

For a **pure `.md` diff**, Lean and Standard were already mechanically identical before this decision, and remain so after it: only Rex auto-fires on a docs PR (`auto-code-review.sh` fires on every `gh pr create`, full stop); Tariq, the Security Auditor, and the UI design gate do not auto-fire on `.md` paths at all (see `role-triggers.md`'s diff/path trigger table — none of their trigger globs match plain markdown). So the tier delta this decision actually buys is narrower than "Lean means less ceremony" suggests in the abstract: it mainly (a) suppresses the role chain on **non-.md Lean paths** that would otherwise trigger a role (a small `.yml` config tweak, a UI copy string, a config-text file under a path a role trigger's glob happens to match), and (b) reduces Rex's own review depth via Option 4, which applies uniformly regardless of file extension. Recording this precisely, rather than letting "Lean tier" read as a bigger win than it is, is the corrective this AgDR owes the record — `right-size-ceremony.md`'s own value for a pure-docs change was always going to be the Standard/Heavy distinction and the disproportion nudge, not a Lean-specific gate exemption, exactly as the issue's own Risk section anticipated.

## Consequences

- `block-unreviewed-merge.sh` is **not touched** by this decision and stays exactly as strict as before — no new marker kind, no path-exemption logic, no tier-conditional branch of any kind added to the gate. Rail 1 and rail 2 in `right-size-ceremony.md` are unchanged verbatim.
- `right-size-ceremony.md` no longer prescribes something the gate forbids — the Lean row and the "When to apply" guidance now describe a reduced-scope Rex pass, not an absent one.
- `.claude/agents/code-reviewer.md` gains an explicit, rail-1-gated eligibility bar for reduced-scope review, with **any** security / trust-chain / migration path match disqualifying the whole diff, and ambiguity always falling back to the full review (rail 2). The required review outputs (posted review, marker format, AgDR/glossary/handbook checks) are unchanged at every tier.
- `auto-code-review.sh`'s banner keeps the unconditional "Rex runs on every PR" instruction crisp (preserving the #843 fix's dual-reader clarity) and adds, without diluting it, that the role chain around Rex is what varies by tier.
- The per-run cost reduction is real but bounded: a Lean diff still spawns a Rex sub-agent, still produces a review, still writes a marker — the savings are in review depth (tokens, wall-clock), not in whether a review happens at all. Options 1 and 2 remain the deferred path to a bigger reduction, gated on the constraints stated above and a genuine third incident of re-review churn proving this insufficient.
- Tests (`.claude/hooks/tests/test_lean_tier_reachable.sh`) pin rail 1 at three independent points — the merge gate's Rex-check block (no lean/tier bypass), Rex's own eligibility bar (security / trust-chain / migration paths always disqualify), and the rule text itself — each with a discriminating (proven-would-catch-a-regression) assertion, not just a presence check.

## Artifacts

- me2resh/apexyard#1064 (the gap this decision closes)
- `.claude/rules/right-size-ceremony.md` (Lean row + "When to apply" + self-check; rails 1 & 2 unchanged)
- `.claude/hooks/auto-code-review.sh` (tier-aware banner note; Rex-unconditional instruction unchanged)
- `.claude/agents/code-reviewer.md` (Reduced-Scope Review section, Output Format `Scope` line, Rule 11)
- `.claude/hooks/tests/test_lean_tier_reachable.sh`
- AgDR-0104 (control vs. backstop framing — why the gate can't also be the tier classifier)
- AgDR-0107 (the original Lean-tier rule this decision corrects)
- AgDR-0111 / AgDR-0112 (prior rounds establishing that gate trust must rest on forge-reported state, never a local self-report)
