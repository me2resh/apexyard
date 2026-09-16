# AgDR-0155: Portfolio-wide harness adapter management

> Repositories in this portfolio can use different AI coding harnesses.
> Adapter installation and drift lack a portfolio-level signal.
> I decided to manage adapters from the portfolio registry.
> The framework hooks remain the single enforcement source.
> This gives repositories consistent governance.
> It accepts per-harness trust setup and Cursor's current partial enforcement.

## Context

Claude Code loads ApexYard hooks natively. Codex, pi, opencode, and Cursor require harness-specific adapter files. Existing installers and `/update` reconciliation operate on one repository at a time. A registered portfolio can therefore contain missing or stale adapters without a portfolio-level signal.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Copy the full hook implementation into each repository | Works without a shared path | Duplicates security-critical logic and creates drift |
| Central portfolio manager with registry-driven install and drift checks | Keeps one hook source and gives operators one audit surface | Requires repository access and harness-specific trust setup |
| GitHub-only bot enforcement | Centralised PR visibility | Cannot enforce local tool calls and requires a separate review service |

## Decision

Chosen: **registry-driven adapter management with shared hook delegation**. This preserves one audited hook implementation while covering each registered repository. Onboarding installs declared adapters. `/update` reconciles installed adapters. A read-only portfolio check reports missing or stale output. Capability status remains explicit: full for Claude Code, Codex with trust, pi with `-a`/`--approve`, and opencode with `--auto`. Cursor remains partial until delegated execution is live-proven.

## Consequences

- Adapter output remains generated and must not become a second source of truth.
- Portfolio checks need safe handling for missing workspaces and unavailable harness CLIs.
- The registry needs an optional harness declaration with backward-compatible defaults.
- CI can verify adapter presence and drift but cannot replace an interactive Rex runtime without a separate service.

## Artifacts

- Framework feature issue: https://github.com/me2resh/apexyard/issues/1286
