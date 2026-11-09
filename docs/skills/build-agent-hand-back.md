# Build-agent brief and hand-back

A decision made for you is a choice the ticket did not state.
Examples include a default, a scope cut, or a resolution of conflicting requirements.

## Brief requirements

Include the ticket, scope, constraints, reference paths, and required checks.
Include known decisions and their reasons under `## Decisions made for you`.
Require the agent to return the format below and record additional choices there.
Use "None" only with a one-line reason.
Surface unresolved conflicts explicitly instead of silently choosing a requirement.

## Required hand-back format

```markdown
## Result
[State completed work and remaining acceptance criteria.]

## Decisions made for you
- [Choice: default chosen, scope cut, or conflicting requirements and their resolution. State the reason.]
[Use "None" only with a one-line reason.]

## Validation
[Commands, results, and checks that could not run.]

## Follow-ups
[Remaining work and unresolved conflicts, or None with a reason.]
```

## Orchestrator responsibilities

Copy each agent's decision list into `## Decisions made for you` in the PR body.
Preserve reasons and unresolved conflicts when combining lists.
Request a corrected hand-back if its decision section is missing, empty, or vague.
