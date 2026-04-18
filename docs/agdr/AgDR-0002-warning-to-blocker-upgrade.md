---
id: AgDR-0002
timestamp: 2026-04-12T06:00:00Z
agent: atlas
model: claude-opus-4-6
trigger: user-prompt
status: executed
ticket: me2resh/apexyard#20
---

# Warning-to-blocker upgrade for branch-name and PR-title validation

> In the context of the rule-mechanization audit (#13) which found that warnings are "prose in disguise", facing the question of whether to upgrade `validate-branch-name.sh` and `validate-pr-create.sh` from warning (exit 0) to blocker (exit 2), I decided to upgrade both to blockers to close the enforcement gap, accepting that this is a behavior-visible breaking change for existing users.

## Context

The first real test run of ApexYard (2026-04-11) exposed that agents drop rules under pressure. The subsequent audit identified that two pre-existing hooks — `validate-branch-name.sh` and `validate-pr-create.sh` — only warned on rule violations via stderr output but always exited 0, allowing the operation to proceed. This makes them functionally equivalent to prose advice: the harness runs them, but their warnings can be silently ignored.

AgDR-0001 explicitly listed the warning-to-blocker upgrade as a deferred follow-up, noting it was a "breaking change" that deserved its own ticket.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A — Upgrade both to blockers** | Closes the enforcement gap completely. Branch names and PR titles either conform or the operation is rejected. Matches the "if it's a MUST, it's a hook" principle from the audit. | Breaking change — users who got used to pushing with non-conforming names will now be blocked. May surprise contributors on first push after upgrade. |
| **B — Keep as warnings** | No breaking change. Familiar behavior. Users who push non-conforming branches can still do so and fix later. | Defeats the purpose of the rule-mechanization audit. Warnings were ignored in the test run — that's the incident that started this entire session. |
| **C — Configurable severity** | Add a `hook_severity` field to `project-config.json` that lets forks choose warning vs blocker per hook. | Over-engineering for a binary choice. Adds complexity to every hook. The "make everything configurable" instinct here is premature abstraction. |

## Decision

**Chosen: Option A — upgrade both to blockers.**

The entire session exists because prose rules and warning-only hooks were ignored under pressure. Keeping them as warnings is inconsistent with the design philosophy established in AgDR-0001 ("if a rule is important, put it in a hook; if it's a preference, put it in a rule file; if it's context, put it in CLAUDE.md"). Branch naming and PR title format are MUST rules in `git-conventions.md` — they belong in a hook that blocks, not one that warns.

The breaking-change concern is real but manageable: a one-paragraph migration note in CLAUDE.md flags the change, and the block messages include actionable fix instructions (rename command for branches, format examples for PR titles).

## Consequences

- Push with non-conforming branch name now fails (exit 2) with a rename suggestion
- PR creation with malformed title, missing glossary, or missing branch ticket ID now fails (exit 2) with format guidance
- Migration note added to CLAUDE.md Quality Rules section
- hooks/README.md updated to replace "Warns" with "Blocks" for both hooks

## Artifacts

- Ticket: [me2resh/apexyard#20](https://github.com/me2resh/apexyard/issues/20)
- Parent decision: AgDR-0001 (rule-mechanization hooks)
