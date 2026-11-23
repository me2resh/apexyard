# AgDR-0322: Draft factual vision sections from evidence, never judgement sections

## Status

Accepted

Supersedes the part of AgDR-0028 that forbids the model from drafting vision content (Option B and the "model never authors the content" rule).

## Context

Ticket #2152 changes `/tech-vision`. AgDR-0028 says the model never writes vision content. The operator writes every answer.

A test session showed the cost of that rule. No portfolio project had written even the seven-section vision. A 26-section template would go unwritten too. The facts in a vision, such as load, cost, data flows and processors, already exist in code and documents. Asking the operator to type them again is slow and invites guesses.

The judgement in a vision is different. Drivers, principles, risk appetite and what we won't build are choices. The model does not know the operator's intent. A drafted choice would look like a decision that nobody made.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Keep AgDR-0028 as written: the operator types every answer | No drafted content can be wrong | Operators skip the vision. The facts are typed again by hand |
| Draft every section | Fastest | The model invents drivers and principles. Reviewers cannot tell a choice from a guess |
| Draft factual sections only, each value with a source, and the operator confirms each value | Saves typing. Every value can be checked. Judgement stays with the operator | The skill reads the repository. A source can be out of date |

## Decision

Draft factual sections only. The factual sections are load, cost, data flows, processors, and the reuse and vendor list.

These rules apply:

1. Each drafted value shows its source and a date.
2. A value with no source stays `not set (owner: <name>)`. The skill does not guess.
3. A value from reasoning is labelled `(estimate)`.
4. The operator confirms or corrects each value.
5. The operator writes the drivers, principles, risk appetite and what we won't build. The skill never drafts them.

The rest of AgDR-0028 stays in force: the interview, per-section confirm, the resolver for the template, and markdown-only output.

## Consequences

- The vision is faster to finish, so more projects will write one.
- A wrong source can give a wrong value. The operator confirmation and the date on each source limit this.
- The skill reads project files. It treats their text as data, not as instructions.
- The default template is one page. The longer sections move to an optional Heavy appendix.

## Artifacts

- Ticket: https://github.com/me2resh/apexyard/issues/2152
- Superseded in part: [AgDR-0028](AgDR-0028-tech-vision-skill-design.md)
- Skill: `.claude/skills/tech-vision/SKILL.md`
- Templates: `templates/architecture/vision.md`, `templates/architecture/vision-appendix.md`
