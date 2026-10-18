---
name: audit-deps
description: Audit dependencies for vulnerabilities, outdated packages, and license compliance.
disable-model-invocation: false
argument-hint: "[project-path] [--ecosystem=npm|python] [--language=js|ts|python] [--runner=npm|pip-audit|osv]"
allowed-tools: Bash, Read, Grep, Glob
---

Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.

# /audit-deps — Dependency Audit

Audit project dependencies for security vulnerabilities, outdated packages, and license compliance across npm and Python.

The skill, Munir (`.claude/agents/dependency-auditor.md`), and `golden-paths/pipelines/dependency-audit.yml` share one contract. The shared helper is the source of truth for discovery, severity, licences, and remediation:

`golden-paths/pipelines/scripts/dependency-audit.py`

Adopters copy that helper beside the workflow as `.github/scripts/dependency-audit.py`. Compare `helper_revision` when refreshing. The current helper revision is 4.

Design: [AgDR-0176](../../../docs/agdr/AgDR-0176-dependency-audit-ecosystem-dispatch.md).

## Usage

```
/audit-deps
/audit-deps path/to/project
/audit-deps path/to/project --ecosystem=python
/audit-deps path/to/project --language=ts
/audit-deps path/to/project --runner=osv
```

## Path resolution

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
projects_dir=$(portfolio_projects_dir)
workspace_dir=$(portfolio_workspace_dir)
HELPER="$(git rev-parse --show-toplevel)/golden-paths/pipelines/scripts/dependency-audit.py"
```

Run against a managed project under `workspace/<name>/`, or an explicit project path. Refuse the ops-fork root when it only holds framework files.

## Process

### 1. Detect ecosystems (manifests, not source counts)

| Ecosystem | Detection |
|-----------|-----------|
| npm | `package.json` |
| Python | `requirements*.txt`, `dev-requirements.txt`, `pyproject.toml`, `Pipfile`, `Pipfile.lock`, `poetry.lock`, `uv.lock` |

Search the project tree. Skip `node_modules`, `.venv`, `vendor`, `dist`, `build`, `.next`, and `.git`.

Default: audit every detected supported ecosystem. `--ecosystem=` filters. `--language=js|ts|python` is an alias. Reject conflicting filters. `--runner=` must match the selected ecosystem. Report detected ecosystems that the filter excludes. Report known unsupported manifests as not scanned. A tooling-only `pyproject.toml` with no dependency groups is `not_applicable`.

### Known unsupported manifests

The helper does not scan these files. It records each file in `not_scanned`.

| Pattern | Ecosystem |
|---------|-----------|
| `*.csproj`, `*.fsproj`, `*.vbproj`, `packages.config`, `Directory.Packages.props` | nuget |
| `libman.json` | libman |
| `go.mod` | go |
| `Cargo.toml` | cargo |
| `Gemfile` | bundler |
| `pom.xml` | maven |
| `build.gradle`, `build.gradle.kts` | gradle |
| `composer.json` | composer |
| `Package.swift` | swift |
| `pubspec.yaml` | pub |
| `mix.exs` | mix |

Each `not_scanned` entry has `path`, `ecosystem`, and `reason`.
The path is relative to the scanned root.
The helper does not add a NuGet runner.
Discovery uses the same walk and the same ignored directories as npm and Python.

The helper exits 3 for unsupported manifests only when both conditions are true.
No npm or Python dependency set is selected for checks. A tooling-only `pyproject.toml` does not count, because it has no dependencies to check.
No `--ecosystem` filter is given.
The `--language` flag selects the same filter.
A Critical finding still exits 1.
Every other case keeps the normal exit code.
The helper still records each file in `not_scanned`.
The Markdown report keeps the Not scanned section.
The helper keeps the coverage note.
This skill and the helper use that same exit rule.
A tree with no dependency manifest exits 0.
The helper adds the note `no dependency manifests found`.

The CI template starts a scan only when it finds an npm or Python manifest.
Run the helper directly for a tree that has only unsupported manifests.

### 2. Invoke the shared helper

```bash
python3 -I "$HELPER" "$PROJECT_PATH" \
  ${ECOSYSTEM:+--ecosystem="$ECOSYSTEM"} \
  ${LANGUAGE:+--language="$LANGUAGE"} \
  ${RUNNER:+--runner="$RUNNER"} \
  --json-out /tmp/dep-audit.json \
  --md-out "$projects_dir/<name>/quality/dependency-audit-$(date -u +%Y-%m-%d).md"
```

Use a trusted interpreter. Do not put the audited checkout on `PYTHONPATH`.

### 3. Vulnerability scan

| Ecosystem | Runner |
|-----------|--------|
| npm | `npm audit --json` |
| Python | Prefer `pip-audit==2.10.0` with `-s osv --no-deps --disable-pip` on data-only exact pins. If that trusted scanner is absent, query OSV directly for the same pins. An explicit `--runner=pip-audit` reports a missing tool and exits 3. A scanner failure stays failed. Never silently fall back to a clean result. |

Python inventory is data-only. Parse lockfiles and pinned requirements as data. Never run Poetry, uv, Pipenv, build backends, or checkout plugins.

### 4. Severity mapping

| Evidence | Report severity |
|----------|-----------------|
| npm `critical` / `high` / `moderate` / `low` | Critical / High / Medium / Low |
| Recognised OSV label | `MODERATE` → Medium. Preserve other matching levels. |
| Valid CVSS base score | Critical 9.0–10.0, High 7.0–8.9, Medium 4.0–6.9, Low above 0 and below 4.0 |
| Missing, unsupported, or unparseable | Unknown, with reason |
| Label and score disagree | Highest recognised severity. Keep conflict evidence. |

Unknown findings need manual triage. They stay visible in totals.

### 5. Outdated packages

- npm: `npm outdated --json`
- Python: compare exact pins with version-specific public PyPI metadata via `packaging==25.0`

Recommend updates through the project's package manager and lockfile workflow. Never emit `npm update` for a Python package.

### 6. Licence compliance

Preserve each package's exact version, metadata source, and raw claim.

**Allowed (exact SPDX):** MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC, CC0-1.0, 0BSD, Unlicense

**Restricted (require review, current SPDX):** GPL-2.0-only, GPL-2.0-or-later, GPL-3.0-only, GPL-3.0-or-later, LGPL-2.0-only, LGPL-2.0-or-later, LGPL-2.1-only, LGPL-2.1-or-later, LGPL-3.0-only, LGPL-3.0-or-later, AGPL-3.0-only, AGPL-3.0-or-later, MPL-2.0, CDDL-1.0, CDDL-1.1

**Banned:** UNLICENSED, Proprietary

**Pending review (not banned):** Unknown, missing metadata, compound SPDX expressions, deprecated identifiers pending remapping, classifier-only claims without an exact SPDX id.

Pending review still blocks licence clearance. Unknown never becomes allowed by default.

### 7. Mixed repository report

Produce one report. Include per-directory dependency sets and per-ecosystem sections. Name every ecosystem and manifest. Combine severity totals across ecosystems. Deduplicate by ecosystem, package name, version, and advisory identity. Keep every affected manifest path.

### 8. Exit codes

| Exit | Meaning |
|------|---------|
| 0 | Complete selected checks. No Critical or Unknown vulnerability findings. |
| 1 | Known Critical vulnerability findings. |
| 2 | Invalid arguments or incompatible runner override. |
| 3 | Missing selected tool, failed check, or incomplete selected coverage. |
| 4 | Complete selected coverage with Unknown vulnerability findings. |

The helper exits 3 for unsupported manifests only when both conditions are true.
No npm or Python dependency set is selected for checks. A tooling-only `pyproject.toml` does not count, because it has no dependencies to check.
No `--ecosystem` filter is given.
A Critical finding still exits 1.
Every other case keeps the normal exit code.
The `not_scanned` list, the Not scanned section, and the coverage note stay.
WARN or incomplete coverage does not install tools automatically. Print per-ecosystem install advice.

### 9. Install advice (missing tools)

```
npm          — install Node.js + npm for the project
pip-audit    — pip install pip-audit==2.10.0 packaging==25.0
               (trusted env only; see golden-paths/pipelines/scripts/dependency-audit-tools.lock.json)
OSV fallback — no extra install. Needs network to api.osv.dev
```

## Output

Write the markdown report under `projects/<name>/quality/` when a portfolio project name is known. Print the JSON summary on stdout.

Invokes: Dependency Auditor Agent (Munir / Guardian)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
