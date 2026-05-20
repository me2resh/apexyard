# AgDR-0029 — PR summary narrative quality: prose rule + Rex advisory check

> In the context of PR descriptions generated under ApexYard's existing structural rules (glossary mandatory, ticket link mandatory, Summary section present) consistently shipping with **label-only summary bullets** ("State fix", "OPA/Rego compliance policies", "CI pipeline changes", "Pre-commit hooks") that force reviewers into diff archaeology before they can pick a review focus, facing the question of how strongly to enforce the new "every bullet states *what changed* AND *why it matters*" rule, I decided to ship a **prose-only rule in `.claude/rules/pr-quality.md` + a `nit:` / `suggestion:`-shaped advisory check in Rex** (non-blocking; the false-positive rate on the label-only heuristic is too high for a blocking gate to be worth the merge-gate churn), to achieve a measurable lift in narrative quality across PRs without trapping legitimate one-line bug fixes or dependency bumps behind a request-changes verdict, accepting that adoption is gradual (self-discipline-first, Rex-advisory as the back-pressure) rather than instant, and that we may need to revisit blocking enforcement once the heuristic's false-positive rate is measured under real traffic.

## Context

The framework currently mandates PR-description **structure** but says nothing about the **narrative quality** of the summary bullets. The structural rules — glossary present, ticket link present, `## Summary` section present — are mechanically enforced by `validate-pr-create.sh` (#20) and by Rex's checklist § 6 "PR Description Quality". They are necessary; they are not sufficient.

The visible failure mode: PRs ship with `## Summary` sections containing four to six terse noun-phrase bullets that name the area of change without explaining what the change is or why it matters. A reviewer reading the description cold cannot pick a review focus from the bullets alone; every PR becomes a code-archaeology exercise before judgment can begin. The example from the originating ticket (#312) is representative:

```
## Summary
- State fix
- OPA/Rego compliance policies
- CI pipeline changes
- Pre-commit hooks
```

PR descriptions are the primary async communication channel between author and reviewer. A label-only description converts every reviewer into an archaeologist — a tax that scales with team size and PR throughput.

Two adjacent framework patterns shape the design choice:

1. **The glossary rule (mandatory + blocking)** — every PR must have a Glossary table; missing one is REQUEST CHANGES. The rule is high-signal because the violation shape ("section absent") is unambiguous and the cost of false-positive blocking is essentially zero.
2. **The handbook discovery system (#232) — advisory-by-default, blocking-on-opt-in** — handbooks ship as `nit:` / `suggestion:` findings unless the author writes `ENFORCEMENT: blocking` at the top of the file. This is the framework's established escape valve for "we want the rule visible, but we don't want it to churn the merge gate".

The narrative-quality rule sits closer to the second shape than the first. The violation shape ("bullet is label-only") is a heuristic, not a binary, and the false-positive rate matters.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. Prose-only rule + Rex advisory check** (chosen) | Lowest implementation cost; matches the established advisory-handbook pattern (#232); no false-positive churn on bug-fix or dependency-bump PRs; rule lands and starts shaping behaviour immediately via Rex's review comments | Adoption is gradual; depends on Rex consistently surfacing the finding; no mechanical enforcement against a determined bypass |
| B. Hook-enforced check (`validate-pr-create.sh` grep) | Mechanically enforced at PR-create time; visible at the moment the failure happens | False-positive rate is high — `Bumps lockfile`, `Fixes #42`, `Renames Foo → Bar across 17 files` are all legitimate short bullets that would block. The skip-condition logic ("is this a pure dependency bump?") is itself a heuristic that needs maintenance. The churn cost on the wrong PRs outweighs the lift on the right ones. |
| C. Rex blocking verdict on label-only bullets | Strongest enforcement signal; same shape as the existing AgDR-required + glossary-required blockers | Same false-positive problem as Option B but at the merge gate instead of the PR-create gate. A blocking verdict on a `nit:`-class finding is the wrong shape — it teaches the team to ignore Rex's blockers in general, weakening the rules that genuinely should block. |
| D. Template-only nudge — update `.github/PULL_REQUEST_TEMPLATE.md` with a checkbox and stop there | Trivially low cost; visible at PR-create time in the GitHub UI | Weakest. Templates can be ignored, deleted, or edited away. The framework currently ships no PR template (the repo has none at `.github/PULL_REQUEST_TEMPLATE.md`), so Option D would be the bare minimum on top of nothing — it would not catch PRs created via `gh pr create` with an inline body that bypasses the template entirely. |
| E. A + C-as-advisory (chosen here is identical to A; documenting for clarity) | Belt-and-braces — rule lives in two places, Rex echoes it on every PR | Already what Option A delivers; not a separate option |

## Decision

Chosen: **Option A — prose-only rule + Rex advisory check**.

Concretely:

1. **Rule** lives at `.claude/rules/pr-quality.md` § "Summary bullets — narrative quality (MANDATORY)". Contains the rule statement, a bad/good worked example pair (verbatim from the originating ticket), a three-question author self-check, and an explicit legitimate-exceptions list (dependency bumps, mechanical refactors, single-line bug fixes whose fix IS the rationale).

2. **Cross-link** from `workflows/code-review.md` § "PR Description Format" — one paragraph that names the rule and links into `pr-quality.md` for the worked examples. PR authors reading the workflow doc see the standard before they write the description.

3. **Rex check** in `.claude/agents/code-reviewer.md` § 6 "PR Description Quality". Detection heuristic: bullet text after stripping list punctuation is ≤ 6 words AND contains no verb. Verdict effect: surface as `nit:` / `suggestion:`, do NOT downgrade verdict from APPROVED. Skip the check entirely on pure-dependency-bump and pure-rename diffs (both of which legitimately produce short bullets).

4. **No PR template change** — the framework repo currently ships no `.github/PULL_REQUEST_TEMPLATE.md`. Adding one for a single advisory bullet would create a new framework file that adopters have to merge on every upstream sync, for marginal benefit. The rule + cross-link + Rex check covers the same surface without that maintenance tax.

5. **No mechanical enforcement at PR-create time.** `validate-pr-create.sh` continues to check structure (glossary present, ticket link present) but does NOT add a label-only-bullet check. Defer the question of mechanical enforcement until we have real-traffic data on how often Rex's advisory finding is the right call.

## Consequences

- **Authors learn the rule by reading Rex's review comments.** The first few PRs after this lands will get advisory `nit:` callouts; the rule diffuses through the team via Rex's prose rather than a blocking gate.
- **Legitimate short bullets stay unblocked.** Dependency bumps, mechanical refactors, and single-line bug fixes that legitimately produce ≤ 6-word bullets are explicitly listed as exceptions in the rule, and Rex's skip-condition logic short-circuits the check entirely on pure-dependency-bump and pure-rename diffs.
- **The rule is composable with `validate-pr-create.sh`.** That hook continues to enforce the structural contract; this rule sits on top as a quality contract enforced by Rex's prose review.
- **Rex's verdict semantics stay clean.** Blocking verdicts (REQUEST CHANGES) remain reserved for rules with a low false-positive rate and a clear violation shape (missing glossary, missing AgDR for a detected decision, blocking-handbook violation). Mixing advisory-class findings into the blocking pool would dilute the signal of the blockers that genuinely matter.
- **Mechanical enforcement remains a future option.** If real traffic shows the advisory finding is consistently the right call, a follow-up ticket can graduate it to blocking — either by promoting the rule via the `ENFORCEMENT: blocking` marker convention (if it ever migrates into a handbook) or by adding a hook-enforced check with a tightened heuristic. The current decision deliberately leaves that door open without walking through it.
- **The `.github/PULL_REQUEST_TEMPLATE.md` decision is documented but defer-able.** Adopters who want the checkbox in their PR UI can add the template to their own fork (the framework's `.gitignore`-the-fork pattern under split-portfolio mode already supports per-adopter UI overrides). The framework itself does not ship the file.

## Artifacts

- Issue: me2resh/apexyard#312
- PR: `feat(#312): PR summary narrative-quality rule + Rex advisory check` against `dev`
- Rule: `.claude/rules/pr-quality.md` § "Summary bullets — narrative quality (MANDATORY)"
- Workflow cross-link: `workflows/code-review.md` § "PR Description Format"
- Rex agent: `.claude/agents/code-reviewer.md` § 6 — new sub-section "Label-only summary bullets — advisory check (non-blocking)"
- Smoke test: `.claude/rules/tests/test_pr_quality_narrative_rule.sh`
- Related: AgDR-0020 (adopter handbooks for Rex — same advisory-by-default pattern), #232 (handbook discovery system that established the advisory/blocking convention)
