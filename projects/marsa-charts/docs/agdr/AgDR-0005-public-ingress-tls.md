---
id: AgDR-0005
timestamp: 2026-05-31T06:45:00Z
agent: Hisham (Tech Lead)
model: claude-opus-4-8
trigger: user-prompt
status: executed
---

# AgDR-0005 — Public-ingress TLS: K3s built-in Traefik ACME resolver

> In the context of giving the Marsa chart public-facing HTTPS (browser → `marsa.<domain>`), facing a choice between the K3s-bundled Traefik's built-in ACME resolver and a dedicated cert-manager controller, I decided to use the **K3s built-in Traefik ACME (Let's Encrypt) `certResolver`**, to achieve turnkey HTTPS with zero extra controllers, accepting that certs live in a single Traefik-owned `acme.json` file (single-replica, persistence-dependent) rather than as portable Kubernetes TLS Secrets.

## Context

- This is the **public-ingress HTTPS axis**, split out from [[AgDR-0004-subchart-policy]] per its 2026-05-31 amendment. AgDR-0004's "TLS" referred to *in-cluster service-to-service* TLS (mesh territory, still out of scope); this AgDR governs only browser-facing HTTPS.
- Marsa targets **K3s**, which ships **Traefik** as its default ingress controller and exposes a built-in ACME `certResolver`. The chart already routes via a Traefik `IngressRoute`.
- Product positioning ("Heroku/Railway-style experience on your own k8s") demands turnkey HTTPS — ideally one `helm install` produces a working TLS endpoint with no extra controller install step.
- Current scale is single-node K3s, single Traefik replica. No HA-ingress, non-Traefik-ingress, or multi-controller requirement today.
- The PR (#10) already implements this path: `cert-resolver.yaml` patches the bundled Traefik via `HelmChartConfig` (`helm.cattle.io/v1`) to register a Let's Encrypt `le` resolver; `ingress-route.yml` references `certResolver: le` when `tls.enabled`.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Traefik built-in ACME resolver (chosen)** — patch K3s's bundled Traefik to run a Let's Encrypt `certResolver` | Zero extra controllers/CRDs; uses what K3s already ships; matches AgDR-0004's "built-in Traefik, no extra controllers" spirit; smallest footprint; fits single-node turnkey promise | Certs stored in a Traefik-owned `acme.json` **file**, not a k8s Secret — no locking, so **single Traefik replica only**; needs **persistent storage** for `acme.json` or certs re-issue on every Traefik restart (Let's Encrypt rate-limit risk); Traefik-specific, not portable to other ingress controllers |
| **cert-manager** — dedicated controller + CRDs (Issuer/Certificate/Order/Challenge), certs stored as k8s TLS Secrets | Ingress-agnostic + portable across clusters; HA-friendly (Secrets are cluster state, no file locking); many issuers (LE, Vault, internal CA); standard k8s approach; certs reusable by any workload | Extra controller to install, run, and upgrade + its CRDs — the exact footprint AgDR-0004 set out to avoid; overkill for single-node K3s; adds a moving part to the turnkey install |

## Decision

Chosen: **K3s built-in Traefik ACME `certResolver`**, because:

1. **Footprint matches positioning.** Single-node K3s + turnkey "Heroku for your k8s" wants the fewest moving parts. The resolver reuses the Traefik K3s already runs — no extra controller, no CRDs to install.
2. **The chosen-against cons don't bite at current scale.** The `acme.json` single-replica / no-locking limitation only matters for HA/multi-replica Traefik, which is explicitly off the v0.1 happy path (AgDR-0004 anti-scope).
3. **cert-manager's wins are exactly the deferred signals.** Portability, HA, non-Traefik ingress, multiple cert consumers — all of these line up with AgDR-0004's "off the K3s happy path" revisit triggers. We adopt cert-manager when those signals fire, not speculatively.

## Consequences

- **`acme.json` MUST be persisted.** ⚠️ The Traefik ACME resolver stores issued certs in `acme.json` *inside the Traefik pod*. Without PVC-backed persistence, every Traefik restart re-issues certs and will hit Let's Encrypt's rate limits (50 certs/registered-domain/week; 5 duplicate-cert/week). Finishing the TLS work **requires** confirming the K3s Traefik has PVC-backed storage for `acme.json` (K3s default Traefik does persist to `/data` on a PVC — verify it's present and survives restart). This is the single load-bearing operational caveat of this choice.
- **Single Traefik replica only.** `acme.json` has no distributed locking — scaling Traefik beyond one replica corrupts/races the cert store. Documented limitation; acceptable for single-node v0.1.
- **Certs are not Kubernetes Secrets.** Other workloads/ingresses cannot reuse the cert; it's Traefik-internal. Fine while Traefik is the only TLS terminator.
- **Chart surface.** `cert-resolver.yaml` (the `HelmChartConfig` patch) + the `tls` stanza in `values.yaml` + `certResolver: le` in `ingress-route.yml` are the implementation; no new dependencies added to `Chart.yaml`.
- **ACME email is operator-supplied** via `values.yaml` (`email`) — must be a real address for Let's Encrypt expiry notices; the placeholder default must be overridden before public use (enforce/validate in `values.schema.json` when finding #3 lands).

## Trigger to revisit (migrate to cert-manager)

Replace the Traefik resolver with cert-manager when ANY of:

- **HA / multi-replica Traefik** becomes a supported topology (the `acme.json` no-locking limit becomes a correctness bug, not just a caveat)
- **A non-Traefik ingress controller** is adopted (the resolver is Traefik-specific)
- **A second TLS consumer** appears that needs the cert as a reusable k8s Secret (e.g. a second ingress, mTLS gateway, or a workload terminating its own TLS)
- **Marsa adoption shifts off K3s** onto general k8s where Traefik isn't the bundled default (overlaps AgDR-0004's ingress revisit trigger)
- **`acme.json` persistence proves fragile in practice** (repeated rate-limit hits, cert loss on node events) despite PVC backing — cert-manager's Secret-based storage removes the failure mode

## Addendum (2026-05-31) — Ingress resource type: Traefik `IngressRoute`

A sibling decision surfaced in PR #10 review: use Traefik's `IngressRoute` CRD (`traefik.io/v1alpha1`) vs. native Kubernetes `Ingress`.

| Option | Pros | Cons |
|--------|------|------|
| **Traefik `IngressRoute` (chosen)** | Native to the Traefik already committed to (AgDR-0004); cleaner multi-route handling for the web + `api.<domain>` host split; direct `certResolver` wiring for this AgDR's ACME resolver | Traefik-locked; `kubeconform -strict` must resolve the `traefik.io` CRD schema (CI supplies a schema-location or skips the kind); more to unwind if the cert-manager / non-Traefik revisit triggers fire |
| **Native `Ingress`** | Portable across controllers; validates under kubeconform out of the box; easier non-Traefik / cert-manager migration | TLS-via-resolver is annotation-driven and clunkier; loses Traefik-specific routing ergonomics |

Chosen: **`IngressRoute`**, because Traefik coupling is already accepted (AgDR-0004 ingress controller + this AgDR's cert resolver), the operator verified it working on k3d/K3s (PR #10, `http://marsa.gomaa.ovh/`), and the cleaner host-split routing is worth the lock-in at v0.1 scale.

Consequence: this **deepens** the kubeconform CRD consideration in the marsa-charts CI — `helm template | kubeconform -strict` must resolve (or `-skip`) both `traefik.io/v1alpha1/IngressRoute` and `helm.cattle.io/v1/HelmChartConfig`. Migrating off Traefik (revisit triggers above) now also means swapping `IngressRoute` → `Ingress`, not only the cert mechanism.

## Artifacts

- Ticket: [marsa-cloud/marsa-charts#9](https://github.com/marsa-cloud/marsa-charts/issues/9)
- PR: [marsa-cloud/marsa-charts#10](https://github.com/marsa-cloud/marsa-charts/pull/10) — `charts/marsa/templates/cert-resolver.yaml`, `ingress-route.yml`, `values.yaml` `tls` stanza
- Related AgDRs: [[AgDR-0004-subchart-policy]] (parent — public-ingress TLS split out here per its 2026-05-31 amendment), [[AgDR-0001-chart-structure]]
- Author: Hisham (Tech Lead) on behalf of Mohammad Gomaa
- Date: 2026-05-31
