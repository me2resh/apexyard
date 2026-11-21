---
id: AgDR-0290
timestamp: 2026-11-08T09:30:00Z
agent: platform-engineer
model: composer
session: gh-1997
trigger: user-prompt
status: executed
category: patterns
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# AgDR-0290: Opt-in approval quiz and read-only /explain-pr

> In the context of human PR approval, facing weak operator recall of agent diffs, I decided to add an opt-in comprehension check before the CEO marker write and a read-only `/explain-pr` skill, to help operators defend what they ship, accepting that the quiz is advisory skill flow and does not harden the merge gate.

## Context

Ticket: me2resh/apexyard#1997.

Gate hardening is frozen. Marker format, approval record, and merge-gate decision logic must not change. The quiz must sit before the existing marker write and must stay off by default.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Opt-in skill step plus shared helper; default `merge.approval_quiz: false`; new read-only `/explain-pr` | No gate change; default behaviour unchanged; reusable quiz pack | Relies on AskUserQuestion and skill discipline |
| B. New merge-gate check that requires a quiz marker | Mechanical enforcement | Changes gate logic (forbidden by this ticket) |
| C. Quiz always on for `/approve-merge` | Stronger default | Blocks every current approve path |

## Decision

Chosen: **A**, because it meets the acceptance criteria without touching gate decision logic, marker format, or the approval record.

1. `/approve-merge` gains `--quiz` and reads `merge.approval_quiz` through `_lib-read-config.sh`.
2. Shared helper `.claude/skills/approve-merge/scripts/approval-quiz.sh` builds a file:line evidence pack from a unified diff and PR body.
3. `/explain-pr` is model-invokable, read-only, and may end with the same quiz.
4. `/approve-merge` keeps `disable-model-invocation: true`.

## Consequences

- Default `/approve-merge` behaviour is unchanged when the quiz is off.
- Operators can turn the quiz on per run or per project.
- Questions must name files and lines from the pack. They must not invent facts.
- Bootcamp review content links to `/explain-pr`.

## Artifacts

- Ticket: me2resh/apexyard#1997
- Helper: `.claude/skills/approve-merge/scripts/approval-quiz.sh`
- Skill: `.claude/skills/explain-pr/SKILL.md`
- Docs: `docs/skills/approval-quiz.md`
- Tests: `.claude/skills/approve-merge/tests/test_approval_quiz.sh`, `.claude/skills/explain-pr/tests/test_explain_pr_contract.sh`
