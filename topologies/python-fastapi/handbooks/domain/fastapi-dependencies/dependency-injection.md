---
paths:
  - "app/api/**"
  - "app/dependencies/**"
  - "app/main.py"
---

# Handbook: FastAPI Dependency Injection — wire the world correctly

**Scope:** PRs touching FastAPI routers, the `dependencies/` module, or `main.py` wiring.
**Enforcement:** advisory.

## The rule

FastAPI's `Depends(...)` is the project's dependency-injection primitive. Use it consistently:

| Resource | Pattern | Lifetime |
|---|---|---|
| Database session | `Depends(get_async_db)` — async generator yielding `AsyncSession` | Per-request |
| HTTP client | `Depends(get_http_client)` — module-level singleton wrapped in a getter | App lifetime |
| Service classes | `Depends(get_orders_service)` — constructed per-request with injected dependencies | Per-request |
| Current user | `Depends(get_current_user)` — JWT verification + DB lookup | Per-request |
| Settings | `Depends(get_settings)` — cached via `@lru_cache` | App lifetime |
| Request-scoped state (e.g. tenant context) | `Depends(get_tenant_context)` | Per-request |

| Anti-pattern | Why it's broken |
|---|---|
| Service classes instantiated inside route handlers | Loses testability; tests have to monkey-patch the constructor |
| Direct ORM access in route handlers (no service layer) | Couples HTTP to DB; the architecture handbook also flags this |
| `Depends` chains > 5 deep | Smells of over-engineering; flatten the wiring |
| Settings read via `os.environ.get(...)` inside a handler | Untestable; use a `Settings` Pydantic model + `Depends(get_settings)` |
| Per-request resource that's actually app-scoped (e.g. constructing a new HTTP client per request) | Wastes connection-pool capacity; creates resource leaks |

## Why

FastAPI's DI is a load-bearing feature: it's how you swap a real DB for a test DB, a real Stripe client for a fake, a real auth provider for a no-op. Skip the DI and tests have to monkey-patch globals; the design becomes brittle.

DI also documents the dependency graph at the route signature level. Reading a route handler's signature tells you exactly what the handler needs — no hidden imports, no global state.

## What Rex flags

Surface a finding when:

1. A route handler instantiates a service class directly (`service = OrdersService(...)`) instead of receiving it via `Depends`.
2. A route handler reads `os.environ.get(...)` or `os.getenv(...)` instead of receiving settings via `Depends(get_settings)`.
3. A `Depends` chain involves a session-scoped resource being treated as app-scoped (or vice versa) — common bug.
4. The `dependencies/` module returns service instances without injecting their dependencies (services constructed with hardcoded args).
5. A new resource is added (DB pool, HTTP client) without a corresponding `get_<resource>` provider in `app/dependencies/`.
6. `Depends(...)` is used inside a non-route function (e.g. a service method) — DI is for the router boundary, not deep call stacks.

## Sample finding

> **Dependency injection (FastAPI)** — `app/api/orders.py:14` instantiates `OrdersService(db=get_session())` inside the handler. Tests can't swap the service or the DB. Add a `get_orders_service` provider in `app/dependencies/services.py` that takes `db: AsyncSession = Depends(get_async_db)` and returns the service; route signature becomes `service: OrdersService = Depends(get_orders_service)`.
>
> **Dependency injection (FastAPI)** — `app/api/dashboard.py:8` reads `STRIPE_KEY = os.environ['STRIPE_KEY']` at the top of the file. The handler can't be tested without setting an env var. Move the key into a `Settings` Pydantic model under `app/config.py`, expose `get_settings()` via `@lru_cache`, and have the handler receive it via `Depends(get_settings)`.

## What's NOT a violation

- Singletons that are genuinely process-wide (`get_logger`) — fine to access directly.
- Constants in module scope (`MAX_PAGE_SIZE = 100`) — settings should go through `Settings`; constants don't need DI.
- Sub-dependencies via `Depends` in a dependency provider (a service's provider depending on a repo's provider) — that's the right shape; the chain is one of provider-to-provider, not handler-to-deep-call.
- `Depends(security_scheme)` for OAuth2 / JWT — that's a documented FastAPI pattern.

## Pattern — the standard dependency module

```python
# app/dependencies/__init__.py
from functools import lru_cache
from typing import AsyncGenerator

import httpx
from fastapi import Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db.session import async_session_factory


@lru_cache
def get_settings() -> Settings:
    return Settings()


async def get_async_db() -> AsyncGenerator[AsyncSession, None]:
    async with async_session_factory() as session:
        yield session


# App-lifetime HTTP client (constructed in main.py lifespan; this getter returns it)
_http_client: httpx.AsyncClient | None = None

def get_http_client() -> httpx.AsyncClient:
    if _http_client is None:
        raise RuntimeError("HTTP client not initialised — check main.py lifespan")
    return _http_client
```

```python
# app/dependencies/services.py
from fastapi import Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.dependencies import get_async_db
from app.services.orders_service import OrdersService


def get_orders_service(db: AsyncSession = Depends(get_async_db)) -> OrdersService:
    return OrdersService(db=db)
```

```python
# app/api/orders.py
from fastapi import APIRouter, Depends
from app.dependencies.services import get_orders_service
from app.services.orders_service import OrdersService

router = APIRouter()

@router.post("/orders", response_model=OrderResponse)
async def create_order(
    req: CreateOrderRequest,
    service: OrdersService = Depends(get_orders_service),
) -> OrderResponse:
    return await service.create(req)
```

Tests override the provider: `app.dependency_overrides[get_orders_service] = lambda: FakeOrdersService()`.
