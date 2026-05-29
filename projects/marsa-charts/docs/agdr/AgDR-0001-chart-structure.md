# AgDR-0001 — Chart structure: single umbrella chart

> In the context of seeding `marsa-cloud/marsa-charts` before the first `Chart.yaml` lands, facing a choice between umbrella / per-service / hybrid layouts, I decided to ship a **single umbrella chart** that represents the whole Marsa product, accepting that any future need for per-component versioning will require restructuring later.

## Context

- Marsa is a self-hostable PaaS aimed at solo and small-team operators (mission per `onboarding.yaml`: "Heroku/Railway-style experience on their own Kubernetes").
- The product's primary install UX is a single `helm install` — operators consume the product, not its internal components.
- Marsa is currently solo-developed; no per-team release-cadence pressure exists.
- The repo is greenfield: zero charts exist yet, so the cost of picking the wrong structure now is "restructure the first chart" rather than "migrate live installs".
- Two adjacent decisions are pending and explicitly out of scope here: chart versioning policy (AgDR-NNNN, [#5](https://github.com/marsa-cloud/marsa-charts/issues/5)) and subchart dependency policy (AgDR-NNNN, [#7](https://github.com/marsa-cloud/marsa-charts/issues/7)).

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Umbrella chart** — one `charts/marsa/` containing all Marsa templates; one Chart.yaml; one version line. | Single `helm install marsa` UX; mirrors how GitLab, Mattermost, Sentry, Coolify ship; trivial release process; one version-bump conversation per release. | Future per-component versioning requires breaking the chart apart; templates can grow large if Marsa decomposes into many services. |
| **Per-service charts** — `charts/marsa-api/`, `charts/marsa-web/`, `charts/marsa-worker/`, etc., each independently versioned and published. | Each component can move independently; matches a microservices release cadence; easier to deprecate one piece. | Operators must compose installs themselves; cross-component version compatibility becomes the operator's problem; no upstream PaaS-style project ships this way. |
| **Hybrid — umbrella + local per-service subcharts** — `charts/marsa/` with `charts/marsa/charts/marsa-api/`, etc. as local dependencies. | Single install UX preserved; nominally allows future split; same release cadence externally. | Adds Helm sub-chart complexity (values propagation, naming) with no current benefit; the nominal future-split path is rarely exercised in practice. |

## Decision

Chosen: **Umbrella chart** at `charts/marsa/`, because:

1. **Install UX matches product positioning.** A "Heroku for your own k8s" promises one command; per-service or hybrid both leak internals.
2. **Prior art is unanimous.** Every comparable self-hosted PaaS / dev-platform product (GitLab, Mattermost, Sentry, Coolify) ships as a single chart. Operators have learned this shape.
3. **No current motivation for independent versioning.** Single team, internal-only API surface, restart-the-product is a non-event at PaaS-operator scale. The pros of per-service versioning are theoretical at current scale; the cons (operator burden) are immediate.
4. **Reversible at low cost.** The first install hasn't happened. If Marsa later genuinely needs per-component versioning (e.g. a public API for third-party tools, a multi-team release cadence), splitting the umbrella into per-service charts is a one-time migration — and one we'd do as a deliberate response to an actual signal, not as upfront speculation.

Internal service decomposition (monolith vs few services vs many) is **deliberately deferred** — the umbrella chart contains whatever templates Marsa needs at the time, regardless of how many Deployments those templates produce. The chart structure doesn't lock in the runtime architecture.

## Consequences

- **Repo layout:** first chart lands at `charts/marsa/` (Chart.yaml, values.yaml, values.schema.json, templates/, README.md). Future helper / example charts (if any) sit alongside as siblings under `charts/`.
- **Versioning:** chart version and appVersion are single values — moves the conversation in [#5](https://github.com/marsa-cloud/marsa-charts/issues/5) from "how do components version against each other" to the simpler "how does chart version track the marsa app version".
- **Subchart policy ([#7](https://github.com/marsa-cloud/marsa-charts/issues/7))** is still open and orthogonal — the umbrella chart can either bundle Postgres/Redis/ingress as remote subcharts or require BYO. This AgDR doesn't pre-commit.
- **CI ([#3](https://github.com/marsa-cloud/marsa-charts/issues/3))** runs on a single chart target — `helm lint charts/marsa`, `ct lint --target-branch main`. No fan-out across multiple chart dirs needed.
- **README ([#4](https://github.com/marsa-cloud/marsa-charts/issues/4))** documents one install path: `helm install marsa marsa/marsa`.
- **Distribution ([#6](https://github.com/marsa-cloud/marsa-charts/issues/6))** publishes a single artifact per release, simplifying the OCI vs gh-pages comparison.
- **Anti-scope:** this AgDR does NOT decide internal service shape, subchart bundling, versioning policy, or distribution mechanism. Those each have their own ticket.
- **Trigger to revisit:** revisit this decision if any of the following become true — (a) Marsa exposes a public API that external tools version against, (b) the team grows past ~5 engineers with component-specific release cadences, (c) operators explicitly ask for per-component upgrades.

## Artifacts

- Ticket: [marsa-cloud/marsa-charts#2](https://github.com/marsa-cloud/marsa-charts/issues/2)
- Architecture stub: [`projects/marsa-charts/architecture/container.md`](../../architecture/container.md) — updated to reflect a single chart container
- Related open tickets: [#3](https://github.com/marsa-cloud/marsa-charts/issues/3) (CI), [#4](https://github.com/marsa-cloud/marsa-charts/issues/4) (README), [#5](https://github.com/marsa-cloud/marsa-charts/issues/5) (versioning), [#6](https://github.com/marsa-cloud/marsa-charts/issues/6) (distribution), [#7](https://github.com/marsa-cloud/marsa-charts/issues/7) (subchart policy)
- Author: Hisham (Tech Lead) on behalf of Mohammad Gomaa
- Date: 2026-05-29
