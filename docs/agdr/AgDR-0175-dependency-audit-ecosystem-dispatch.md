---
id: AgDR-0175
timestamp: 2026-09-27T20:56:20Z
agent: codex
model: gpt-6
session: /root
trigger: user-prompt
status: proposed
category: integrations
projects: [apexyard]
---

<!-- Uses the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# AgDR-0175 - Dependency audit ecosystem dispatch

> In the context of #1359, facing incomplete dependency audits, I chose finite ecosystem dispatch and data-only Python inventory collection.
> This provides npm and Python coverage, accepting parser maintenance and public advisory queries.

## Context

- `/audit-deps`, Munir, and the CI template currently describe npm-only behavior.
- Issue #1359 requests Python coverage across all three layers.
- The reporter's issue comment requests a direction but does not select one.
- The operator's session request selects a feature that mirrors `/mutation-test`'s language dispatch.
- Python support introduces scanner, parser, metadata, and network dependencies.
- PR #1430 reviews 5332145898 and 5332140528 require this revision.

## Options Considered

### Dispatch shape

| Option | Pros | Cons |
|--------|------|------|
| Hardcoded Python branch | Small initial change. | Repeats detection and reporting rules. |
| Finite runner map | Matches `/mutation-test` and keeps scope bounded. | Requires common normalization and coverage rules. |
| Universal plugin loader | Supports arbitrary extensions. | Adds interfaces and executable plugin risk beyond #1359. |

### Python inventory, scanner, and advisory source

| Option | Pros | Cons |
|--------|------|------|
| Data-only inventory, pip-audit with OSV, direct OSV fallback | Preserves the requested pip-audit preference and one advisory source. Avoids package-manager execution. | Maintains lock readers and fallback pagination. Needs severity enrichment. |
| OSV-Scanner | Reads npm and Python lockfiles directly. One pinned binary can cover both ecosystems. | Adds binary distribution and report adaptation. Does not replace the existing outdated and licence checks. |
| Data-only inventory with direct OSV queries only | Few scanner dependencies. Controls coverage and avoids checkout execution. | Removes the requested pip-audit preference. Owns every advisory-client and parser behavior. |
| Package-manager exporters with pip-audit | Reuses package-manager interpretation. | Plugin startup, relocking, network resolution, and builds increase the untrusted-checkout attack surface. |

OSV-Scanner supports `package-lock.json`, `requirements.txt`, `poetry.lock`, `uv.lock`, and `Pipfile.lock`.
Its documented support makes it a credible alternative, rather than an unavailable option.

## Decision

Chosen: **finite ecosystem dispatch with data-only inventory, pip-audit using OSV, and a direct OSV fallback**.
This is the choice because it preserves npm behavior and the scanner preference while preventing package-manager execution during Python inventory collection.

Parse `poetry.lock` and `uv.lock` as TOML data.
Parse `Pipfile.lock` as JSON data.
Read pinned requirements and static manifest declarations as data.
Never run Poetry, uv, or Pipenv inside the audited checkout.
Never load checkout plugins, regenerate locks, install target dependencies, or invoke build backends.
Unsupported lock schemas and unresolved entries produce incomplete coverage.

Use `pip-audit==2.10.0` with explicit `-s osv`, `--no-deps`, and `--disable-pip` on synthesized exact pins.
The default pip-audit service is PyPI, so explicit OSV selection prevents advisory-source drift.
When the trusted scanner is absent, use the direct OSV client on the same inventory.
A scanner failure remains failed and does not silently trigger a clean fallback.
Both paths fetch full OSV advisory records, including available GHSA and PYSEC aliases, before normalization.

Use `packaging==25.0` for Python requirements, markers, versions, and compatibility checks.
Use `cvss==3.6` for CVSS 2.0, 3.0, 3.1, and 4.0 vectors.
These libraries avoid custom implementations of their published formats.
The CVSS library declares LGPLv3+ and requires the existing restricted-licence approval before distribution or use.
Until approved and available, vector-only severity remains Unknown unless other recognized evidence supplies a severity.

Install audit tools outside the checkout in an isolated, trusted environment.
Pin direct versions and transitive distributions with hashes in the implementation's tooling lock.
Do not accept arbitrary installed versions or resolve tool binaries from the checkout.
Run the trusted Python interpreter with `-I` to exclude checkout imports and Python environment overrides.
Pin GitHub Actions by full commit SHA.
Record tool versions, helper revision, and parser availability in each report.

OSV queries disclose public package names and exact versions to `api.osv.dev`.
PyPI metadata calls disclose public package names and versions to `pypi.org`.
Trusted tool installation separately downloads pinned distributions from PyPI and `files.pythonhosted.org`.
Existing npm calls use the configured public npm registry.
Never send private-index entries, credentials, index URLs, or project source to these services.
No API key is required for OSV or public PyPI metadata.

Use 30-second HTTP deadlines, two retries, and batches of at most 100 queries.
Retry transient failures after one and two seconds within the overall deadline.
Use five-minute subprocess deadlines and a 20-minute overall audit deadline.
Apply these limits to OSV, PyPI, and npm metadata calls.
Follow OSV pagination until completion or the deadline.
Preserve findings and incomplete coverage when any limit expires.

Ship one shared helper beside the CI template.
The skill invokes that helper, and adopters copy the same version into their project.
This avoids independently maintained severity, licence, and deduplication implementations.
The helper records its revision so copied versions can be compared and refreshed.

## Consequences

- npm and Python audits share discovery, normalization, and reporting contracts.
- Untrusted checkout code does not run during Python inventory collection.
- Lock schema maintenance remains explicit debt, covered by fixtures and unsupported-schema failures.
- Copied helper versions can drift and need an adopter refresh when the framework changes them.
- Python transitive coverage requires resolved input rather than dependency resolution.
- Private indexes and other ecosystems remain outside this first pass.
- Unknown licence metadata changes from a banned label to a pending-review state.
- Pending licence review still prevents licence clearance, so Unknown never grants deployment permission.
- Missing tools, Unknown severity, incomplete coverage, and known vulnerabilities retain distinct outcomes.

## Review State

This decision is proposed for PR #1430 and covers the external-tool and advisory-source choices.
It does not authorize implementation, tool distribution, licence clearance, or merge.
New review markers must match the revised PR head.
Human merge approval and the design's tracker prerequisites remain separate gates.

## Artifacts

- Issue #1359 in this repository.
- [Technical design](../designs/dependency-audit-ecosystems-technical-design.md).
- [Existing mutation-test decision](AgDR-0045-mutation-test-skill.md).
- [pip-audit 2.10.0 usage and security model](https://github.com/pypa/pip-audit/blob/v2.10.0/README.md).
- [OSV-Scanner supported inputs](https://google.github.io/osv-scanner/supported-languages-and-lockfiles/).
- [OSV querybatch and pagination](https://google.github.io/osv.dev/post-v1-querybatch/).
- [PyPI metadata API](https://docs.pypi.org/api/json/).
- [packaging 25.0 metadata](https://pypi.org/pypi/packaging/25.0/json).
- [CVSS 3.6 formats and licence](https://pypi.org/pypi/cvss/3.6/json).
- [SPDX identifiers](https://spdx.org/licenses/).
