# AgDR-0003 — Chart distribution: OCI registry on ghcr.io

> In the context of needing to pick a publication mechanism before the first chart release, facing a choice between OCI on ghcr.io and the classic gh-pages HTTP repo via chart-releaser, I decided to **publish charts as OCI artifacts to ghcr.io/marsa-cloud/charts**, accepting that operators on pre-Helm-3.8 clients (released March 2022) cannot consume them.

## Context

- Helm 3.8+ ships with native OCI registry support — no plugins, no separate index file maintenance.
- ghcr.io sits next to the source repo at no additional setup or cost.
- The classic alternative (gh-pages branch hosting an `index.yaml` + chart tarballs via chart-releaser) is well-trodden but introduces a parallel publishing branch that must be kept in sync.
- The "old Helm clients can't OCI" objection is real but bites a shrinking population — Helm 3.8 released in March 2022 and the K3s-self-hoster audience this chart targets is overwhelmingly current.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **OCI on ghcr.io** (`oras push ghcr.io/marsa-cloud/charts/marsa`) | Native Helm 3.8+ support; no `index.yaml` to maintain; no gh-pages branch; lives next to source repo and image artifacts; cosign signing path is straightforward | Operators on Helm <3.8 (released March 2022) cannot consume — a shrinking but real population |
| **gh-pages HTTP repo via chart-releaser** | Works on every Helm version; well-trodden, every Helm tutorial assumes this shape | Adds gh-pages branch maintenance burden; parallel publishing pipeline; `index.yaml` is a footgun (race conditions on parallel releases); no native signing |
| **Both** | Maximum compatibility | Two pipelines to keep green; one will rot |

## Decision

Chosen: **OCI on ghcr.io.**

The publish target is `ghcr.io/marsa-cloud/charts/marsa`. Install UX:

```
helm install marsa oci://ghcr.io/marsa-cloud/charts/marsa --version 0.1.0
```

This is the standard 2026-era pattern. The Helm <3.8 compatibility cost is judged acceptable for a greenfield product whose target audience (K3s self-hosters) skews recent.

## Consequences

- **Publish pipeline ([#3](https://github.com/marsa-cloud/marsa-charts/issues/3))** runs on tag push: package chart, `helm push oci://ghcr.io/marsa-cloud/charts`. No `cr index` step, no gh-pages commit.
- **README ([#4](https://github.com/marsa-cloud/marsa-charts/issues/4))** documents the OCI install command verbatim. No `helm repo add` step.
- **Versioning ([[AgDR-0002-chart-versioning]])** — the OCI tag is the chart's `version` field; `appVersion` is metadata embedded in the artifact, not in the tag.
- **Cosign signing path is open** as a future enhancement (separate follow-up ticket if/when supply-chain verification becomes a roadmap item).
- **No gh-pages branch** — keeps the repo tree clean; `main` is the only branch.
- **Pre-Helm-3.8 operators see "unsupported scheme: oci"** if they try to install — README explicitly states minimum Helm version.
- **Trigger to revisit:** if a meaningful fraction of would-be operators (≥10% of install attempts via README issue / discussion threads) hit the "Helm too old" wall, file a follow-up to additionally publish via gh-pages.

## Artifacts

- Ticket: [marsa-cloud/marsa-charts#6](https://github.com/marsa-cloud/marsa-charts/issues/6)
- Related AgDRs: [[AgDR-0001-chart-structure]] (one chart artifact = one OCI tag), [[AgDR-0002-chart-versioning]] (which version goes on the OCI tag)
- Related open tickets: [#3](https://github.com/marsa-cloud/marsa-charts/issues/3) (CI / publish pipeline), [#4](https://github.com/marsa-cloud/marsa-charts/issues/4) (README install instructions), [#7](https://github.com/marsa-cloud/marsa-charts/issues/7) (subchart policy)
- Author: Hisham (Tech Lead) on behalf of Mohammad Gomaa
- Date: 2026-05-29
