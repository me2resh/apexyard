# ApexYard Capability Tour

A 60-second orientation to the three ideas that make ApexYard different from
"just a folder of prompts": **roles**, **skills**, and **gates**. This is the
shared tour content rendered by both `/onboard` (first-run) and `/tutorial`
(re-entry, any time) — one asset, read by both, never duplicated. See
`docs/technical-designs/onboarding-increment-1.md` § D3.

Skippable in one word — say "skip" at any point and move on.

---

## What's a role?

A role is a named persona with its own responsibilities and CAN/CANNOT
boundaries — think of it as a teammate, not a mode. When work matches a
role's trigger (a PR touches `**/auth/**`, a technical design needs review),
that role activates and drives the task.

**Example**: open a PR that touches authentication code, and Hakim (the
Security Auditor) activates automatically to review it — you didn't have to
ask.

## What's a skill?

A skill is a slash command that packages a whole workflow — questions to
ask, a template to fill in, a place to file the result — so you don't have
to reconstruct the process by hand each time.

**Example**: `/feature` asks you for a user story and acceptance criteria,
shows you the formatted ticket, and files it as a real GitHub issue once you
confirm.

## What's a gate?

A gate is a checkpoint the work can't pass until a specific condition is
met — tests green, a reviewer's sign-off, your explicit approval. Gates are
mechanically enforced, not just written down: a hook blocks the action until
the gate is satisfied.

**Example**: `gh pr merge` is blocked until both Rex (the automated code
reviewer) and you, the human, have each approved that exact commit — no
merge slips through on a plan-level "go".

## How the loop works

Idea → ticket → PR → review → merge. Every feature moves through this loop;
roles drive each stage, skills do the mechanical work, gates make sure
nothing skips a step.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
