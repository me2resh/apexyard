---
name: code-review
description: Review a PR for quality, security, and standards compliance. Invokes the Code Reviewer agent (Rex).
disable-model-invocation: true
argument-hint: "<pr-number> [repo]"
allowed-tools: Bash, Read, Grep, Glob
---

# /code-review — Code Review

Review a pull request for quality, security, and adherence to standards.

## Activated agent + role

When `/code-review` runs:

1. **Primary reviewer**: the **Code Reviewer agent (Rex)** at [`.claude/agents/code-reviewer.md`](../../agents/code-reviewer.md) — runs on every commit, owns the automated first-pass review.
2. **Human approval gate**: the **[Tech Lead](../../../roles/engineering/tech-lead.md)** — activates to sign off on architecture, design patterns, and team conventions that Rex can't judge from code alone.
3. **Conditional Security Auditor**: if the diff touches `**/auth/**`, `**/crypto/**`, `**/secrets/**`, `.env*`, or similar, the **[Security Auditor](../../../roles/security/security-auditor.md)** also activates and must sign off before merge. Consider chaining `/security-review` for the deeper pass.
4. **Conditional UI Designer**: if the diff touches visible UI, the **[UI Designer](../../../roles/design/ui-designer.md)** activates for design review.

See [`.claude/rules/role-triggers.md`](../../rules/role-triggers.md) for the full activation protocol.

## Usage

```
/code-review 30
/code-review 30 your-org/your-repo
```

## Process

1. Fetch PR details and the latest commit SHA
2. Get the diff
3. Review against the checklist (architecture, code quality, testing, security, performance)
4. Check for the required Glossary section
5. Check for AgDR links if technical decisions were made
6. Submit a GitHub review via `gh pr review`

## Review Checklist

### Architecture
- Domain layer has no external dependencies
- Application layer doesn't import infrastructure
- Proper separation of commands vs queries

### Code Quality
- Type-safety enforced
- No unjustified `any` types
- Proper error handling
- Clear naming conventions

### Testing
- Unit tests for domain logic
- Tests test behavior, not implementation
- Edge cases covered

### Security
- No secrets in code
- Input validation present
- No injection vulnerabilities

### PR Description
- Links to the ticket
- **Has a Glossary section** (REQUIRED — request changes if missing)
- AgDR links if decisions were made

### Technical Decisions (AgDR) — BLOCKING

Scan the diff for unrecorded decisions:

- New dependencies / libraries in build files
- New frameworks (ORM, queue, cache, etc.)
- Architecture patterns implemented
- Design pattern choices

**If a decision is detected but no AgDR is linked**:

1. REQUEST CHANGES (do not approve)
2. List the specific decisions found
3. Instruct the author to run `/decide`
4. The PR cannot merge until the AgDR is linked

## Output

Posts a GitHub review comment with:

- Commit SHA reviewed
- Checklist results
- Issues found
- Verdict: APPROVED / CHANGES REQUESTED / COMMENT

Invokes: Code Reviewer Agent (Rex)
