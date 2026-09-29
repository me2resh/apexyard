# Technical Design: Dependency Audit Ecosystem Dispatch

**Status**: Approved for implementation (PR #1430 design gate). Implemented on #1359.
**Date**: 2026-09-27
**Requirements**: issue #1359, including its design-direction comment.
**Decision record**: [AgDR-0176](../agdr/AgDR-0176-dependency-audit-ecosystem-dispatch.md).

## Overview

Extend dependency audits to npm and Python through a finite runner map.
Update the skill, Munir's agent instructions, and the CI template together.
The operator selected this pattern in the session request for #1359:

> A self-contained feature in /audit-deps that mirrors /mutation-test's language dispatch.

The reporter's issue comment asks for a direction. It does not record the operator's selection.
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
For npm workspaces, use the root package-lock graph for the root and its covered members.
List every member manifest under that root dependency set.
Audit a member separately only when it has an independent lock and dependency root.
Report uncovered members as incomplete. Do not require separate locks for covered members.
Do not scan a manifest and its lockfile as independent dependency sets.
List both paths under their shared result.

Default to every detected supported ecosystem.
Support `--ecosystem=npm|python` as an explicit filter.
Accept `--language=js|ts|python` as aliases and reject conflicting filters.
Support `--runner=npm|pip-audit|osv` only when it matches the selected ecosystem.
Read the finite runner map from project configuration.
Default to npm for Node and pip-audit with the documented OSV fallback for Python.
Reject arbitrary commands and plugin loaders in the map.
Reject unknown values. Report detected ecosystems excluded by the filter.
For known unsupported manifests, report their paths as not scanned.
A tooling-only `pyproject.toml` with no declared dependency groups records `not_applicable`, rather than incomplete coverage.
Dynamic dependency declarations remain incomplete unless a corresponding lock supplies resolved versions.

Ship one shared helper at `golden-paths/pipelines/scripts/dependency-audit.py`.
The skill invokes that helper. Adopters copy it beside the workflow as `.github/scripts/dependency-audit.py`.
Keep normalization in this helper rather than duplicating it inside workflow YAML.
Record the helper revision and scanner versions in the report.
Copied helpers can drift. Document the refresh procedure in the pipeline README.

### Python inputs

Collect exact package names and versions before advisory queries.
Select one resolved dependency set per Python project directory.
Prefer its lockfile, then pinned requirements files.
List alternate dependency groups separately when they resolve different versions.

- Read exact requirements pins without installing project packages.
- Evaluate environment markers against the recorded Python version and platform.
- Follow local requirements includes only inside the project root.
- Preserve extras and constraints when determining coverage.
- Parse `poetry.lock` and `uv.lock` directly as TOML data.
- Parse `Pipfile.lock` directly as JSON data.
- Never run Poetry, uv, or Pipenv in the audited checkout.
- Never load `.poetry/plugins`, project modules, or build backends.
- Validate supported lock schema versions before extracting packages.
- Never regenerate a lockfile during an audit.
- Report unsupported lock schemas, unresolved constraints, VCS dependencies, and private-index dependencies as incomplete.
- Do not audit the audit tool's environment as a substitute for project dependencies.

An exact requirements list covers only the dependencies that it enumerates.
The report must distinguish declared-package coverage from a resolved transitive dependency set.
A package range without a resolved version cannot establish vulnerability absence.

### Vulnerability runners

Build a temporary requirements file from the data-only inventory outside the checkout.
Use a trusted isolated audit environment containing `pip-audit==2.10.0`.
Invoke its interpreter with isolation enabled:

```text
<trusted-audit-python> -I -m pip_audit -r <temporary-pins> --no-deps --disable-pip -s osv -f json --timeout 30
```

Pass arguments as a subprocess array. Run from the trusted temporary directory.
Never select checkout-local executables or inherit `PYTHONPATH` and scanner service overrides.
Pin audit dependencies and their transitive distributions with hashes outside project-controlled configuration.
Record actual versions and reject mismatched tool installations.
AgDR-0176 compares this option with OSV-Scanner and direct OSV scanning.
If the preferred trusted scanner is absent, query OSV directly for the same exact package set.
An explicit `--runner=pip-audit` selection instead reports the missing tool and exits 3.
A scanner failure must remain visible. Do not silently convert it into a clean fallback result.

OSV is the Open Source Vulnerabilities advisory service.
Send package name, ecosystem `PyPI`, and exact version to `POST https://api.osv.dev/v1/querybatch`.
Follow pagination and fetch each advisory's full record through `/v1/vulns/{id}`.
Batch responses alone do not supply the complete severity and remediation information.
pip-audit JSON also lacks severity. Fetch full OSV records for its IDs and available GHSA and PYSEC aliases.
Deduplicate alias-connected records after enrichment. Preserve every source record and affected manifest.
Failed enrichment retains the finding with Unknown severity and a failed enrichment check.

| Bound | Default |
|---|---|
| Each HTTP request, including PyPI metadata | 30 seconds |
| Transient retries per request | Two retries after one and two seconds |
| OSV batch size | At most 100 queries |
| Scanner and npm subprocess | Five minutes |
| Overall audit | 20 minutes |

Retry connection failures, timeouts, HTTP 429, and HTTP 5xx within the remaining audit deadline.
Cap server-requested retry delays at 30 seconds. Do not retry malformed JSON or permanent HTTP failures.
Follow each OSV query's pagination token until exhausted. Detect repeated tokens and preserve an incomplete result.
Preserve available findings after any exhausted bound, timeout, or malformed response.

### Severity normalization

| Evidence | Report severity |
|---|---|
| npm `critical`, `high`, `moderate`, `low` | Critical, High, Medium, Low respectively |
| Recognized OSV severity label | Map `MODERATE` to Medium and preserve the other matching levels |
| Valid CVSS score | Critical 9.0–10.0, High 7.0–8.9, Medium 4.0–6.9, Low above 0 and below 4.0 |
| Missing, unsupported, or unparseable severity | Unknown, with its reason |
| Label and score disagree | Highest recognized severity, with conflict evidence retained |

CVSS is the Common Vulnerability Scoring System.
Use the highest valid supported score when an advisory supplies several scores.
Use `cvss==3.6` for CVSS 2.0, 3.0, 3.1, and 4.0 vectors.
Use each vector's base score. Never treat a vector string as a numeric score.
Compare recognized labels with mapped scores. The highest severity wins, including across equivalent advisory aliases.
A valid score of zero maps to Unknown with a zero-impact reason when no recognized label exists.
Retain invalid evidence and conflicts for triage. They cannot erase a recognized Critical finding.
The parser declares LGPLv3+ and needs restricted-licence approval before use or distribution.
Until approved and available, vector-only evidence stays Unknown unless another recognized source establishes severity.
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
This explicitly changes Unknown from the current banned label to pending review.
Pending review still blocks licence clearance. Unknown never becomes allowed by default.
Use exact recognized SPDX identifiers for automatic classification.
Compound expressions and exceptions require manual review in this first pass.
Do not invent an SPDX identifier from a classifier or ambiguous legacy licence text.

For Python outdated checks, compare exact versions with public PyPI release metadata using `packaging==25.0`.
Use that pinned library for requirement parsing, marker evaluation, version ordering, and Python compatibility.
Exclude yanked and prerelease candidates by default.
Record Python compatibility constraints and missing comparison tooling.
Report unknown comparisons explicitly. Do not apply npm's version-segment rules to Python versions.
Recommend updates through the project's package manager and lockfile workflow.
Never emit `npm update` for a Python package or mutate dependencies during the audit.

### Report contract

Produce one report containing per-directory dependency sets and per-ecosystem sections.
Record every detected manifest, selected runner, coverage boundary, and check status.
Use `complete`, `incomplete`, `failed`, `excluded`, or `not_applicable` for each check.
A tooling-only manifest records why dependency checks are not applicable.
Keep coverage status separate from findings and licence clearance.
Unknown vulnerabilities produce a needs-triage verdict rather than a clean verdict.

| Exit | Meaning |
|---|---|
| 0 | Complete selected checks, no Critical or Unknown vulnerability findings |
| 1 | Known Critical vulnerability findings |
| 2 | Invalid arguments or incompatible runner override |
| 3 | Missing selected tool, failed check, or incomplete selected coverage |
| 4 | Complete selected coverage with Unknown vulnerability findings |

Known Critical findings take precedence over other exit statuses, while coverage gaps remain visible.
Print per-ecosystem install advice when tools are missing. Never install them automatically during an operator audit.
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
Use read-only repository permissions for pull-request scans and disable persisted checkout credentials.
Prepare npm licence inventory with `npm ci --ignore-scripts` only for dependency roots with npm locks.
Installed packages support license-checker metadata extraction without lifecycle scripts.
Packages whose metadata requires generated artifacts remain incomplete rather than triggering scripts.
Python inventory collection never installs target packages or invokes exporters.
Install pinned trusted audit tools separately from inventory collection.
Install with `pip install --require-hashes -r dependency-audit-tools.requirements.txt`.
That file is a generated hashed lock for Python 3.12 on Linux x86_64 (AgDR-0194 / #1478).
Regenerate after changing a pin with:

```bash
uv pip compile --python-version 3.12 --python-platform x86_64-unknown-linux-gnu \
  --generate-hashes --no-header \
  -o golden-paths/pipelines/scripts/dependency-audit-tools.requirements.txt \
  golden-paths/pipelines/scripts/dependency-audit-tools.in
```

Upload per-manifest JSON evidence and combine it into the report.
Run the summary step even after a scan fails.
A scan failure or incomplete selected input fails the workflow after the summary by default.
Document `fail-on-incomplete` as an explicit adopter option, defaulting to true.
When disabled, retain an incomplete verdict and a visible CI warning. Never describe the scan as clean.
Upgrade notes must explain that unpinned Python requirements now fail coverage checks by default.
Retain critical-vulnerability failure and high-vulnerability issue behavior across both ecosystems.
Unknown severity emits a CI warning and a manual-triage issue, alongside the Unknown count.
Unknown alone does not trigger the Critical threshold. Its report remains needs-triage.
Include ecosystem and manifest context in deduplicated tracking issues.
Grant issue-write permissions only to a separate trusted default-branch job.
Read report JSON through files or environment variables in `actions/github-script`.
Never interpolate package names, paths, or advisory text into JavaScript source through expressions.

## Implementation Plan

| Step | Files and result | Dependency |
|---|---|---|
| 1 | `.claude/skills/audit-deps/SKILL.md`: detection, runner map, input contracts, report, and remediation. | Approved design |
| 2 | `.claude/agents/dependency-auditor.md`: ecosystem triggers, triage, licences, and report examples. | Step 1 |
| 3 | Shared runner, tooling lock, CI template, and README: conditional scans, evidence, summary, thresholds, and upgrade notes. | Step 1 |
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
| A copied template depends on the framework checkout. | Copy the versioned helper beside the workflow. |
| Copies drift from framework normalization. | Record helper revision and document the refresh procedure. |
| Lock schemas change. | Validate known versions and fail unsupported inputs explicitly. |

Rollback restores the three existing contracts and removes the shared helper, tooling lock, and new audit tests.
No production data or dependency lockfiles change during rollout.

## Security Considerations

Public advisory queries disclose package names and exact versions to OSV or PyPI.
Document that network boundary before an audit.
Do not send credentials, private index URLs, or project source files.
Never install Python target dependencies or run exporters to enumerate their versions.
The separate npm licence step installs its locked tree with lifecycle scripts disabled.
Treat package names, paths, advisory text, and metadata as untrusted input.
Use structured subprocess arguments and serialize JSON rather than interpolating shell commands.
Treat reports and tracking issues as evidence, not permission to deploy.

## Testing Strategy

| Fixture | Required evidence |
|---|---|
| npm-only, Python-only, mixed, nested manifests | Correct discovery, grouping, and runner selection |
| Language override and unsupported manifests | Accurate excluded and not-scanned paths |
| Exact pins, markers, includes, constraints, lockfiles | Correct versions or explicit incomplete coverage |
| Missing pip-audit, unsupported lock schema, OSV outage, malformed response | Visible fallback or failure without a clean verdict |
| Batch pagination and advisory aliases | Full records and deduplicated combined totals |
| Severity labels, CVSS vectors, absent severity | Explicit mapped or Unknown severity |
| SPDX expressions, classifiers, missing licences | Correct disposition without fabricated identifiers |
| Python versions, prereleases, yanked releases | Ecosystem-aware outdated results |
| Conditional CI, thresholds, Unknown, evidence upload | npm preservation, triage, and failure reporting |
| Poetry plugin directory and executable build backend | Inventory reads data without invoking either code path |
| npm workspace root, covered member, independent member | Correct lock ownership without duplicate scans |
| Tooling-only pyproject and unpinned Python input | Not-applicable checks and documented incomplete behavior |
| Hostile package names, paths, and advisory text | Serialized issue input without source interpolation |

Use local fake tool and HTTP responses for repeatable tests.
Do not require live advisories or credentials in regression tests.
Verify behavior with fixtures, rather than only matching documentation strings.

## Architecture evolution

| Date | Change | Reasoning |
|------|--------|-----------|
| 2026-09-29 | Fail-closed scanners (B1–B5). TOML lock parsers via `tomllib`. Manifest size cap. PEP 508/440 pin sanitisation. Symlink containment. Restore npm outdated + licence-checker. Install tools from the pin file. Hash pins deferred in AgDR-0184. | Rex review of PR #1469 found five fail-open paths that reported unscanned sets as clean, regex lock parsers that missed real Poetry/uv source tables, and a pipeline that dropped npm checks from `dev`. |
| 2026-09-29 | Hashed audit-tool lock shipped. CI installs with `--require-hashes`. Pre-hash gate step removed. Regeneration documented via `uv pip compile --generate-hashes` (AgDR-0194 / #1478). | AgDR-0176 required hashes; AgDR-0184 deferred them. #1478 fail-closed during transition, then filled the lock so verified tools install from the compiled pin file. |

## Approvals

PR #1430 recorded the design gate approval before implementation on #1359.
The later implementation and follow-up work use that approved design.

## Sources

- Issue #1359 and its comments.
- [pip-audit 2.10.0 usage and security model](https://github.com/pypa/pip-audit/blob/v2.10.0/README.md).
- [OSV-Scanner supported inputs](https://google.github.io/osv-scanner/supported-languages-and-lockfiles/).
- [CVSS 3.6 parser and licence](https://pypi.org/pypi/cvss/3.6/json).
- [packaging 25.0 parser](https://pypi.org/pypi/packaging/25.0/json).
- [OSV API](https://google.github.io/osv.dev/api/).
- [PyPI JSON API](https://docs.pypi.org/api/json/).
- [Python core metadata](https://packaging.python.org/en/latest/specifications/core-metadata/).
- [SPDX License List](https://spdx.org/licenses/).
- [AgDR-0184](../agdr/AgDR-0184-dependency-audit-tool-hash-pins-deferred.md) — hash-pin deferral (superseded by AgDR-0194).
- [AgDR-0194](../agdr/AgDR-0194-dependency-audit-fail-closed-hash-transition.md) — `--require-hashes` and generated hashed lock (#1478).

