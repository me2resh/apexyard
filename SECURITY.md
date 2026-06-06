# Security Policy

ApexYard is a framework of plain markdown, shell hooks, and CI templates — it
ships no runtime service and has no package dependencies. Its security surface
is (1) the shell hooks that run on a contributor's machine, (2) the CI workflows
in this repo, and (3) the example configs/templates adopters copy. We take all
three seriously and dog-food the strongest version of the tooling we ship.

## Supported versions

The framework uses a release-cut model (`dev` → `main`, tagged with semver).
Security fixes land on `dev` and ship in the next release. Only the latest
released minor is supported; please upgrade (`/update`) before reporting.

| Version | Supported |
|---------|-----------|
| Latest released minor (`main`) | ✅ |
| Older tags | ❌ — upgrade first |

## Reporting a vulnerability

**Do not open a public issue for a security vulnerability.**

Use GitHub's private vulnerability reporting:
**Security → Report a vulnerability** on https://github.com/me2resh/apexyard
(the "Report a vulnerability" button under the Security tab). This opens a
private advisory only the maintainers can see.

Please include:

- What the issue is and the security impact (e.g. a hook that can be bypassed,
  a workflow that leaks a token, an example template that ships a real secret).
- Steps to reproduce, and the affected file(s) / version.
- Any suggested remediation.

We aim to acknowledge within **5 business days** and to ship a fix or a
mitigation plan within **30 days** for confirmed issues, coordinating disclosure
with you.

## Scope

In scope:

- Hook bypasses that defeat a documented gate (merge gate, ticket-first,
  secrets/onboarding/leak guards).
- CI workflow weaknesses (injection, excessive `GITHUB_TOKEN` scope, unpinned
  actions, artifact poisoning).
- Secrets or filled-in private config shipped in the repo, an example template,
  or a release artifact.

Out of scope:

- Vulnerabilities in a fork's *own* managed-project code (report those in that
  project's tracker).
- Social-engineering of maintainers; issues requiring a malicious local actor
  who already has commit access.

## Our own scanning

This repo runs, on itself: gitleaks (full-history secret scan), Semgrep
(`r/bash`), CodeQL (`actions` + `javascript-typescript`), OSSF Scorecard,
Dependabot (GitHub Actions), a release-artifact content guard, and the
commit-time `check-secrets.sh` / `block-onboarding-in-git.sh` /
`block-private-refs-in-public-repos.sh` hooks. See
`.github/workflows/security-scan.yml` and `docs/agdr/AgDR-0065-framework-security-hardening.md`.
