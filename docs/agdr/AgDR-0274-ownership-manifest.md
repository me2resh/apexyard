---
id: AgDR-0274
timestamp: 2026-10-25T06:00:00Z
agent: platform-engineer
model: claude-opus-5-5
session: n/a
trigger: user-prompt
status: executed
category: architecture
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Ownership manifest for drift-safe updates

> In the context of updates to adopter ops repos, facing local edits that a sync can overwrite or keep silently, I decided to ship a per-release ownership manifest with a first-match glob list and a bash library that reads it, to achieve one source of truth for who owns each path, accepting a restricted YAML subset and a new CI check.

## Context

An update must keep an adopter's edits, or stop clearly. To do that, the update must know who owns each path. Today `/update` merges the full upstream history and asks about each conflict file. It has no rule that says "never touch this path" or "this file is a gate". A repo made from a template (#1885) has no shared history, so a plain `git merge` cannot run there.

Three tools need the same answer: the update engine (#1887), `apexyard update` (#1885) and `apexyard migrate` (#1886).

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Hard-code the classes in each tool | No new file | Three copies drift. A new path has no class and no check. |
| `.gitattributes` with a custom attribute | Git reads it with `git check-attr` | Adopters edit `.gitattributes` for their own needs. A missing attribute is silent. No security flag without a second attribute. |
| Ownership manifest (YAML subset, first match wins) and `bin/_lib-ownership.sh` | One file per release. One library for all callers. CI can fail on an unmatched path. A security flag fits on the same rule. | A small parser in awk. Only a fixed YAML subset is valid. |
| Full YAML with `yq` | Any YAML shape | New dependency on every adopter machine and in each hook. |

## Decision

Chosen: **the ownership manifest at `.claude/ownership-manifest.yaml`, read only through `bin/_lib-ownership.sh`**, because it gives one answer to all three tools, needs no new dependency, and lets CI refuse a path with no owner.

Rules:

- Each rule has a glob, an owner (`framework`, `adopter` or `shared`) and an optional `security: true`.
- The first matching glob wins.
- There is no catch-all rule. A new top-level path fails `bin/check-ownership-manifest.sh` until a rule covers it.
- An update changes only paths that the framework ships. A local path that the framework does not ship is never touched, whatever its class.
- Gate files carry `security: true`. They are `.claude/hooks/**`, `.githooks/**`, `.claude/settings.json`, `bin/run-pre-push-checks.sh`, `bin/run-configured-pre-push-checks.sh`, `bin/install-git-hooks.sh`, `.cursor/hooks.json`, and the `gate-dispatcher.ts` file in each of the opencode and pi harness adapters.
- `.github/workflows/**` is shared with no security flag, because the adopter owns their CI.

## Consequences

- A contributor who adds a new top-level path must add a manifest rule in the same PR. CONTRIBUTING.md says so.
- The workflow `ownership manifest` runs on every PR, including docs-only PRs.
- The library accepts only the YAML subset in the manifest header. A richer shape is an error, not a silent misread.
- `.claude/agents/**` is framework-owned. The agent-routing sync edits model lines in these files. The update engine accepts upstream for the `model:` line that agent-routing names. The SessionStart hook applies the override again, so the drift report does not count it.

## Artifacts

- me2resh/apexyard#1887 (step 1: manifest, library, CI check)
