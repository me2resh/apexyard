---
id: AgDR-0238
timestamp: 2026-10-13T15:00:00Z
agent: claude
model: claude-opus-5-5
trigger: user-prompt
status: executed
---

# AgDR-0238: Hosting-first scaffold interview

> In the context of a confusing /scaffold interview, I chose a hosting-first interview with defaults, to keep it short, accepting defaults the owner reviews.

## Context

The first /scaffold interview asked up to 15 questions in three tiers. A live test run on 2026-10-13 showed four faults:

- The onboarding `database` key filled the data-sensitivity question, so the privacy question was skipped.
- Reused onboarding answers skipped questions without a notice.
- Some questions had four presets plus "Not sure". The menu allows four options.
- The budget question needed a currency follow-up. The owner found the cost questions confusing.

The owner asked for a different flow: ask where the project runs, then recommend the technology and the pipeline. The owner also asked to remove the cost, currency and test questions. A roundtable of the platform, UX, architecture and product roles, with a contrarian, converged on the design below.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep the 15-question bank and fix the four faults | Small change | Still too many questions for a non-engineer; cost questions stay |
| Hosting-first interview with derived defaults | 3, 4 or 5 questions; the hosting answer drives the stack and the pipeline | More choices become defaults; the summary must show them |

## Decision

Chosen: **hosting-first interview with derived defaults**.

- The questions are: where it runs, which cloud (only when needed), what it is, and who uses it (the scale).
- A small product and a production service also ask about personal or payment data. A production service also asks who checks a release.
- A demo asks 3 questions, a small product 4, and a production service 5. A cloud follow-up and a confirm screen can add one each.
- When onboarding or a PRD supplies values, one confirm screen shows them first. A question is skipped only after the owner confirms.
- A closed key map and a closed value table read onboarding. An unknown value means the skill asks. No onboarding key fills data sensitivity, compliance or sign-in.
- Each question has at most three presets and "Not sure, recommend for me". "Not sure" picks the recommended preset that the screen shows.
- A rules table maps the host and the shape to a golden path, a pipeline, manual steps and an infrastructure draft kind.
- The default managed hosting service is Netlify.
- Test coverage (80 percent), the page-size budget (500 KB for web) and the language become defaults or derived values. The summary shows each one with its source.
- A final summary screen offers: use this setup, change one answer, or start with a minimal custom setup.
- Until deploy templates exist (outcome o4), the summary says that deploy is not set up yet.
- The skill never asks about budget or currency. Outcome o4 shows a rough monthly cost range, labelled "not a quote", with no question.

## Consequences

- Plan `plan-apexyard-scaffold` revision 3 amends nine criteria:
  - ac1-1: host first, with 3, 4 or 5 questions by scale.
  - ac1-5: the answer sources default and derived.
  - ac2-1: defaults instead of questions for language, coverage and design.
  - ac4-1, ac4-2, ac4-5 and ac4-6: no budget question, and a cost range only.
  - ac5-1: the language comes from the golden path.
  - ac6-2: a page-size budget default of 500 KB.
- The spec gains the sources `default` and `derived`. Old spec fields such as budget and coverage are listed as no longer used.
- A wrong default can add work, for example the "personal details" default adds data safeguards. The confirm and summary screens make each default visible.
- The hosting value table needs updates when new hosting services appear. An unknown value only adds a question.

## Artifacts

- Ticket #1708, slice `slice-scaffold-o1-interview`.
- Roundtable artifact in the portfolio docs (2026-10-13, scaffold interview redesign).
- `.claude/skills/scaffold/` (questions, rules, schema, scripts, skill text).
