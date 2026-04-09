# Code Review Process

Ensure code quality, share knowledge, and catch issues before they reach production.

---

## Roles

Code review is a **role-activated** workflow. The roles below activate automatically when a PR is opened, per [`.claude/rules/role-triggers.md`](../.claude/rules/role-triggers.md).

| Role | Responsibility | Role file |
|------|----------------|-----------|
| **Author** | Creates PR, responds to feedback. The engineer who wrote the code: [Backend Engineer](../roles/engineering/backend-engineer.md) or [Frontend Engineer](../roles/engineering/frontend-engineer.md). | `roles/engineering/{backend,frontend}-engineer.md` |
| **Code Reviewer agent (Rex)** | Automated first-pass review on every commit. Checks architecture, tests, security, AgDR, glossary. | `.claude/agents/code-reviewer.md` |
| **Tech Lead reviewer** | Human approval gate. Signs off on architecture, design patterns, team conventions. | [`roles/engineering/tech-lead.md`](../roles/engineering/tech-lead.md) |
| **Security Auditor** (conditional) | Activates when the PR diff touches `**/auth/**`, `**/crypto/**`, `**/secrets/**`, `.env*`, or similar. | [`roles/security/security-auditor.md`](../roles/security/security-auditor.md) |
| **UI Designer** (conditional) | Activates when the PR diff touches UI components, design tokens, or visible layout. | [`roles/design/ui-designer.md`](../roles/design/ui-designer.md) |
| **QA Engineer** | Not a reviewer — takes over at the QA phase after merge to verify acceptance criteria. | [`roles/engineering/qa-engineer.md`](../roles/engineering/qa-engineer.md) |

---

## Author Responsibilities

### Before Requesting Review

1. **Self-review your diff** -- Read every line you changed
2. **Ensure CI passes** -- Lint, type check, tests
3. **Write a good PR description**

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

**Why a Glossary?** Every PR is a learning opportunity. Explaining concepts helps:
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

1. **Understand context first** -- Read PR description, check linked ticket
2. **Review for correctness** -- Does it do what it's supposed to? Edge cases?
3. **Review for quality** -- Architecture, conventions, readability, maintainability
4. **Review for security** -- Input validation, auth, sensitive data
5. **Review tests** -- Meaningful tests, edge cases, regression protection

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
