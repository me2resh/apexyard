# Code Review Process

Code review checks that a change is correct, safe, and understandable before it reaches production. It also records the reasoning that future maintainers need.

---

## Roles

Code review is a **role-activated** workflow. A PR automatically activates the roles below, per [`.claude/rules/role-triggers.md`](../.claude/rules/role-triggers.md). When you activate a review role, use the single-line marker convention from [`.claude/rules/role-triggers.md`](../.claude/rules/role-triggers.md) § "How to signal activation". Example: `▸ Activating Hakim (Security Auditor) for PR #42 (trigger: diff touches **/auth/**)`.

| Role | Responsibility | Role file |
|------|----------------|-----------|
| **Author** | Creates PR, responds to feedback. The engineer who wrote the code: [Backend Engineer](../roles/engineering/backend-engineer.md) or [Frontend Engineer](../roles/engineering/frontend-engineer.md). | `roles/engineering/{backend,frontend}-engineer.md` |
| **Code Reviewer agent (Rex)** | Automated first-pass review on every commit. Checks architecture, tests, security, AgDR, glossary. | `.claude/agents/code-reviewer.md` |
| **Tech Lead reviewer** | Human approval gate. Signs off on architecture, design patterns, team conventions. | [`roles/engineering/tech-lead.md`](../roles/engineering/tech-lead.md) |
| **Security Auditor** (conditional) | Activates when the PR diff touches `**/auth/**`, `**/crypto/**`, `**/secrets/**`, `.env*`, or similar. Sends findings and required fixes to the Tech Lead. Sends risk acceptance and security exceptions to the human approver (AgDR-0301). | [`roles/security/security-auditor.md`](../roles/security/security-auditor.md) |
| **UI Designer** (conditional) | Owns the **routine per-PR design gate**. Activates when the PR diff touches UI components, design tokens, or visible layout. Reviews the implementation diff. Records approval via `/approve-design`. Design-system changes, cross-product visual standards, and disagreements go to the **human approver**, not to an agent. See AgDR-0301, which supersedes AgDR-0106. | [`roles/design/ui-designer.md`](../roles/design/ui-designer.md) |
| **QA Engineer** | Verifies acceptance criteria in the QA phase after merge. Does not act as a reviewer. | [`roles/engineering/qa-engineer.md`](../roles/engineering/qa-engineer.md) |

Rex and the Security Auditor split scope and do not repeat each other's checks. Rex owns code quality, tests, and the writing profile. The Security Auditor owns security and gate integrity. See `.claude/agents/code-reviewer.md` § "Scope Split with the Security Auditor" and `.claude/agents/security-reviewer.md` § "Scope Split with the Code Reviewer".

---

## Author Responsibilities

### Before Requesting Review

1. **Read your diff**. Inspect every changed line.
2. **Run the checks**. Lint, type checks, and tests must pass.
3. **Write a useful PR description**. Explain what changed, why it matters, and how to verify it.

### PR Description Format

```markdown
## Summary
- Brief description of changes (2-4 bullet points)

## Testing
1. How to verify this works

Closes #[ticket-id]

---

## Glossary
| Term | Definition |
|------|------------|
| [Term] | [What it means in this context] |
```

**Summary bullets must be narrative, not label-only.** Every bullet should answer *what changed* AND *why it matters to the person reading this*. Label-only bullets ("State fix", "CI pipeline changes") make reviewers search the diff and waste their time. See [`.claude/rules/pr-quality.md`](../.claude/rules/pr-quality.md) § "Summary bullets — narrative quality (MANDATORY)" for the rule, a worked bad/good pair, and the legitimate-exceptions list. Rex flags label-only bullets as an advisory finding (a `Nit`, non-blocking).

**Why a Glossary?** A glossary makes a PR useful to more than the people who wrote it. Clear definitions help:

- Junior devs learn from senior work
- Seniors articulate their thinking
- Future readers understand decisions
- Build shared vocabulary

### During Review

- Respond to all comments
- Do not treat feedback as a personal criticism
- Ask for clarification if unclear
- Update code or explain why not
- Re-request review after changes

---

## Reviewer Responsibilities

### How to Review

1. **Understand the context**. Read the PR description and linked ticket.
2. **Check correctness**. Confirm the requested behavior. Test the important edge cases.
3. **Check quality**. Review architecture, conventions, readability, and maintenance cost.
4. **Check security**. Check for validation gaps, authorization errors, and leaked sensitive data.
5. **Check tests**. Confirm that tests cover the behavior and protect against regressions. Read CI's own check-run result for the head SHA first. Run only the tests for changed files plus a fail-before proof for each new test. Check a sample of the builder's pasted evidence. Do not reproduce all of it (see `.claude/rules/pr-quality.md` § "Builder Evidence").

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
- [ ] Functions are small and have one purpose
- [ ] No code duplication
- [ ] No dead code
- [ ] Comments explain why, not what
- [ ] Review the Fallow static-analysis results (JS/TS): dead code, unused exports/dependencies, duplication, circular dependencies, and high complexity. Findings are advisory. Rex runs Fallow automatically on JS/TS diffs when the `fallow` CLI is available. See `.claude/agents/code-reviewer.md` § 9.

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
| UI change | 1 + UI Designer (routine design gate, the human approver on escalation) |
| Architecture change | Solution Architect review (Tariq) + the human approver |
| External contribution (any files) | Full code review (Rex) + full security review (Hakim). See below. |

### External contributions

An external contributor is a PR author outside the repository owners, members, and collaborators. Bots do not count as external contributors.
Run a full code review and a full security review for every external contribution.
Do not reduce the scope of either review.
Apply both reviews to every file the diff touches.
A forge UI approval does not replace either review.
The per-PR human merge approval still applies.
Allow a delta re-review after the contributor pushes a fix.
Keep the first review from Rex full.
Keep the first review from Hakim full.

---

## Handling Disagreements

1. **Discuss**. Try to understand each other's perspective.
2. **Provide evidence**. Reference principles, docs, and data.
3. **Escalate if needed**. The Tech Lead decides.
4. **Accept the decision**. Follow the decision after agreement.

---

## Anti-Patterns

| Anti-Pattern | Problem | Instead |
|--------------|---------|---------|
| Rubber stamping | No real review | Read the code |
| Nitpicking everything | Slows down, frustrates | Focus on what matters |
| Blocking for style | Automate with linter | Use automated checks |
| Personal attacks | Toxic culture | Critique code, not person |
| Huge PRs | Hard to review well | Keep PRs < 400 lines |

---

## Metrics

Track these to improve:

- PR size (aim for < 400 lines)
- Review time (aim for < 24h)
- Review cycles (cap at 2, see `.claude/rules/pr-workflow.md` § "A cap of two review rounds")
- Post-merge bugs (aim for < 5%)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*

## Severity and repeated reviews

See [severity reviews and drive-to-green](../docs/skills/drive-to-green.md).
Use the loop for one PR. Keep all existing approval gates.
