# ApexYard Capability Tour

A 60-second introduction to the three ideas that organize ApexYard:
**roles**, **skills**, and **gates**. `/onboard` shows this content during
first use, and `/tutorial` shows it again whenever someone needs a refresher.
Both commands read this one shared file. See
`docs/technical-designs/onboarding-increment-1.md` § D3.

You can skip the tour at any time by saying "skip".

---

## What's a role?

A role names a type of teammate, its responsibilities, and its CAN/CANNOT
boundaries. When work matches a role's trigger, the role activates and guides
the task. For example, a PR that touches `**/auth/**` activates the Security
Auditor.

**Example**: Hakim reviews that authentication PR automatically. You do not
need to ask for the review.

## What's a skill?

A skill is a slash command that packages a workflow: the questions to ask, the
template to use, and where to save the result. It gives each run the same
starting point.

**Example**: `/feature` asks for a user story and acceptance criteria, shows
the formatted ticket, and files a GitHub issue after you confirm it.

## What's a gate?

A gate is a checkpoint. Work cannot pass it until a required condition is
met, such as passing tests, a reviewer sign-off, or your explicit approval.
Hooks enforce these conditions, so the gate is an action the system checks,
not only a rule in a document.

**Example**: `gh pr merge` stays blocked until Rex and you have approved the
same commit. A plan-level "go" does not replace those approvals.

## How the loop works

Idea → ticket → PR → review → merge. Roles guide each stage, skills carry out
repeatable steps, and gates stop work from skipping a required check.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
