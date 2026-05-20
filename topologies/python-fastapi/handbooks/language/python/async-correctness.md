# Handbook: Async Correctness (FastAPI variant)

**Scope:** PRs touching `**/*.py` files in a FastAPI project.
**Enforcement:** advisory.

## The rule

FastAPI runs on an asyncio event loop. Sync work that blocks the event loop blocks the whole process. Follow these rules:

| Pattern | Rule |
|---|---|
| Route handlers doing async work | `async def` |
| Route handlers doing only fast in-memory work | `def` is fine (FastAPI offloads to a threadpool) |
| Blocking I/O (sync DB driver, `requests.get`, `time.sleep`) inside an `async def` | NEVER — use the async equivalent (`asyncpg`/`aiosqlite`, `httpx`, `asyncio.sleep`) |
| Mixing sync and async DB sessions | NEVER — pick one (async session OR sync session per project, not both) |
| `await` on a blocking call | Always — never call an async function without awaiting (it returns a coroutine object) |
| Background tasks via `asyncio.create_task` | Only when the task is OK to lose on shutdown; otherwise use a proper queue (Celery, ARQ) |
| `asyncio.run` inside a request | NEVER — you're already in a loop; nested loops crash |

## Why

FastAPI's concurrency model is event-loop-based, not thread-based. A single `time.sleep(1)` inside an async handler stops the loop for that second — every other request on that worker also waits. With async sleep (`await asyncio.sleep(1)`), the loop services other requests during the wait.

The most insidious bug is the **mixed sync/async DB session**. SQLAlchemy 2.0 supports both, but using a sync `Session` inside an `async def` handler silently blocks the event loop on every query. The tests pass (the test client doesn't care); production tail latency explodes.

## What Rex flags

Surface a finding when:

1. An `async def` function imports `requests` (sync HTTP client) or calls `time.sleep`.
2. A function returns a coroutine without `await` (`result = some_async_func()` instead of `result = await some_async_func()`).
3. An `async def` handler uses `Session` (sync) instead of `AsyncSession`.
4. `asyncio.create_task` is called without a reference to the returned task — fire-and-forget tasks get garbage-collected.
5. `asyncio.run(...)` is called inside a route handler.
6. `time.sleep`, `socket.recv`, or other blocking calls appear in `async def` functions.
7. A FastAPI dependency (`Depends(...)`) is `def` but performs I/O — should be `async def` so the loop isn't blocked.

## Sample finding

> **Async correctness** — `app/api/orders.py:14` is `async def create_order(...)` but calls `requests.post('https://...')`. `requests` is sync; the call blocks the event loop. Switch to `httpx.AsyncClient` and `await client.post(...)`.
>
> **Async correctness** — `app/services/users_service.py:8` calls `result = self.repo.get_by_id(id)` where `get_by_id` is `async def`. Missing `await` — `result` is a coroutine, not a `User`. Add `await` (and have mypy catch this for you — `--strict` flags missing awaits).
>
> **Async correctness** — `app/api/dashboard.py:5` uses `db: Session = Depends(get_db)` inside an `async def` handler. Sync session blocks the event loop on every query. Switch to `db: AsyncSession = Depends(get_async_db)` and update queries to `await db.execute(...)`.

## What's NOT a violation

- A sync `def` route handler — FastAPI offloads it to a threadpool; safe for CPU-bound work or sync libraries.
- A sync utility function called from a sync handler — no event loop concern.
- `asyncio.create_task(some_coro)` with the task stored in a long-lived list — fire-and-forget IS the design; just ensure the reference is held.
- Test code using `asyncio.run(...)` to bootstrap a test loop — that's the test client's responsibility; flag only in production code.

## Pattern — the standard async handler

```python
# app/api/orders.py
from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession
import httpx

from app.dependencies import get_async_db, get_http_client
from app.api.schemas.orders import CreateOrderRequest, OrderResponse

router = APIRouter()

@router.post("/orders", response_model=OrderResponse, status_code=201)
async def create_order(
    req: CreateOrderRequest,
    db: AsyncSession = Depends(get_async_db),
    http: httpx.AsyncClient = Depends(get_http_client),
) -> OrderResponse:
    # Async DB
    order = await db.execute(...)
    await db.commit()

    # Async HTTP
    response = await http.post("https://inventory-service/decrement", json={...})
    response.raise_for_status()

    return OrderResponse.model_validate(order)
```

Every I/O call is `await`ed; the handler is fully async; the event loop isn't blocked.

## Recipe — migrating a sync handler to async

1. **Change `def` → `async def`.** This is the cosmetic part.
2. **Replace sync clients with async clients.** `requests` → `httpx`; sync `Session` → `AsyncSession`; `redis.Redis` → `redis.asyncio.Redis`.
3. **Add `await` to every I/O call.** mypy catches the missed ones; tests catch the rest.
4. **Update dependencies.** If `get_db()` returns a sync `Session`, write a sibling `get_async_db()` returning `AsyncSession`. Migrate handlers one at a time.

A mixed sync/async codebase is uncomfortable but workable during migration. Pick a target (everything async, or everything sync) and don't ship new code in the deprecated style.
