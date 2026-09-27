# Technical Design: Dependency Audit Ecosystem Dispatch

**Status**: In Review
**Date**: 2026-09-27
**Requirements**: issue #1359, including its design-direction comment.
**Decision record**: [AgDR-0175](../agdr/AgDR-0175-dependency-audit-ecosystem-dispatch.md).

## Overview

Extend dependency audits to npm and Python through a finite runner map.
Update the skill, Munir's agent instructions, and the CI template together.
The operator selected the existing `/mutation-test` dispatch pattern.
Other ecosystems, private indexes, and resolution of unpinned transitive dependencies remain outside this first pass.
Implementation starts after the design gate passes.

An ecosystem is a package registry and its dependency tooling.
A manifest declares dependencies. A lockfile records resolved versions.

## Architecture

### Runner map and discovery

| Ecosystem | Detection | Vulnerabilities | Outdated packages | Licences |
|---|---|---|---|---|
| npm | `package.json` | `npm audit --json` | `npm outdated --json` | `license-checker --json` |
| Python | `requirements*.txt`, `pyproject.toml`, `Pipfile`, `Pipfile.lock`, `poetry.lock`, `uv.lock` | `pip-audit`, otherwise OSV | Exact-version PyPI metadata comparison | Installed metadata or version-specific PyPI metadata |

Use manifest detection, rather than source-file counts, to select runners.
Search the selected project tree, excluding dependency, virtual environment, generated output, and Git directories.
Group related manifests and lockfiles by project directory.
Do not scan a manifest and its lockfile as independent dependency sets.
List both paths under their shared result.

Default to every detected supported ecosystem.
Support `--language=npm|python` as an explicit filter.
Reject unknown values. Report detected ecosystems excluded by the filter.
For known unsupported manifests, report their paths as not scanned.
Do not add a dynamic plugin loader.

### Python inputs

Collect exact package names and versions before advisory queries.
Select one resolved dependency set per Python project directory.
Prefer its lockfile, then pinned requirements files.
List alternate dependency groups separately when they resolve different versions.

- Read exact requirements pins without installing project packages.
- Evaluate environment markers against the recorded Python version and platform.
- Follow local requirements includes only inside the project root.
- Preserve extras and constraints when determining coverage.
- Use available Poetry, uv, or Pipenv export commands for their lockfiles.
- Never regenerate a lockfile during an audit.
- Report unavailable exporters, unresolved constraints, VCS dependencies, and private-index dependencies as incomplete.
- Do not audit the audit tool's environment as a substitute for project dependencies.

An exact requirements list covers only the dependencies that it enumerates.
The report must distinguish declared-package coverage from a resolved transitive dependency set.
A package range without a resolved version cannot establish vulnerability absence.

### Vulnerability runners

For an exact requirements export, use `pip-audit -r <file> --no-deps --disable-pip -f json`.
Use a temporary export outside the project files.
Prefer an installed `pip-audit`. Document its supported version and installation command.
If it is absent, query OSV directly for the same exact package set.
A scanner failure must remain visible. Do not silently convert it into a clean fallback result.

OSV is the Open Source Vulnerabilities advisory service.
Send package name, ecosystem `PyPI`, and exact version to `POST https://api.osv.dev/v1/querybatch`.
Follow pagination and fetch each advisory's full record through `/v1/vulns/{id}`.
Batch responses alone do not supply the complete severity and remediation information.
Use bounded timeouts and retries. Preserve an incomplete result after exhausted retries or malformed responses.

### Severity normalization

| Evidence | Report severity |
|---|---|
| npm `critical`, `high`, `moderate`, `low` | Critical, High, Medium, Low respectively |
| Recognized OSV severity label | Map `MODERATE` to Medium and preserve the other matching levels |
| Valid CVSS score | Critical 9.0–10.0, High 7.0–8.9, Medium 4.0–6.9, Low above 0 and below 4.0 |
| Missing, unsupported, conflicting, or unparseable severity | Unknown, with its reason |

CVSS is the Common Vulnerability Scoring System.
Use the highest valid supported score when an advisory supplies several scores.
Use a documented CVSS parser rather than treating a vector as a numeric score.
Never guess severity from an advisory title or vulnerability identifier.
Unknown vulnerabilities require manual triage and remain visible in totals.

### Licences and outdated packages

Preserve each package's exact version, metadata source, and raw licence claim.
Prefer `License-Expression`, then `License`, then `License ::` classifiers.
Use version-specific PyPI metadata when matching local distribution metadata is unavailable.
Never substitute the latest release's licence for the audited version's licence.

SPDX identifiers name licences. SPDX expressions combine licences with `AND`, `OR`, or exceptions.
Retain the current allowed SPDX identifiers.
Use current SPDX identifiers for restricted copyleft licences, including `-only` and `-or-later` variants.
Require review for a restricted expression or an exception that the policy does not classify.
Do not classify an expression through substring matching alone.
Treat an explicit no-grant or proprietary claim as blocked by the framework's existing policy.
Treat missing or unclassifiable metadata as Unknown and require review.
Do not invent an SPDX identifier from a classifier or ambiguous legacy licence text.

For Python outdated checks, compare exact versions with public PyPI release metadata.
Exclude yanked and prerelease candidates by default.
Record Python compatibility constraints and missing comparison tooling.
Report unknown comparisons explicitly. Do not apply npm's version-segment rules to Python versions.
Recommend updates through the project's package manager and lockfile workflow.
Never emit `npm update` for a Python package or mutate dependencies during the audit.

### Report contract

Produce one report containing per-directory dependency sets and per-ecosystem sections.
Record every detected manifest, selected runner, coverage boundary, and check status.
Use `complete`, `incomplete`, `failed`, or `excluded` for each check.
Only a successful zero-finding check within its stated coverage can report no known findings.
Incomplete or failed checks cannot produce a clean overall verdict.

Deduplicate totals by ecosystem, normalized package name, exact version, and advisory identity.
Merge advisory aliases when their equivalence is established.
Retain every affected manifest path after deduplication.
Different package versions remain separate findings.
Include Critical, High, Medium, Low, and Unknown totals across ecosystems.
Keep licence and outdated counts separate from vulnerability totals.

### CI template

Retain scheduled and manual runs. Expand push and PR filters to nested npm and Python dependency files.
Detect all supported manifests before selecting ecosystem jobs.
Select jobs from the repository contents, rather than only the changed-file ecosystem.
Keep npm audits active on mixed repositories.
Skip irrelevant runtime setup when an ecosystem is absent.

Keep the copied template self-contained. Do not require a checkout of the ApexYard framework.
Pin action references by full commit SHA and document audit-tool versions.
Retain least-privilege permissions and avoid executing project install scripts during inventory collection.
Upload per-manifest JSON evidence and combine it into the report.
Run the summary step even after a scan fails.
A scan failure or incomplete selected input must fail the workflow after the summary.
Retain critical-vulnerability failure and high-vulnerability issue behavior across both ecosystems.
Include ecosystem and manifest context in deduplicated tracking issues.

## Implementation Plan

| Step | Files and result | Dependency |
|---|---|---|
| 1 | `.claude/skills/audit-deps/SKILL.md`: detection, runner map, input contracts, report, and remediation. | Approved design |
| 2 | `.claude/agents/dependency-auditor.md`: ecosystem triggers, triage, licences, and report examples. | Step 1 |
| 3 | `golden-paths/pipelines/dependency-audit.yml`: filters, conditional scans, evidence, summary, and thresholds. | Step 1 |
| 4 | Focused audit fixtures and workflow checks. | Steps 1–3 |

Keep each implementation PR tied to #1359.
Do not introduce additional ecosystem support in this ticket.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| An unresolved package appears safe. | Preserve incomplete coverage and fail CI after reporting. |
| Several manifests duplicate findings. | Group dependency sets and deduplicate advisory aliases while retaining affected paths. |
| Advisory or metadata service fails. | Bound retries and preserve failed-check evidence. |
| Licence claims differ across releases. | Query the audited version and preserve the raw claim. |
| A copied template depends on the framework checkout. | Keep all required runtime logic inside the copied workflow. |

Rollback restores the three existing files and removes the new audit tests.
No production data or dependency lockfiles change during rollout.

## Security Considerations

Public advisory queries disclose package names and exact versions to OSV or PyPI.
Document that network boundary before an audit.
Do not send credentials, private index URLs, or project source files.
Never install an audited project merely to enumerate its dependencies.
Treat package names, paths, advisory text, and metadata as untrusted input.
Use structured subprocess arguments and serialize JSON rather than interpolating shell commands.
Treat reports and tracking issues as evidence, not permission to deploy.

## Testing Strategy

| Fixture | Required evidence |
|---|---|
| npm-only, Python-only, mixed, nested manifests | Correct discovery, grouping, and runner selection |
| Language override and unsupported manifests | Accurate excluded and not-scanned paths |
| Exact pins, markers, includes, constraints, lockfiles | Correct versions or explicit incomplete coverage |
| Missing pip-audit, failed exporter, OSV outage, malformed response | Visible fallback or failure without a clean verdict |
| Batch pagination and advisory aliases | Full records and deduplicated combined totals |
| Severity labels, CVSS vectors, absent severity | Explicit mapped or Unknown severity |
| SPDX expressions, classifiers, missing licences | Correct disposition without fabricated identifiers |
| Python versions, prereleases, yanked releases | Ecosystem-aware outdated results |
| Conditional CI, thresholds, evidence upload | npm preservation and failure reporting |

Use local fake tool and HTTP responses for repeatable tests.
Do not require live advisories or credentials in regression tests.
Verify behavior with fixtures, rather than only matching documentation strings.

## Approvals

Architecture and human approval remain pending.
The issue supplies requirements, but its tracker hierarchy lacks the parent/story records required by the pre-build rule.
Reconcile those prerequisites before implementation.
This design does not declare the build gate satisfied.

## Sources

- Issue #1359 and its comments.
- [pip-audit usage and security model](https://github.com/pypa/pip-audit).
- [OSV API](https://google.github.io/osv.dev/api/).
- [PyPI JSON API](https://docs.pypi.org/api/json/).
- [Python core metadata](https://packaging.python.org/en/latest/specifications/core-metadata/).
- [SPDX License List](https://spdx.org/licenses/).
