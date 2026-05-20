# {Short Title — e.g. "Choosing async vs sync DB sessions for the orders service"}

> In the context of {context — FastAPI project, what feature drove the decision}, facing {concern — e.g. "production latency on the order-listing endpoint"}, I decided {decision — e.g. "migrate the orders service to AsyncSession + asyncpg"} to achieve {goal — e.g. "release the event loop on every DB call"}, accepting {tradeoff — e.g. "sync and async sessions coexist during migration; one-off code paths for tests"}.

## Context

{Decision-relevant context only. What part of the FastAPI stack triggered this? Async vs sync DB, ORM choice, auth provider, deployment target (Kubernetes / serverless / VM)?}

## Options Considered

> ApexYard's Python-FastAPI topology v1.0.0 ships this template with stack-specific option prompts. Fill in the rows that apply; delete the rest. Don't feel obliged to consider every option — pick the 2-3 that were genuinely on the table.

### A) ORM / data access

| Option | Pros | Cons | Picked? |
|--------|------|------|---------|
| **SQLAlchemy 2.0 async** | Standard, typed (`Mapped[T]`), great migration story (Alembic) | Heavier than alternatives; learning curve | |
| **SQLAlchemy 2.0 sync** | Same ecosystem, simpler mental model | Blocks the event loop unless used via `run_in_executor` | |
| **Tortoise ORM** | Native async, Django-like API | Smaller ecosystem; migration tooling less mature | |
| **SQLModel** | Pydantic + SQLAlchemy unified | Project less active; v2 migration story unclear | |
| **asyncpg + raw SQL** | Fastest, no abstraction layer | No type safety on queries; no migration tooling | |
| **Encode databases** | Lightweight async; works with multiple drivers | Smaller community; some quirks under load | |

### B) Auth strategy

| Option | Pros | Cons | Picked? |
|--------|------|------|---------|
| **JWT (asymmetric — RS256)** | Stateless, scales horizontally, no session table | Token revocation is hard; key rotation needs care | |
| **JWT (symmetric — HS256)** | Simpler key management | Same secret on every service; harder to rotate | |
| **Session cookies (server-stored)** | Easy revocation, simpler token shape | Stateful; needs Redis or DB session store | |
| **OAuth2 + external IdP (Auth0, Clerk, etc.)** | Off-the-shelf, MFA + SSO included | Vendor lock-in; cost at scale | |
| **API keys** | Trivial for service-to-service | Bad UX for end users; rotation overhead | |

### C) Background jobs

| Option | Pros | Cons | Picked? |
|--------|------|------|---------|
| **Celery + Redis** | Battle-tested, broad community | Heavy; complex result-backend story | |
| **ARQ** | Async-native, simple, Redis-backed | Smaller community | |
| **FastAPI BackgroundTasks** | Built-in, zero deps | Fire-and-forget; no retry, no persistence | |
| **AWS SQS + a worker service** | Decouples scaling | Extra service to operate | |
| **Temporal / Inngest** | Durable workflows | $$$; learning curve | |

### D) Deployment target

| Option | Pros | Cons | Picked? |
|--------|------|------|---------|
| **Kubernetes (uvicorn behind Ingress)** | Full control, horizontal scaling, multi-region | Operational overhead | |
| **AWS Lambda + Mangum** | Serverless, pay-per-request | Cold-start latency; FastAPI's async story is awkward in Lambda | |
| **Google Cloud Run / AWS App Runner** | Container, auto-scaling, no cluster | Less flexibility than k8s | |
| **Single VM + systemd** | Cheapest for low traffic | No HA; manual scaling | |
| **Fly.io / Railway** | Easy deploy, good DX | Vendor lock-in | |

### E) Testing strategy

| Option | Pros | Cons | Picked? |
|--------|------|------|---------|
| **pytest + TestClient + docker-compose Postgres** | Fast, realistic, full stack | DB-bound; CI startup time | |
| **pytest + httpx.AsyncClient + sqlite-in-memory** | Very fast | SQLite ≠ Postgres; some queries diverge | |
| **pytest + TestClient + transaction-rollback fixtures** | Fast, real DB, isolated | Fixture complexity | |
| **End-to-end via Playwright/curl against a deployed env** | Tests the real boundary | Slow; flaky on infra hiccups | |

## Decision

Chosen: **{the option}**, because {2-3 sentences naming the load-bearing reason. Reference the topology's ambient affordances if applicable — e.g. "topology assumes async; sticking with AsyncSession keeps the async-correctness handbook applicable"}.

## Consequences

- {Specific consequence for the codebase}
- {Consequence for dev workflow — migrations, testing, env management}
- {Consequence for deploy}
- {Consequence for tests}

## Artifacts

- {Commit / PR links}
- {Updated configs — `pyproject.toml`, `alembic.ini`, `app/config.py`}
- {Affected handbooks}

## What this decision does NOT cover

- {Be explicit about scope}
- {Future AgDRs if applicable}
