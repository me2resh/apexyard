# AgDR-0175 - Dependency audit ecosystem dispatch

> In the context of issue #1359, facing an npm-only dependency audit across the skill, agent, and CI template, I propose a finite ecosystem runner map for npm and Python to achieve honest mixed-repository coverage, accepting that other ecosystems wait for later tickets.

**Status**: Proposed
**Recorded at**: 2026-09-27T20:56:20.151247+00:00

## Context

- `/audit-deps`, Munir, and `golden-paths/pipelines/dependency-audit.yml` currently describe npm-only behavior.
- Issue #1359 asks for Python support across all three layers.
- The issue comment asks for a design choice before code.
- `/mutation-test` already uses language detection, a runner map, and `--language`.
- Python support introduces new external tool and CI behavior.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Hardcode a Python branch | Smallest first diff. | Duplicates logic and does not match `/mutation-test`. |
| Finite runner map for npm and Python | Mirrors existing framework pattern. Keeps scope bounded. | Requires shared normalization rules. |
| Universal plugin loader | Extensible for many ecosystems. | Too broad for #1359 and harder to review. |

## Decision

Chosen: **Finite runner map for npm and Python**, pending design approval.

The runner map is the right first-pass shape because `/mutation-test` already uses it.
It keeps the implementation small.
It also avoids a generic plugin API before there are three working ecosystems.

## Consequences

- `/audit-deps` gains ecosystem detection and `--language`.
- Munir must stop assuming npm remediation commands.
- The CI template must wake for Python dependency files.
- Mixed repositories get one combined report.
- Unsupported ecosystems are named as not scanned.
- Python fallback to OSV is limited to exact resolved versions.
- Incomplete scans remain visible and cannot imply a clean result.

## Review State

This record is proposed.
It does not approve the external integrations.
It needs Solution Architect review with the technical design.
It needs human merge approval before implementation starts.

## Artifacts

- Issue: #1359
- Technical design: `docs/designs/dependency-audit-ecosystems-technical-design.md`
- Related pattern: `docs/agdr/AgDR-0045-mutation-test-skill.md`
- Supporting source: https://github.com/pypa/pip-audit
- Supporting source: https://google.github.io/osv.dev/post-v1-querybatch/
- Supporting source: https://spdx.org/licenses/
