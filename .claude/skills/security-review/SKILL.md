---
name: security-review
description: Security-focused PR review for vulnerabilities and best practices. Invokes the Security Reviewer agent (Shield).
disable-model-invocation: true
argument-hint: "<pr-number> [repo]"
allowed-tools: Bash, Read, Grep, Glob
---

# /security-review — Security Review

Review a pull request specifically for security vulnerabilities and best practices.

## LSP-aware (optional, recommended)

This skill performs semantic code navigation — finding definitions, walking references, tracing handlers across modules. With LSP enabled (`ENABLE_LSP_TOOL=1` + per-language plugin per `docs/getting-started.md`), queries are ~3-15× cheaper in token cost than grep + Read. Without LSP, the skill falls back to grep + Read transparently — no new failure mode, just optional speed.

Per-language LSP plugins live in Claude Code's marketplace. Install once; the skill detects the active language and dispatches automatically.

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

## Persist the run + render trend

After the Security Reviewer agent posts the GitHub review, persist a structured artefact via the shared audit-history lib so the security-review trend across PRs becomes legible. See `docs/agdr/AgDR-0019-audit-artefact-persistence.md` for the schema rationale.

### 1. Resolve project name + score + verdict

`<project-name>` is the project's registered name in `apexyard.projects.yaml`, derived from the PR's repo. If the project isn't registered, use the basename of the repo and tell the operator to `/handover` it for cross-machine trend continuity.

Compute a single headline score from the severity distribution of the findings in the review:

```
score = max(0, 100 - 25*critical - 10*high - 3*medium - 1*low)
```

Compute the verdict by the worst-severity rule:

| Worst severity present | Verdict |
|---|---|
| critical or high       | `fail` |
| medium only            | `conditional` |
| low only / none        | `pass` |

### 2. Build payload + body, persist via the lib

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-audit-history.sh"

# Lowercase severity in the payload — the lib's stats derivation expects
# critical / high / medium / low / info. The visible review on the PR
# can use whatever capitalisation reads best.
payload=$(mktemp); cat > "$payload" <<'EOF'
{
  "schema_version": 1,
  "findings": [
    {"id": "F1", "severity": "critical", "status": "open", "summary": "Unsanitised user input in SQL"},
    {"id": "F2", "severity": "high",     "status": "open", "summary": "JWT signature not verified"}
  ]
}
EOF

# Body: a markdown summary of the security review for this PR, formatted
# per templates/audits/security-review.md. Include the diff scope, findings
# table, dependency vulnerabilities, secrets-scan results, and recommendations.
body=$(mktemp); cat > "$body" <<'EOF'
## Scope

PR <number>; reviewed `<branch>..main` (X files, Y +/- lines).

## Findings

| # | Severity | OWASP class | Finding | File:Line | Status |
|---|---|---|---|---|---|
| F1 | critical | A03 Injection | Unsanitised user input concatenated into SQL | `src/users.ts:42` | open |
| F2 | high | A07 Auth failure | JWT signature not verified | `src/auth.ts:18` | open |

## Dependency vulnerabilities

(... output of `npm audit` or `pip audit` for critical+high ...)

## Secrets scan

(... checks per templates/audits/security-review.md ...)

## Recommendations

1. F1 — fix injection vector before merge
2. F2 — verify JWT signatures
EOF

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
audit_run_persist "<project-name>" "security-review" "$ts" "fail" 50 "$body" < "$payload"
rm -f "$payload" "$body"
```

### 3. Render the trend section

```bash
audit_render_trend "<project-name>" "security-review" 5
```

- < 2 prior runs → silent (no trend section). Don't append anything.
- ≥ 2 prior runs → prints a markdown trend block (heading + table + ASCII chart of `score` over time) to stdout. Append it to this run's MD artefact so the PR-by-PR security trend is visible.

### 4. Opt-in commit (history-tracked marker)

By default the dimension's runs/ JSON files are gitignored. The lib applies a `.gitignore` based on the presence of the marker:

```bash
# Opt in to commit security-review history for this project
touch projects/<name>/audits/security-review/.audit-history-tracked
```

The MD artefacts at `<dim_dir>/<ts>.md` are committed regardless — they are the durable human-readable artefact of every PR's security review.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
