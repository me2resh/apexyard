# Code Review Process

Code review checks that a change is correct, safe, and understandable before it reaches production. It also records the reasoning that future maintainers need.

---

## Roles

Code review is a **role-activated** workflow. The roles below activate automatically when a PR is opened, per [`.claude/rules/role-triggers.md`](../.claude/rules/role-triggers.md). When you activate one of these roles for a review, signal it with the single-line marker convention from [`.claude/rules/role-triggers.md`](../.claude/rules/role-triggers.md) § "How to signal activation" — e.g. `▸ Activating Hakim (Security Auditor) for PR #42 (trigger: diff touches **/auth/**)`.

| Role | Responsibility | Role file |
|------|----------------|-----------|
| **Author** | Creates PR, responds to feedback. The engineer who wrote the code: [Backend Engineer](../roles/engineering/backend-engineer.md) or [Frontend Engineer](../roles/engineering/frontend-engineer.md). | `roles/engineering/{backend,frontend}-engineer.md` |
| **Code Reviewer agent (Rex)** | Automated first-pass review on every commit. Checks architecture, tests, security, AgDR, glossary. | `.claude/agents/code-reviewer.md` |
| **Tech Lead reviewer** | Human approval gate. Signs off on architecture, design patterns, team conventions. | [`roles/engineering/tech-lead.md`](../roles/engineering/tech-lead.md) |
| **Security Auditor** (conditional) | Activates when the PR diff touches `**/auth/**`, `**/crypto/**`, `**/secrets/**`, `.env*`, or similar. Findings + required fixes hand off to the Tech Lead; strategy / compliance / repeated-pattern concerns escalate to the [Head of Security](../roles/security/head-of-security.md). | [`roles/security/security-auditor.md`](../roles/security/security-auditor.md) |
| **UI Designer** (conditional) | Owns the **routine per-PR design gate** — activates when the PR diff touches UI components, design tokens, or visible layout, reviews the implementation diff, and records approval via `/approve-design`. The [Head of Design](../roles/design/head-of-design.md) is the **escalation path** (design-system changes, cross-product visual standards, disagreements, no UI Designer available), not the routine reviewer. See AgDR-0106. | [`roles/design/ui-designer.md`](../roles/design/ui-designer.md) |
| **QA Engineer** | Not a reviewer — takes over at the QA phase after merge to verify acceptance criteria. | [`roles/engineering/qa-engineer.md`](../roles/engineering/qa-engineer.md) |

---

## Author Responsibilities

### Before Requesting Review

1. **Read your diff** — inspect every changed line.
2. **Run the checks** — lint, type checks, and tests must pass.
3. **Write a useful PR description** — explain what changed, why it matters, and how to verify it.

### PR Description Format

```markdown
## Summary
- Brief description of changes (2-4 bullet points)

## Testing
1. How to verify this works

Fixes #[ticket-id]

---

## Glossary
| Term | Definition |
|------|------------|
| [Term] | [What it means in this context] |
```

**Summary bullets must be narrative, not label-only.** Every bullet should answer *what changed* AND *why it matters to the person reading this*. Label-only bullets ("State fix", "CI pipeline changes") force reviewers into diff archaeology and waste their judgment time. See [`.claude/rules/pr-quality.md`](../.claude/rules/pr-quality.md) § "Summary bullets — narrative quality" for the rule, a worked bad/good pair, and the legitimate-exceptions list. Rex flags label-only bullets as an advisory finding (`nit:` / `suggestion:`, non-blocking).

**Why a Glossary?** A glossary makes a PR useful to more than the people who wrote it. Clear definitions help:

- Junior devs learn from senior work
- Seniors articulate their thinking
- Future readers understand decisions
- Build shared vocabulary

### During Review

- Respond to all comments
- Don't take feedback personally
- Ask for clarification if unclear
- Update code or explain why not
- Re-request review after changes

---

## Reviewer Responsibilities

### How to Review

1. **Understand the context** — read the PR description and linked ticket.
2. **Check correctness** — confirm the requested behavior and test the important edge cases.
3. **Check quality** — review architecture, conventions, readability, and maintenance cost.
4. **Check security** — look for validation gaps, authorization errors, and leaked sensitive data.
5. **Check tests** — confirm that tests cover the behavior and protect against regressions.

### Giving Feedback

**Be constructive**:

```
BAD:  "This is wrong"
GOOD: "This might throw a null error if user is undefined.
       Consider adding a null check."
```

**Be specific**:

```
BAD:  "Improve this function"
GOOD: "This function has multiple responsibilities. Consider extracting
       the validation logic into a separate validateOrder() function."
```

**Distinguish severity**:

```
BLOCKING:  "This exposes user passwords in logs. Must fix."
SUGGESTION: "NIT: Could rename this to `calculateTotal` for clarity"
QUESTION:   "Why did you choose Map over Object here?"
```

### Response Time

| Priority | Response Time |
|----------|---------------|
| Urgent (blocking release) | < 2 hours |
| Normal | < 24 hours |
| Large PR (500+ lines) | < 48 hours |

---

## Review Checklist

### Architecture

- [ ] Follows architecture principles
- [ ] Dependencies point inward (clean architecture)
- [ ] Domain logic in domain layer
- [ ] No business logic in infrastructure

### Code Quality

- [ ] Follows naming conventions
- [ ] Functions are small and focused
- [ ] No code duplication
- [ ] No dead code
- [ ] Comments explain why, not what
- [ ] Fallow static-analysis pass reviewed (JS/TS) — dead code, unused exports/deps, duplication, circular deps, complexity hotspots (advisory; Rex runs it automatically on JS/TS diffs when the `fallow` CLI is available — see `.claude/agents/code-reviewer.md` § 9)

### Security

- [ ] Input validated at boundaries
- [ ] No injection vulnerabilities
- [ ] No XSS vulnerabilities
- [ ] Sensitive data not logged
- [ ] Auth/authz checked

### Testing

- [ ] Unit tests for domain logic
- [ ] Integration tests for use cases
- [ ] Edge cases covered
- [ ] Tests are readable

### Performance

- [ ] No N+1 queries
- [ ] No unnecessary database calls
- [ ] Async operations where appropriate

---

## Approval Requirements

| Change Type | Approvals Needed |
|-------------|------------------|
| Standard feature | 1 (Tech Lead or Senior) |
| Infrastructure | 1 + Platform Engineer |
| Security-related | 1 + Security review |
| UI change | 1 + UI Designer (routine design gate; Head of Design on escalation) |
| Architecture change | Head of Engineering |

---

## Handling Disagreements

1. **Discuss** -- Try to understand each other's perspective
2. **Provide evidence** -- Reference principles, docs, data
3. **Escalate if needed** -- Tech Lead makes the call
4. **Accept and move on** -- Once decided, commit to it

---

## Anti-Patterns

| Anti-Pattern | Problem | Instead |
|--------------|---------|---------|
| Rubber stamping | No real review | Actually read the code |
| Nitpicking everything | Slows down, frustrates | Focus on what matters |
| Blocking for style | Automate with linter | Use automated checks |
| Personal attacks | Toxic culture | Critique code, not person |
| Huge PRs | Hard to review well | Keep PRs < 400 lines |

---

## Metrics

Track these to improve:

- PR size (aim for < 400 lines)
- Review time (aim for < 24h)
- Review cycles (aim for < 3)
- Post-merge bugs (aim for < 5%)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
