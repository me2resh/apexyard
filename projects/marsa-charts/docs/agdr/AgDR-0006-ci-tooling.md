---
id: AgDR-0006
timestamp: 2026-05-31T12:05:00Z
agent: Adel (Platform Engineer)
model: claude-opus-4-8
trigger: user-prompt
status: executed
---

# AgDR-0006 — marsa-charts CI tooling choices

> In the context of getting `chart-ci.yml` actually green for the first chart (it had never run — it failed at workflow-parse on every prior commit), facing version/licence/permission friction in the test + secrets-scan tooling, I decided to **run helm-unittest via the official docker image and gitleaks via its open-source binary**, to achieve a free, deterministic pipeline on an org-owned repo, accepting a dependency on Docker Hub + a GitHub release at CI time.

> **Amendment (2026-05-31):** the secrets-scan choice flipped to **gitleaks-action@v2**. The original "OSS binary" pick was driven by the action requiring a licence on org-owned repos and us not having one. A licence is now available (stored in the `GITLEAKS_LICENSE` repo secret), so the action — which gives full-history scanning, PR annotations, and SARIF for free — is the better choice. The binary's manual checksum-verify + `--no-git` removal are no longer needed (the action handles history). Decision below is superseded for the secrets-scan row only; the helm-unittest / kubeconform / ct-lint choices stand.

## Context

- `chart-ci.yml` never compiled: `${{ env.K8S_VERSION }}` was used in a job `name:`, where the `env` context is unavailable → 0 jobs, "workflow file issue". Fixing that unblocked the real tooling decisions below.
- `marsa-cloud` is a GitHub **organisation**, so `gitleaks-action@v2` demands a paid `GITLEAKS_LICENSE` secret.
- `helm plugin install helm-unittest` couples the plugin's `plugin.yaml` schema to the runner's helm version — the current plugin uses `platformHooks`, which even helm 3.17.3 rejects.

## Options Considered

| Decision | Options | Chosen |
|----------|---------|--------|
| Secrets scan | gitleaks-action@v2 (needs licence on orgs) · gitleaks OSS binary · drop the scan | **gitleaks-action@v2** with an org licence (see Amendment) |
| Unit tests | `helm plugin install` (version-coupled) · official `helmunittest/helm-unittest` docker image · drop CI tests | **docker image** (ships a matched helm+plugin pair) |
| kubeconform + CRDs | fail on unknown CRD schemas · `-ignore-missing-schemas` | **-ignore-missing-schemas** (K3s `HelmChartConfig` isn't in the datreeio catalog) |
| ct lint maintainers | require maintainers · `--validate-maintainers=false` | **disable** (Chart.yaml ships no maintainers for solo-dev v0.1) |

## Decision

Chosen as above. The pipeline now runs: detect-charts → helm lint, ct lint, kubeconform, **helm unittest** (new), gitleaks — all free and unauthenticated.

## Consequences

- helm-unittest now gates PRs (closes the "spec exists but doesn't run in CI" gap).
- The unittest job depends on Docker Hub (`helmunittest/helm-unittest:latest`) and runs the container as the runner UID (`-u $(id -u):$(id -g)`) so it can write its `__snapshot__` dir into the bind mount.
- `-ignore-missing-schemas` means a genuinely malformed CRD wouldn't be caught by kubeconform; acceptable for the two known K3s/Traefik CRDs at v0.1.
- Revisit `--validate-maintainers=false` when the team grows (add a maintainers list to Chart.yaml).

## Artifacts

- PR: marsa-cloud/marsa-charts#11 (chart + CI), commits fixing the parse error → docker-image unittest → snapshot-perms
- Related: [[AgDR-0005-public-ingress-tls]] (the IngressRoute/HelmChartConfig CRDs that drove `-ignore-missing-schemas`)
- Author: Adel (Platform Engineer) on behalf of Mohammad Gomaa
- Date: 2026-05-31
