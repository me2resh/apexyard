# Security-scan tooling + cadence for the framework repo

> In the context of adding a security scan to the apexyard framework repo (and refreshing the shipped golden-path template), facing the need for free/no-account tooling that fits a repo with no shipped binary, I decided to use gitleaks (secrets) + Semgrep OSS (SAST) on a release-gated cadence (with explicit N/A for dep-audit/SBOM where there are no manifests), to achieve self-scanning without a paid service or token, accepting that release-gated scanning catches issues at release time rather than on every PR.

## Context

The framework repo runs link-check / markdownlint / shellcheck but never security-scanned itself, while it *ships* a "Shield" security-pipeline template (`golden-paths/pipelines/security.yml`) — which itself referenced tools requiring a paid token (`returntocorp/semgrep-action` needs `SEMGREP_APP_TOKEN`) and an unpinned action (`trufflehog@main`). The repo is mostly markdown + shell + skills, with **no third-party dependency manifests** (no `package.json`/`requirements.txt`/`pyproject.toml` with runtime deps). Constraints from the owner: full suite, **free/OSS tools only**, **fail on medium+**, and **release-gated** (run on release/tag/dispatch, not every PR).

## Options Considered

| Decision point | Options | 
|----------------|---------|
| **Secrets** | gitleaks (OSS, free action) · trufflehog (verification needs a token; was unpinned `@main`) |
| **SAST** | Semgrep OSS (`pip install semgrep`, free public rulesets, no login) · Semgrep paid action (needs `SEMGREP_APP_TOKEN`) · CodeQL (free + native but heavier for an on-demand/release trigger) |
| **Cadence** | release-gated (release/tag/`workflow_dispatch`) · every PR/push |
| **Dep-audit / SBOM** | run pip-audit/npm-audit + CycloneDX · mark **N/A** honestly (no manifests in this repo) |

## Decision

Chosen: **gitleaks + Semgrep OSS, release-gated, with honest N/A for dep-audit + SBOM**, because:

1. **gitleaks over trufflehog** — OSS, pinned (`gitleaks-action@v2`), no token for the scanning we need; trufflehog's value-add (verification) requires a token and the template pinned it to `@main` (a supply-chain risk).
2. **Semgrep OSS over the paid action / CodeQL** — `pip install semgrep` + free public rulesets runs with only `GITHUB_TOKEN`; the paid action needs `SEMGREP_APP_TOKEN`. CodeQL is free + robust but designed for continuous scanning and is heavier for a release-only trigger; Semgrep OSS is lighter on-demand.
3. **Release-gated cadence** — per the owner's call: the full suite runs on `release: published` / `push: tags: v*` / `workflow_dispatch`, not on every PR (avoids slowing day-to-day CI; the scan gates the *ship*, which is where "did we ship anything harmful?" matters).
4. **Honest N/A** — this repo has no dependency manifests, so dep-audit + SBOM jobs emit an explicit N/A notice rather than fabricating coverage. The premium repo (which ships a wheel) runs the full dep/license/SBOM/wheel-content suite (its sibling ticket #110).
5. **`permissions: contents: read`** least-privilege; no `pull_request_target`.

The same tool swaps were applied to the shipped `golden-paths/pipelines/security.yml` so adopters inherit the free, pinned stack.

## Consequences

- The framework dog-foods a security scan; adopters get a battle-tested, token-free template.
- Release-gated means a finding surfaces at release time, not on the introducing PR — acceptable for a no-shipped-binary repo; the premium product uses the same release gate where the stakes are higher.
- One-time clearance run on current `dev`: gitleaks 0 secrets; Semgrep 4 WARNING (all the safe `IFS` save/restore pattern — false positives) + 22 advisory INFO; no ERROR, no secrets — clear for release.

## Artifacts

- PR: me2resh/apexyard#488 (`.github/workflows/security-scan.yml` + golden-path template refresh)
- Sibling: me2resh/apexyard-premium#110 (full suite + wheel-content scan on the shipped product)
