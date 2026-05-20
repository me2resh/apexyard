# Handbook: Pydantic Models (FastAPI variant)

**Scope:** PRs touching `**/*.py` files in a FastAPI project, especially `app/api/**` and `app/schemas/**`.
**Enforcement:** advisory.

## The rule

Pydantic v2 is the validation boundary for every HTTP request and response. Follow these patterns:

| Pattern | Required |
|---|---|
| Request models | `class CreateOrderRequest(BaseModel)` — used as the route handler's body parameter |
| Response models | Separate from request models — `class OrderResponse(BaseModel)` — declared via `response_model=` on the route |
| Domain entities | NOT Pydantic models — use `@dataclass` or plain classes; Pydantic is for the HTTP boundary, not the domain |
| `Field(...)` constraints | Use Pydantic's `Field(min_length=..., max_length=..., pattern=...)` for validation; don't reinvent in route handler |
| `ConfigDict(extra="forbid")` | Default for request models — reject unknown fields rather than silently dropping |
| ORM serialisation | Use `from_attributes=True` in `model_config` when constructing from SQLAlchemy rows |

| Anti-pattern | Why it's broken |
|---|---|
| One Pydantic model used for request + response + DB row | Conflates three boundaries; changes to one ripple into the others. The model becomes huge. |
| Pydantic models in `app/domain/` | The domain shouldn't know about HTTP serialisation. Use dataclasses; map at the boundary. |
| `BaseModel` without `ConfigDict(extra="forbid")` for requests | Silently drops unknown fields — typo'd field names become invisible bugs. |
| `dict[str, Any]` as a response type | No OpenAPI schema; clients can't generate types; the contract is invisible. |

## Why

FastAPI's killer feature is that Pydantic validates request bodies at runtime AND generates OpenAPI schemas from the same models. When you skip Pydantic at the boundary, you lose both: validation falls back to ad-hoc checks in the route handler, and the OpenAPI schema is empty.

The reason to keep Pydantic OUT of the domain layer is the inverse — the domain shouldn't be coupled to a serialisation library. If you put Pydantic in the domain, changing serialisation strategy (e.g. switching to `msgspec` for performance) requires touching every domain class.

## What Rex flags

Surface a finding when:

1. A new route handler's body parameter is `dict` or `Any` instead of a Pydantic model.
2. A route handler returns a domain entity (dataclass) without declaring `response_model=` AND without a mapping step.
3. A Pydantic request model lacks `ConfigDict(extra="forbid")` (or v1-style `class Config: extra = "forbid"`).
4. A Pydantic model is used as both the request body AND the response (look for the same class name as both param annotation and return type).
5. A file under `app/domain/` imports `from pydantic import BaseModel`.
6. A response model serialises a SQLAlchemy ORM row directly without `from_attributes=True`.
7. A `Field` constraint is duplicated in route handler validation (e.g. `if len(req.name) > 100: raise ...` when `Field(max_length=100)` would do the same).

## Sample finding

> **Pydantic (FastAPI)** — `app/api/users.py:14` accepts `body: dict` as the request body. The OpenAPI schema for this endpoint is empty; clients can't generate types and the body isn't validated. Define `class CreateUserRequest(BaseModel): name: str; email: EmailStr` and use it as the parameter.
>
> **Pydantic (FastAPI)** — `app/api/orders.py:8` uses `OrderRequest` as both the request body AND the response. Requests have user-supplied fields (no `id`, no `created_at`); responses include server-side fields. Split into `CreateOrderRequest` and `OrderResponse`.
>
> **Pydantic (FastAPI)** — `app/api/users.py:22` returns the SQLAlchemy `User` row directly. The response will serialise correctly if `UserResponse` declares `model_config = ConfigDict(from_attributes=True)`, otherwise Pydantic v2 won't read ORM attributes. Add the config and a `.model_validate(user)` call.

## What's NOT a violation

- `dict[str, str]` as a small inline response (e.g. health-check returning `{"status": "ok"}`) — pragmatic for trivial endpoints.
- Pydantic models in `app/schemas/` (a common alternative to `app/api/schemas.py`) — same intent, different naming.
- Inheritance between request and response models (`OrderResponse(OrderBase)`, `CreateOrderRequest(OrderBase)`) — sharing a base is fine; using the same concrete class is not.
- `Field(default=...)` for sensible defaults — that's exactly what `Field` is for.

## Pattern — the standard request/response pair

```python
# app/api/schemas/orders.py
from pydantic import BaseModel, ConfigDict, Field
from datetime import datetime
from uuid import UUID

class CreateOrderRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    product_id: UUID
    quantity: int = Field(ge=1, le=1000)
    notes: str | None = Field(default=None, max_length=500)


class OrderResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    product_id: UUID
    quantity: int
    notes: str | None
    created_at: datetime
    status: str
```

```python
# app/api/orders.py
from fastapi import APIRouter, Depends
from app.api.schemas.orders import CreateOrderRequest, OrderResponse
from app.services.orders_service import OrdersService

router = APIRouter()

@router.post("/orders", response_model=OrderResponse, status_code=201)
async def create_order(
    req: CreateOrderRequest,
    service: OrdersService = Depends(get_orders_service),
) -> OrderResponse:
    order = await service.create(req.product_id, req.quantity, req.notes)
    return OrderResponse.model_validate(order)
```

## v1 vs v2 migration note

If the codebase is still on Pydantic v1 (`class Config:` instead of `model_config = ConfigDict(...)`), file a migration ticket to bump to v2 — v1 is on borrowed time and v2's strict-mode + better mypy story is materially worth the cost.
