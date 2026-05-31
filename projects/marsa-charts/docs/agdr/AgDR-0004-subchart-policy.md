# AgDR-0004 — Subchart policy: bundle Postgres + Redis, no BYO for v0.1

> In the context of deciding what infrastructure the Marsa chart provides vs. what operators must supply, facing K3s + local-network + MVP-scope constraints, I decided that **v0.1 bundles Postgres and Redis as thin in-chart templates with no BYO option**, accepting that production-grade adopters who want managed databases will be blocked until v1.0 adds the BYO axis.

> **Amendment (2026-05-31, Hisham):** **Redis is NOT bundled.** Marsa does not use Redis, so the "bundle Redis" portion of this decision is moot — no Redis Deployment / Service / PVC ships in the chart. The summary line above and the **Redis** row in the Decision table are retained as the original record but are **superseded by this note**. If Marsa later adopts Redis (caching, queues, sessions), revisit and bundle it then under the same thin-in-chart-template approach this AgDR established for Postgres. Net effect for v0.1: the bundled-component scope is **Postgres only**.

> **Amendment (2026-05-31, Hisham):** This record's references to "TLS" / "cert-manager / TLS" were written with **in-cluster, service-to-service** TLS in mind (e.g. marsa-api ↔ Postgres over the private network) — the concern a service mesh (Linkerd et al.) would address. That concern remains **out of scope** and unaddressed here. **Public-facing ingress HTTPS** (browser → `marsa.<domain>`, certs from a public CA like Let's Encrypt) is a **separate axis** this AgDR did NOT intend to govern; it is decided in [[AgDR-0005-public-ingress-tls]]. The Decision table's TLS row and the "Trigger to revisit (Ingress / TLS)" section below are re-scoped accordingly. **Net effect: bundling public-ingress TLS in the chart does not contradict this record.** The original Context bullets are left as-written — they record the assumptions at decision time, now superseded by this note.

## Context

- Marsa targets **K3s** specifically (not generic Kubernetes). K3s users are typically self-hosting on a VPS or homelab, single-node, often first-time chart deployers, no managed Postgres on hand.
- **v0.1 / MVP assumption: server + agents on a local network** — no public-internet exposure, no TLS-from-public-CA concern, no inbound from outside the network.
- The product positioning ("Heroku/Railway-style experience on your own k8s") demands a turnkey `helm install` that produces a working system in one command. Every "and also configure X" step kills that promise.
- A prior spike already produced a working Postgres manifest (Namespace + Secret + ConfigMap with init.sql + StatefulSet running `postgres:18.3-alpine` with PVC, readiness/liveness probes via `pg_isready`). The spike additionally provisioned a `zitadel` database alongside `marsa` as part of an exploratory auth-provider spike; the auth-provider choice is not yet decided and is explicitly out of scope here.
- Bitnami's 2025 shift moved most of their Helm catalog to a paid "Bitnami Secure Images" offering with only a smaller "latest-only" free tier — depending on bitnami subcharts as defaults is a fragile vendor commitment.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Bundle-only (chosen)** — Postgres + Redis as thin in-chart templates; no BYO config exposed | Simplest chart code; tightest scope; matches Heroku-style promise; no vendor dependency | Production-grade adopters who want managed Postgres can't use chart until v1.0 adds BYO |
| **Hybrid (bundled default + BYO via values)** | Maximum flexibility; serves casual AND production operators | ~70 extra lines of chart code per service (values schema, helper templates, conditional secrets); MVP doesn't have the production-grade audience yet to justify it |
| **BYO-only** | Cleanest chart code | Breaks the turnkey promise; K3s self-hosters typically lack managed DB; wrong shape for the target audience |
| **Bitnami subcharts** | Less template YAML to maintain; community-tested | Vendor dependency fragile post-2025 Bitnami changes; subchart values-passing complexity; overkill for K3s single-node deployments |

## Decision

Chosen: **Bundle-only, no BYO axis in v0.1.**

| Component | v0.1 shape |
|-----------|------------|
| **Postgres** | Bundled. Thin chart templates derived from the spike: StatefulSet running `postgres:18.3-alpine`, PVC via `volumeClaimTemplates`, init ConfigMap creating only the `marsa` database + user, Secret holding chart-generated passwords. Re-installs reuse the existing Secret to preserve the password. Additional databases (e.g. for an auth provider) get added when those subsystems land. |
| **Redis** | ~~Bundled. Thin chart templates: Deployment running `redis:7-alpine`, PVC for AOF persistence, Service.~~ **SUPERSEDED (2026-05-31): not bundled — Marsa does not use Redis. See Amendment.** |
| **Ingress controller** | Use K3s built-in **Traefik**. No bundled controller, no BYO values exposed. The chart's `Ingress` resource uses the default ingressClassName Traefik registers. |
| **In-cluster (service-to-service) TLS** | Out of scope (see Amendment). marsa ↔ Postgres/Redis traffic stays plaintext on the private network for v0.1; encrypting it would mean a service mesh (Linkerd et al.), which is not v0.1 work. |
| **Public-ingress HTTPS** | Not governed here — decided separately in [[AgDR-0005-public-ingress-tls]]. (Originally this row read "cert-manager / TLS: not bundled"; that wording conflated the two axes — see Amendment.) |
| **Auth provider** | Out of scope for this AgDR. Zitadel was explored in a prior spike but not adopted; the auth-stack decision lives in a future AgDR. When the auth provider is chosen, the bundled Postgres init script extends to provision its database. |

**Anti-scope (explicit, to prevent scope creep):**

- No `externalDatabase.host` / `externalRedis.host` values for v0.1
- No `postgresql.enabled` / `redis.enabled` flags
- No support for non-Traefik ingress
- No HA / replication / multi-AZ configurations
- No public-internet-facing deployments validated

## Consequences

- **Chart code stays small.** ~300 lines of template YAML total (Postgres + Redis), no values-schema conditional gymnastics, no `oneOf` constraints, no helper templates resolving connection strings from multiple sources.
- **Marsa's runtime values** point at `postgres.<release-namespace>.svc.cluster.local:5432` and `redis.<release-namespace>.svc.cluster.local:6379` — fixed addresses, no `externalDatabase` shape.
- **Initial passwords:** chart-generated on first install, persisted in a Kubernetes Secret. `helm upgrade` reuses the secret if present. Rotation is a future ticket.
- **Storage:** uses K3s default `local-path` storage class — fine for single-node, blocks naive multi-node deployments (which are out of MVP scope anyway).
- **Operator path off the happy path is undefined** — operators who try to add `externalDatabase.host` to values silently see it ignored. Document this clearly in the values reference.
- **Upgrade path to v1.0 / BYO:** when BYO becomes a requirement (revisit triggers below), v1.0 introduces `postgresql.enabled` / `externalDatabase.host` flags with `postgresql.enabled: true` as the default — backwards compatible for existing installs. Plan now: nothing. Implement at v1.0.

## Trigger to revisit (BYO)

Add the BYO axis when ANY of:

- An operator explicitly asks "can I use my existing Postgres?" (the first such request is the signal — don't wait for many)
- The roadmap adds a "production-grade" or "multi-node" target
- Marsa adoption pattern shifts off K3s onto general k8s clusters
- A bundled-component CVE requires emergency operator intervention, exposing the lack of "just point at a managed service" escape valve

## Trigger to revisit (Ingress / in-cluster TLS)

> Public-ingress HTTPS is **no longer a revisit trigger here** — it was split out into [[AgDR-0005-public-ingress-tls]] (see Amendment 2026-05-31). What remains in this AgDR's scope:

Revisit when ANY of:

- An operator wants non-Traefik ingress (likelier on managed k8s, less likely on K3s)
- Multi-node K3s clusters with separate ingress nodes become a supported topology
- In-cluster service-to-service encryption becomes a requirement (compliance, hostile-network, multi-tenant) → evaluate a service mesh

## Artifacts

- Ticket: [marsa-cloud/marsa-charts#7](https://github.com/marsa-cloud/marsa-charts/issues/7)
- Spike source: prior Postgres-only spike (provided in conversation 2026-05-29) — Namespace + Secret + ConfigMap init script + StatefulSet on `postgres:18.3-alpine` + Service + PVC
- Related AgDRs: [[AgDR-0001-chart-structure]] (umbrella chart contains all of this), [[AgDR-0002-chart-versioning]] (chart version bumps when subchart bumps), [[AgDR-0005-public-ingress-tls]] (public-ingress HTTPS — split out per the 2026-05-31 amendment)
- Related open tickets: [#3](https://github.com/marsa-cloud/marsa-charts/issues/3) (CI), [#4](https://github.com/marsa-cloud/marsa-charts/issues/4) (README — document anti-scope explicitly)
- Author: Hisham (Tech Lead) on behalf of Mohammad Gomaa
- Date: 2026-05-29
