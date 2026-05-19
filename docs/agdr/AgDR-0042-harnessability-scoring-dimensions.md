# AgDR-0042 — Harnessability scoring dimensions and thresholds

> In the context of `/handover` adopting an external codebase into ApexYard governance, facing the gap that Rex's architecture handbooks (especially `ENFORCEMENT: blocking` ones like `clean-architecture-layers.md`) assume the codebase already supplies the ambient affordances those rules rely on — type safety, module boundaries, lint baselines — and fire false positives when those affordances are missing, I decided to score harnessability across **5 dimensions** (type safety, module boundaries, framework opinionation, test coverage signal, lint baseline) producing a human-readable verdict (`high` / `moderate` / `low`) with **conservative v1 thresholds** (`high` requires 5/5 strong-or-present; `low` is ≤2/5 OR the (type-safety = none + framework = weak) override), and to print a specific blocking-handbook warning when the verdict is `low`, to achieve a discrete adoption-time signal that prevents the operator from being surprised by handbook noise on the first code review, accepting that the thresholds are coarse and stack-blind (Go and Rust assume implicit type-safety strength), that single dimensions can be cheated (a `.eslintrc.json` with one rule still passes lint baseline), and that the v1 scoring weights every dimension equally even though some carry more weight in practice (type safety > lint baseline for Rex's blocking handbooks).

## Context

ApexYard's value as a "harness" — the framework's rules, hooks, and Rex's handbook-driven code reviews — depends on the codebase having the **ambient affordances** the rules expect. The framing here draws on industry-standard harness-engineering prior art on ambient affordances: a tool's effectiveness depends on the working environment already supplying the signals the tool relies on, rather than the tool having to manufacture those signals from scratch.

Concretely:

- `handbooks/architecture/clean-architecture-layers.md` (an always-load, currently advisory handbook) assumes the codebase distinguishes `domain/` from `application/` from `infrastructure/`. On a flat single-`src/` codebase, every "domain logic in infrastructure" finding is structurally meaningless.
- Future blocking-mode handbooks on type safety assume `tsconfig.json` strict mode, or equivalent. Without that, every "`any` without justification" finding is noise.
- Future coverage gates assume the project has a coverage threshold to measure against; without one, the gate has nothing to enforce.

The failure mode this AgDR exists to prevent: an operator runs `/handover` on a legacy JS project (no TS, no clean-architecture dirs, no ESLint), accepts the framework as-is, opens their first PR — and Rex floods the review with handbook citations that aren't actionable because the prerequisites don't exist. The natural response is to disable Rex or mark all those handbooks advisory-only, which is a worse outcome than acknowledging the gap at adoption time.

The fix is to **name the gap at handover time** so the operator can choose:

1. Adopt as-is with handbooks set to advisory (legitimate path — many projects start here)
2. Schedule a "lift the floor" follow-up: add TS strict, ESLint baseline, coverage threshold, then re-evaluate
3. Skip those handbooks entirely if the project's contract is fundamentally different (e.g. a one-file Bash script doesn't need clean architecture)

The score makes the choice explicit. A `high` score → operator can run blocking handbooks immediately. A `low` score → operator gets the warning block and goes in eyes-open.

### Why 5 dimensions specifically

Each dimension corresponds to a class of handbook that Rex applies or will apply:

| Dimension | Maps to handbook class |
|-----------|------------------------|
| Type safety | "no `any`", "explicit return types", "exhaustive switch" — language-level signal-quality rules |
| Module boundaries | clean-architecture-layers, "domain has no infrastructure imports" — architectural rules |
| Framework opinionation | "use framework's DI", "use framework's repository pattern" — conventional-shape rules |
| Test coverage signal | "tests required for domain logic", coverage thresholds — quality-gate rules |
| Lint baseline | "no unused imports", "no console.log" — automated-quality rules |

A 5th dimension was considered (`existing CI maturity`) but dropped — CI is downstream of the other four (you can't enforce coverage in CI without a coverage signal; you can't enforce lint in CI without a lint baseline), so it would have double-counted.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. No score, no warning** — let the operator find out on the first code review | Zero implementation cost; preserves current shape | The exact failure mode this AgDR exists to prevent; operator discovers the noise on a real PR where the cost is highest |
| **B. Single binary score (`harnessable` / `not harnessable`)** | Easiest to interpret; one decision boundary | Loses signal granularity — a project missing only lint baseline is in a very different bucket from a project missing every dimension, but binary collapses them. Operator can't tell whether the gap is one easy follow-up or a multi-quarter scaffolding effort |
| **C. Weighted-sum 0-100 score** | Numerically precise; allows fine-grained thresholds | False precision — the inputs are coarse (each dimension is 2-3 buckets), so a 78/100 vs 81/100 difference is noise. Also requires defining and defending the weights, which adds maintenance burden + invites litigation over "why is type safety worth 25% and not 30%?" |
| **D. Human-readable verdict only, no per-dimension breakdown** | Cleanest UX | Loses the actionable signal — operator can't see WHICH dimensions failed without re-running the scan manually. Defeats the "plan a follow-up" recommendation |
| **E. 5-dimension verdict with per-dimension scores + overall verdict + warning on `low` (chosen)** | Per-dimension scores give actionable follow-up planning; overall verdict gives the quick read; the warning surfaces the load-bearing concern (blocking-handbook noise) only when it matters | More to implement than B or D; the truth table has to be defended explicitly (which thresholds, why); the dimensions themselves can be litigated |
| **F. Score plus auto-fix offer** ("we'll add tsconfig strict and ESLint for you") | Closes the gap mechanically | Out of scope for this AgDR per the ticket. A `--fix-harnessability` follow-up is a separate skill — `/handover` shouldn't be the auto-fixer. Deferred. |

## Decision

Chosen: **Option E — 5-dimension verdict (Type safety / Module boundaries / Framework opinionation / Test coverage signal / Lint baseline), human-readable verdict (`high` / `moderate` / `low`), conservative v1 thresholds, warning text on `low` only**.

The truth table for v1:

| Strong-or-present count | Other conditions | Verdict |
|-------------------------|------------------|---------|
| 5 / 5 | — | `high` |
| 3 or 4 / 5 | — | `moderate` |
| ≤ 2 / 5 | — | `low` |
| any | Type safety = `none` AND framework opinionation = `weak` | `low` (override) |

Three deliberate choices:

1. **`high` requires 5/5.** Conservative on purpose — a project missing even one dimension still gets `moderate` because Rex's handbooks span all five classes; a single gap is still a class of false-positive surface. This means most legacy adopters will land in `moderate` initially. That's fine — `moderate` doesn't trigger the warning, so the friction is minimal, but the operator can see the gap.
2. **The `none + weak` override forces `low` regardless.** These two dimensions together are the load-bearing pair for Rex's blocking handbooks. A project with no type safety AND no framework opinionation has neither the language-level signal quality nor the structural-shape conventions that the handbooks rely on. Even if the other three dimensions are technically present (e.g. an `.eslintrc.json` exists), the false-positive rate on architecture handbooks will be high enough to warrant the warning.
3. **Per-dimension rationales are mandatory.** Every dimension entry in the assessment file must cite the evidence (path + key signal). This makes the score auditable and the follow-up plannable — the operator sees "Module boundaries: flat — only src/, no domain/application/infrastructure dirs" and immediately knows what to fix, vs a numeric "module-boundaries: 0.3" which gives no guidance.

The warning text on `low` is verbatim:

> ⚠ Harnessability: LOW
>
> Rex's architecture handbooks will fire advisory-only on this codebase. The blocking gate (`ENFORCEMENT: blocking`) will generate false positives. Recommended: adopt as advisory-only, plan a follow-up to add the missing scaffolding (typescript strict, lint baseline, etc.)

Verbatim because the wording is the contract — the operator should see exactly this phrasing in their terminal AND in the persisted assessment file, so future-them or their teammate can grep `handover-assessment.md` for "Harnessability: LOW" and find the warning unchanged.

## Consequences

- **Conservative thresholds are explicit and tunable.** v1 hard-codes the truth table in `.claude/skills/handover/SKILL.md` as a bash-shaped pseudocode block. A future AgDR can revisit the thresholds with adoption data ("we saw 80% of adopters land in `low` and ignored the warning — relax the thresholds"). The current table is the v1 baseline; this AgDR is the citation for any future change.
- **Stack-blind for Go and Rust.** Both languages get `strong` on type safety implicitly because the language itself is strongly typed. This may over-credit Go projects that ship interface-heavy code without any static analysis (`golangci-lint` config still needed for lint baseline, but type safety auto-passes). Acceptable v1 trade-off — the alternative is a per-stack scoring matrix, which is more code and more litigation per stack. Re-evaluate if Go / Rust adopters surface real false positives.
- **Single-dimension gaming is possible.** A project with one rule in `.eslintrc.json` passes lint baseline; a `coverageThreshold: { global: { lines: 1 } }` passes coverage signal. v1 accepts this — the score is a starting point for an honest conversation, not a regression test. An operator who's gaming the score is implicitly opting out of the warning, which is their call.
- **Re-running `/handover` re-scores from the live tree.** The score is not persisted as a tracked metric over time — it lives only in the assessment file from the most recent handover run. Tracking the score quarter-over-quarter is out of scope (per the ticket). If a project wants that, it can grep the assessment file across `git log -p` history.
- **Legacy-adopter sensitivity.** Many existing managed projects (especially Bash scripts, single-file utilities, or pre-2020 legacy code) will score `low` on first scan. This is by design — the warning is exactly the signal those adopters need before turning on the harness. Operators uncomfortable with the score for a project they consider intentionally simple have the workaround of marking the relevant handbooks advisory-only and proceeding. The score doesn't gate adoption; it informs it.
- **Future direction — auto-fix companion skill.** A separate skill (`/raise-floor` or similar) could close the gap mechanically: add `tsconfig.json` strict, scaffold a minimal `.eslintrc.json`, add a coverage threshold. Out of scope for this AgDR; would build on the per-dimension rationales emitted here.
- **Future direction — per-handbook scoring.** v1 maps dimensions to handbook *classes*, not individual handbooks. A future iteration could score each handbook the project would import against the codebase shape (so a project missing only TypeScript-strict gets a granular "won't apply" verdict on TS-specific handbooks). Deferred — coarser score is enough for the adoption decision.

## Artifacts

- GitHub issue: [me2resh/apexyard#298](https://github.com/me2resh/apexyard/issues/298)
- Branch: `feature/GH-298-handover-harnessability-scoring`
- Related: [AgDR-0037](AgDR-0037-rex-domain-handbooks.md) (Rex domain handbook discovery), [`handbooks/architecture/clean-architecture-layers.md`](../../handbooks/architecture/clean-architecture-layers.md) (the canonical blocking-handbook example whose false-positive surface this score quantifies).
- Skill: [`.claude/skills/handover/SKILL.md`](../../.claude/skills/handover/SKILL.md) § "Harnessability assessment".
