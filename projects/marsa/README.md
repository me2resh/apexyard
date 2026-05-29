# marsa

Open-source, self-hostable Platform as a Service (PaaS). The core product (P0, customer-facing) in the marsa-cloud portfolio.

- **Repo**: https://github.com/marsa-cloud/marsa
- **Stack**: pnpm monorepo — NestJS 11 + MikroORM + PostgreSQL API (`apps/api`); Nuxt 4 + Vue web (`apps/web`); OpenAPI-typed contract between them.
- **Status**: handover → active

## Docs in this folder

- [`handover-assessment.md`](handover-assessment.md) — handover assessment + harnessability score (2026-05-27)
- [`architecture/container.md`](architecture/container.md) — C4 L2 container diagram (auto-generated stub, refine over time)

## Related projects

- `marsa-charts` — Helm charts for deploying Marsa
- `example-todo-app` — sample app to demo/dogfood Marsa deployments
