---
id: AgDR-0194
timestamp: 2026-09-29T17:12:55Z
agent: platform-engineer
model: gpt-6
session: codex-1478
trigger: user-prompt
status: executed
category: security
projects: [apexyard]
---

# Install dependency audit tools from a hash-verified lock

> For issue #1478, facing audit tools installed by version pin only,
> I decided to install them with `--require-hashes` from a compiled, hashed lock,
> to meet AgDR-0176, accepting that a pin change needs network access and `uv` to regenerate the lock.

## Context

AgDR-0176 requires hashes for direct and transitive audit tools.
AgDR-0184 deferred those hashes after PR #1469.
This change ships the hashed lock and the `--require-hashes` install in the same PR.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep installing version pins | No lock to maintain. | The trusted tools lack hash verification. |
| Install with `--require-hashes` from a compiled lock | pip rejects any tool whose hash does not match. Meets AgDR-0176. | A pin change needs network access and `uv` to regenerate the lock. |

## Decision

Chosen: **install with `--require-hashes` from a compiled lock**.
The workflow installs with `pip install --require-hashes -r …`.
Direct pins live in `dependency-audit-tools.in`.
`dependency-audit-tools.requirements.txt` holds the compiled lock with sha256 hashes
for Python 3.12 on Linux x86_64.

Regenerate after changing a pin (from the framework repository root, with network access and `uv`):

```bash
uv pip compile --python-version 3.12 --python-platform x86_64-unknown-linux-gnu \
  --generate-hashes --no-header \
  -o golden-paths/pipelines/scripts/dependency-audit-tools.requirements.txt \
  golden-paths/pipelines/scripts/dependency-audit-tools.in
```

## Consequences

- The Python job installs only hash-verified audit tools.
- The npm job can still run independently.
- An incomplete or missing Python report remains visible in the combined workflow result.
- Lock refresh requires network access and a trusted `uv` installation.

## Artifacts

- `golden-paths/pipelines/dependency-audit.yml`
- `golden-paths/pipelines/scripts/dependency-audit-tools.in`
- `golden-paths/pipelines/scripts/dependency-audit-tools.requirements.txt`
- Issue #1478
