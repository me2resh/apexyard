---
name: security-review
description: Security-focused PR review for vulnerabilities and best practices. Invokes the Security Reviewer agent (Shield).
disable-model-invocation: true
argument-hint: "<pr-number> [repo]"
allowed-tools: Bash, Read, Grep, Glob
---

# /security-review — Security Review

Review a pull request specifically for security vulnerabilities and best practices.

## Activated agent + role

When `/security-review` runs:

1. **Primary reviewer**: the **Security Reviewer agent (Shield)** at [`.claude/agents/security-reviewer.md`](../../agents/security-reviewer.md) — runs the automated security checklist.
2. **Human approval gate**: the **[Security Auditor](../../../roles/security/security-auditor.md)** role — activates on any PR that touches auth / crypto / secrets / user data / PII, or when `/security-review` is explicitly invoked.
3. **Escalation for strategic calls**: the **[Head of Security](../../../roles/security/head-of-security.md)** — threat modelling, compliance decisions, or novel attack surfaces.
4. **For active testing**: the **[Penetration Tester](../../../roles/security/penetration-tester.md)** — exploit discovery, API security review, pre-release security sign-off.

See [`.claude/rules/role-triggers.md`](../../rules/role-triggers.md) for the full activation protocol.

## Usage

```
/security-review 42
/security-review 42 your-org/your-repo
```

## When to Use

Invoke for PRs that touch:

- Authentication / authorisation
- User input handling
- API endpoints
- Data storage
- Third-party integrations
- Cryptography or secrets

## Security Checklist

### Secrets & Credentials
- No hardcoded secrets, API keys, or passwords
- Environment variables for sensitive data
- No secrets in logs or error messages

### Injection Prevention
- Parameterised queries (no SQL injection)
- No command injection
- No template injection

### XSS Prevention
- User input sanitised before rendering
- No unsafe `dangerouslySetInnerHTML`
- No `eval()` with user input

### Authentication & Authorisation
- Auth checks on protected routes
- Authorisation verified before data access
- Secure session management

### Data Protection
- Sensitive data encrypted
- No PII in URLs or query strings
- Proper validation and sanitisation

### API Security
- Rate limiting considered
- Input validation on endpoints
- No stack traces exposed
- CORS configured correctly

## Severity Levels

| Level | Action |
|-------|--------|
| CRITICAL | Block PR immediately |
| HIGH | Block PR, require fix |
| MEDIUM | Warn, recommend fix |
| LOW | Informational |

## Output

Posts a GitHub review with:

- Commit SHA
- Security checklist results
- Issues with severity
- Verdict

Invokes: Security Reviewer Agent (Shield)
