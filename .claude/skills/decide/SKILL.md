---
name: decide
description: Make a technical decision with structured reasoning, creating an Agent Decision Record (AgDR). Use when choosing between libraries, frameworks, implementation approaches, or architectural patterns.
disable-model-invocation: true
argument-hint: "<what you're deciding>"
---

# /decide — Technical Decision Gate

Forces structured decision-making and creates an auditable Agent Decision Record (AgDR).

## Activated role

When `/decide` runs, activate the **[Tech Lead](../../../roles/engineering/tech-lead.md)** role — they own technical decisions within their domain. For decisions that cross the architecture-review threshold (new service, new tech stack, new external integration, major data model change), escalate to the **[Head of Engineering](../../../roles/engineering/head-of-engineering.md)** before creating the AgDR.

If the decision touches auth / crypto / secrets / PII, also involve the **[Security Auditor](../../../roles/security/security-auditor.md)** for sign-off on the security implications before finalising the choice.

See [`.claude/rules/role-triggers.md`](../../rules/role-triggers.md) for the full activation protocol.

## Process

### 1. Parse the Decision Topic

Extract the decision topic from `$ARGUMENTS`. If unclear, ask:

```
What technical decision do you need to make?
```

### 2. Gather Context

Identify decision-relevant context only:

- What problem are we solving?
- What constraints exist?
- What's already in the codebase?

### 3. List Options

Present 2–4 options in a table:

```markdown
| Option | Pros | Cons |
|--------|------|------|
| Option A | … | … |
| Option B | … | … |
```

### 4. Make the Decision

State the chosen option with justification.

### 5. Generate the AgDR

Create file at `{project-root}/docs/agdr/AgDR-{NNNN}-{slug}.md`.

**Important**: AgDRs live in the **current project's repository**, not centralised. Each project has its own `docs/agdr/` folder and its own ID sequence.

Use the AgDR template at `templates/agdr.md`:

```markdown
---
id: AgDR-{NNNN}
timestamp: {ISO-8601: YYYY-MM-DDTHH:MM:SSZ}
agent: {current-agent-name or "claude"}
model: {model-id from environment}
trigger: {user-prompt | hook | automation}
status: executed
---

# {short title}

> In the context of {context}, facing {concern}, I decided {decision} to achieve {goal}, accepting {tradeoff}.

## Context
{Decision-relevant context only — 2–4 bullets}

## Options Considered
| Option | Pros | Cons |
|--------|------|------|
| … | … | … |

## Decision
Chosen: **{option}**, because {justification}.

## Consequences
- {consequence 1}
- {consequence 2}

## Artifacts
- {commit / PR links when available}
```

### 6. Get the Next ID

```bash
ls docs/agdr/AgDR-*.md 2>/dev/null | sort -V | tail -1 | grep -oE 'AgDR-[0-9]+' | grep -oE '[0-9]+'
# Increment by 1, or start at 0001
```

### 7. Return the Decision

```
Decision: {chosen option}
AgDR-{NNNN} created at docs/agdr/AgDR-{NNNN}-{slug}.md
Proceeding with: {brief action}
```

## Rules

1. **Always create an AgDR** — no decision without a record
2. **Y-statement required** — one-line summary at the top
3. **Options table required** — at least 2 options compared
4. **Justification required** — `because` clause is mandatory
5. **Timestamp precise** — full ISO-8601 with time
6. **Slug from title** — lowercase, hyphens, max 50 chars
