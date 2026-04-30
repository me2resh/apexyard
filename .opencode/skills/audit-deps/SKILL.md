---
name: audit-deps
description: Audit dependencies for vulnerabilities, outdated packages, and license compliance.
disable-model-invocation: true
argument-hint: "[project-path]"
allowed-tools: Bash, Read, Grep, Glob
---

# /audit-deps — Dependency Audit

Audit project dependencies for security vulnerabilities, outdated packages, and license compliance.

## Usage

```
/audit-deps
/audit-deps path/to/project
```

## What It Checks

### 1. Vulnerability Scan

```bash
npm audit --json
```

| Severity | Action |
|----------|--------|
| Critical | Immediate ticket, block deploys |
| High | Ticket this week |
| Moderate | Ticket this sprint |
| Low | Track in backlog |

### 2. Outdated Packages

```bash
npm outdated --json
```

- Major version behind → review breaking changes
- Minor version behind → schedule update
- Patch behind → update ASAP

### 3. License Compliance

- **Allowed**: MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC, CC0-1.0, 0BSD, Unlicense
- **Restricted (require approval)**: GPL-2.0, GPL-3.0, LGPL, AGPL, MPL, CDDL
- **Banned**: UNLICENSED, Unknown, Proprietary

### 4. Dependency Health

- Abandoned packages (no updates > 2 years)
- Low download counts
- No maintainer activity
- Known malicious packages

## Output

Generates a report with:

- Vulnerability summary by severity
- Critical / High vulnerability details with CVE
- Outdated packages list
- License issues
- Recommendations

Optionally creates tickets in the team's tracker for Critical / High vulnerabilities.

Invokes: Dependency Auditor Agent (Guardian)
