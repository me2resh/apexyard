# Pin GitHub Actions to immutable commit SHAs

> In the context of apexyard CI workflows that reference third-party GitHub Actions by mutable version tags, facing supply-chain risk if a tag is repointed to malicious code, I decided to pin every `uses:` reference to a full commit SHA with the original tag noted in an inline comment, to achieve reproducible CI execution without changing workflow behavior, accepting the maintenance cost of periodic SHA refreshes (e.g. via Dependabot).

## Context

A /gstack-cso daily audit (2026-06-06) flagged floating `@v2` / `@v16` tags on third-party actions (`lycheeverse/lychee-action`, `DavidAnson/markdownlint-cli2-action`, `ludeeus/action-shellcheck`, `gitleaks/gitleaks-action`) and first-party `actions/*` tags. A compromised tag could execute arbitrary code with the workflow's `GITHUB_TOKEN` permissions on the next run.

This is a hardening change, not a new capability. Workflow inputs, triggers, and permissions are unchanged.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep floating tags | Zero maintenance | Tag repointing is a known CI supply-chain vector |
| **Pin to commit SHA (chosen)** | Immutable action resolution; matches GitHub security guidance | SHAs must be refreshed when upgrading actions |
| Fork and vendor actions | Maximum control | High maintenance; overkill for a markdown/shell framework |

## Decision

Pin all `uses:` references in `.github/workflows/` to the SHA resolved from the tag at pin time, with a trailing `# vN` comment for human readability.

SHAs pinned 2026-06-06:

| Action | Tag | SHA |
|--------|-----|-----|
| actions/checkout | v4 | `34e114876b0b11c390a56381ad16ebd13914f8d5` |
| actions/upload-artifact | v4 | `ea165f8d65b6e75b540449e92b4886f43607fa02` |
| actions/github-script | v7 | `f28e40c7f34bde8b3046d885e986cb6290c5673b` |
| lycheeverse/lychee-action | v2 | `8646ba30535128ac92d33dfc9133794bfdd9b411` |
| DavidAnson/markdownlint-cli2-action | v16 | `b4c9feab76d8025d1e83c653fa3990936df0e6c8` |
| ludeeus/action-shellcheck | 2.0.0 | `00cae500b08a931fb5698e11e79bfbd38e612a38` |

## Consequences

- Adopters copying golden-path workflows should pin SHAs the same way.
- Future action upgrades require resolving a new SHA (not just bumping `@v3`).
- `security-scan.yml` on feature branches should receive the same pins when that workflow lands on `main`.
