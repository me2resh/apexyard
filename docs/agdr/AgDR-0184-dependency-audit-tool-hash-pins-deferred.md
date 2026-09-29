---
id: AgDR-0184
timestamp: 2026-09-29T12:00:00Z
agent: platform-engineer
model: composer
session: cursor-1359-rex-fixes
trigger: user-prompt
status: executed
category: security
projects: [apexyard]
---

<!-- Uses the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Defer --require-hashes for dependency-audit tool pins

> In the context of #1359 and AgDR-0176 L76, facing version-only tool pins
> in `dependency-audit-tools.requirements.txt`, I decided to keep direct
> version pins, install from that pin file in CI, and defer hash pins to a
> follow-up. This keeps the trusted-tool install path explicit without
> blocking the fail-closed scanner fixes.

## Context

- AgDR-0176 requires pinning direct versions and transitive distributions
  with hashes in the implementation tooling lock.
- PR #1469 shipped version pins for `pip-audit==2.10.0` and
  `packaging==25.0` without hash lines.
- The workflow previously ran inline `pip install 'pip-audit==…'` and did
  not read the pin file.
- Generating and maintaining `--require-hashes` lines needs a network
  capable refresh path. That work is separate from the B1–B5 fail-closed
  corrections.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Block merge until hashes land | Meets AgDR-0176 L76 fully | Blocks correctness fixes for clean-false scans |
| Keep version pins, install from the pin file, record the deviation (chosen) | Makes the pin file authoritative for CI. Records the debt. | Transitive tools can still float until hashes land |
| Drop the pin file and keep inline versions | Smaller copy procedure | Hides the AgDR-0176 requirement and drifts from docs |

## Decision

Chosen: **version pins in `dependency-audit-tools.requirements.txt`, CI
installs with `pip install -r …`, hashes deferred**.

Reasons:

1. The pin file is the single install source for the Python audit job.
2. A comment in the requirements file states that hashes are a follow-up.
3. This AgDR records the intentional deviation from AgDR-0176 L76.
4. A later change should add `--generate-hashes` output and switch CI to
   `pip install --require-hashes -r …`.

## Consequences

- CI no longer invents package versions beside the pin file.
- Hash integrity for transitive audit tools remains open until the
  follow-up.
- Adopters who copy the workflow must also copy
  `dependency-audit-tools.requirements.txt`.
- Reports still record `helper_revision` and required tool versions.

## Artifacts

- `golden-paths/pipelines/scripts/dependency-audit-tools.requirements.txt`
- `golden-paths/pipelines/dependency-audit.yml` (install from pin file)
- `docs/agdr/AgDR-0176-dependency-audit-ecosystem-dispatch.md` (parent decision)
- Issue #1359 / PR #1469
