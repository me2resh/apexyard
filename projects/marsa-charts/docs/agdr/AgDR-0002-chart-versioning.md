# AgDR-0002 — Chart versioning policy: hybrid (chart SemVer, appVersion tracks marsa)

> In the context of preparing to publish the first Marsa Helm chart release, facing a choice between independent / lockstep / hybrid versioning, I decided that **chart `version` follows independent SemVer per chart change** while `appVersion` tracks the upstream `marsa` app release, accepting that operators need to read release notes to understand which of the two moved and why.

## Context

- Helm charts carry two distinct version fields: `version:` (the chart artifact) and `appVersion:` (the application the chart deploys).
- Marsa's chart is an umbrella per [[AgDR-0001-chart-structure]] — one chart packaging the whole product.
- Chart-only changes (template typo, default value tweak, new optional values flag, CI fix) happen at a different cadence than app-level changes (new Marsa feature, image bump).
- We're greenfield: no published release yet, so a wrong policy locks nothing in until v1.0 ships.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Independent SemVer for both `version` and `appVersion`** — both move independently per-component | Maximum flexibility | Implies the chart has a lifecycle distinct from the app; we're an umbrella chart with no such split |
| **Lockstep** — chart `version` = `appVersion` = marsa release | Trivial to reason about; one version moves at a time | A chart-only fix (template typo) forces a fake marsa app version bump, polluting the marsa release history |
| **Hybrid — `appVersion` tracks marsa, `version` is independent SemVer on chart-only changes** | Helm community standard (bitnami, kube-prometheus-stack, ingress-nginx, cert-manager); separates "what runs" from "what installed it" cleanly | Operators have two version numbers to follow; release notes must say which moved and why |

## Decision

Chosen: **Hybrid.** Specifically:

- `appVersion:` is set to the marsa app release this chart packages (e.g. `appVersion: "0.1.0"` when shipping marsa v0.1.0).
- `version:` is the chart's own SemVer (e.g. `version: 0.1.0` initially, `0.1.1` on a chart-only fix, `0.2.0` when adding values flags).
- A new marsa release triggers a chart bump that updates `appVersion` AND default image tags AND increments `version` by patch (e.g. chart `0.1.5` → `0.1.6` because chart changed) or minor (when new values options are added to consume new app capabilities).
- A chart-only fix bumps `version` only; `appVersion` stays put.

This matches the Helm community standard. Operators familiar with charts of this shape (bitnami, kube-prometheus-stack) will not be surprised.

## Consequences

- **Release ergonomics:** every chart release writes a release note section like "chart 0.1.5 — bumped appVersion to marsa 0.1.4" or "chart 0.1.5 — fixed default Redis memory limit, appVersion unchanged".
- **Marsa app release → chart bump automation:** [#5](https://github.com/marsa-cloud/marsa-charts/issues/5) close-out implies a manual PR for now; a CI hook that auto-files the chart bump PR on a marsa release is a future enhancement, not part of this AgDR.
- **`Chart.yaml` schema:** both `version` and `appVersion` are required from day one. CI (#3) will validate `appVersion` is a real marsa release tag.
- **values.yaml `image.tag`:** defaults to the version matching `appVersion` so a `helm install` with no overrides Just Works. Bumping `appVersion` without bumping the default image tag is a CI failure.
- **Trigger to revisit:** if marsa's release cadence diverges sharply from chart change frequency (e.g. marsa ships weekly but chart sees one change a quarter — or vice versa), reconsider whether the convenience of hybrid still wins.

## Artifacts

- Ticket: [marsa-cloud/marsa-charts#5](https://github.com/marsa-cloud/marsa-charts/issues/5)
- Related AgDRs: [[AgDR-0001-chart-structure]] (single umbrella → one version line, not many)
- Related open tickets: [#3](https://github.com/marsa-cloud/marsa-charts/issues/3) (CI), [#4](https://github.com/marsa-cloud/marsa-charts/issues/4) (README), [#6](https://github.com/marsa-cloud/marsa-charts/issues/6) (distribution), [#7](https://github.com/marsa-cloud/marsa-charts/issues/7) (subchart policy)
- Author: Hisham (Tech Lead) on behalf of Mohammad Gomaa
- Date: 2026-05-29
