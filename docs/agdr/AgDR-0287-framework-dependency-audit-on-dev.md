---
id: AgDR-0287
timestamp: 2026-11-05T06:49:50Z
agent: claude
model: claude-opus-5-5
trigger: user-prompt
status: executed
---

# Run the framework's own dependency audit on pull requests to dev

> In the context of the framework repo gaining npm lock files and hash-pinned pip requirements, facing a dependency-audit job that still reported "N/A" and Dependabot alerts that cover only `main`, we decided to run the golden-path dependency audit on pull requests and pushes to `dev` through one reusable workflow, to achieve early detection of HIGH and CRITICAL dependency findings, accepting one more CI job on each PR.

## Context

- `security-scan.yml` had a `Dependency audit (N/A)` stub. The repo now has `harness-adapters/pi/package-lock.json`, `harness-adapters/opencode/package-lock.json` and `golden-paths/pipelines/scripts/dependency-audit-tools.requirements.txt`.
- Dependabot alerts cover only the default branch, `main`. A vulnerable dependency on `dev` stays invisible until a release. In early November 2026, the undici and certifi fixes sat unseen on `dev` for this reason.
- Security Scan runs on release, tag push and manual dispatch only. Its gitleaks and Semgrep jobs are release-gated on purpose.
- The framework ships its own audit golden path: `golden-paths/pipelines/dependency-audit.yml` and `scripts/dependency-audit.py`.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Reusable `dependency-audit.yml` on PRs and pushes to `dev`, also called by Security Scan | One copy of the audit steps. Security Scan stays release-gated. The release gate still includes the audit | One more workflow file |
| B. Add PR triggers to the whole Security Scan workflow | No new file | Gitleaks and Semgrep then run on every PR. Semgrep fails on WARNING and above, so existing findings can turn every PR red |
| C. Add a pinned Trivy filesystem scan | Covers many ecosystems | A second scanner to maintain. Does not exercise the framework's own audit tool |
| D. Keep the stub, rely on Dependabot | No work | `dev` stays unaudited until each release |

## Decision

Chosen: **A**, because it audits `dev` on every PR with the framework's own tool, keeps the release-gated scans unchanged, and keeps one copy of the audit steps. The job installs the audit tools in an isolated venv with `--require-hashes`, stages only the three dependency sets so test fixtures are not audited, fails on HIGH and CRITICAL, and reports MODERATE and LOW in the step summary.

## Consequences

- Every PR to `dev` runs one more Linux job. No macOS runner.
- A PR that adds or keeps a HIGH or CRITICAL dependency finding fails until the dependency is fixed.
- A new dependency manifest in the repo needs a line in the staging step, or the audit does not see it.
- The Security Gate on releases now fails when the dependency audit fails.

## Artifacts

- Issue: me2resh/apexyard#1967
