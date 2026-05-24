---
paths:
  - "app/api/**"
  - "app/exceptions/**"
  - "app/main.py"
---

# Handbook: Exception handlers — FastAPI error responses

**Scope:** PRs touching FastAPI routers, exception handlers, or domain exception types.
**Enforcement:** advisory.

## The rule

Every error path returns a typed JSON response with a stable shape. Use FastAPI's exception-handler registration to centralise the mapping:

| Layer | What it raises | What the client sees |
|---|---|---|
| Domain (`app/domain/`) | Domain-specific exceptions: `OrderNotFoundError`, `InsufficientStockError` | n/a (caught at the API boundary) |
| Service (`app/services/`) | Re-raises domain exceptions or wraps with context | n/a |
| API (`app/api/`) | Lets domain exceptions bubble; raises `HTTPException` for HTTP-specific errors (401, 403, etc.) | Mapped to JSON by global handler |
| `app/main.py` | Registers `@app.exception_handler(DomainError)` for each handled domain exception | JSON response with stable shape: `{"detail": "...", "code": "...", "field": "..."}` |

| Anti-pattern | Why it's broken |
|---|---|
| `raise HTTPException(status_code=500, detail=str(e))` in a service | Leaks internal error messages to clients; couples service to HTTP |
| Bare `try/except Exception: pass` | Swallows errors silently; debugging becomes archaeology |
| Different error response shapes for different endpoints (`{"error": "..."}` here, `{"message": "..."}` there) | Client code can't have a single error handler |
| Stack traces in production responses | Information disclosure (file paths, library versions) |
| Returning `200 OK` with `{"error": "..."}` body | HTTP status is meaningful — use it |

## Why

Untyped error handling is the source of most "the API behaves weirdly when X" bug reports. A client receiving `{"error": "..."}` from one endpoint and `{"detail": "..."}` from another can't write robust code. Worse, when a service raises a domain exception that bubbles unhandled, FastAPI returns a generic 500 with a stack trace — information disclosure.

Centralised exception handling fixes both: one place to map exceptions to responses, one consistent shape, no leaked internals.

## What Rex flags

Surface a finding when:

1. A new route handler raises `HTTPException` with a `detail` that interpolates an exception's `str()` (`detail=str(e)` — leaks internals).
2. A service layer function raises `HTTPException` — services shouldn't know HTTP. Raise a domain exception instead.
3. A `try/except Exception: pass` or `try/except: ...` (bare except) appears anywhere in `app/`.
4. A new domain exception class is added without a corresponding `@app.exception_handler(...)` registration in `main.py`.
5. A route handler returns a 200 with an error body (e.g. `return {"error": "not found"}` instead of `raise HTTPException(404)`).
6. An exception handler returns a different response shape than the rest of the codebase (inconsistent error envelope).

## Sample finding

> **Exception handlers (FastAPI)** — `app/api/orders.py:18` catches `OrderNotFoundError` and raises `HTTPException(404, detail=str(e))`. This couples the API to the domain exception's string representation. Register a global handler in `main.py`: `@app.exception_handler(OrderNotFoundError) async def handle_not_found(req, exc): return JSONResponse(404, {"detail": "Order not found", "code": "order_not_found"})`.
>
> **Exception handlers (FastAPI)** — `app/services/payments_service.py:24` raises `HTTPException(402, "Payment failed")`. Services shouldn't know about HTTP. Define `PaymentFailedError(DomainError)` in `app/exceptions.py`, raise that from the service, and map it to 402 in the global handler.

## What's NOT a violation

- `raise HTTPException(401)` inside the `get_current_user` dependency — that IS the HTTP boundary; HTTPException is the right primitive.
- `raise HTTPException(400)` from a route handler for HTTP-specific validation that Pydantic didn't catch (e.g. cross-field constraints) — HTTP-shaped failure at the HTTP boundary is fine.
- `try/except SpecificError: raise NewError("with context") from e` — chained exception handling is good; the lint targets bare `except` and silent `pass`.
- 200 OK with a body that has both data and a `warnings: []` array — that's a separate pattern (success with degradation info), not an error response.

## The standard pattern

```python
# app/exceptions.py
class DomainError(Exception):
    """Base for all domain-layer exceptions."""

class OrderNotFoundError(DomainError):
    def __init__(self, order_id: str):
        self.order_id = order_id
        super().__init__(f"Order {order_id} not found")

class InsufficientStockError(DomainError):
    def __init__(self, product_id: str, requested: int, available: int):
        self.product_id = product_id
        self.requested = requested
        self.available = available
        super().__init__(
            f"Product {product_id} has {available} in stock, requested {requested}"
        )
```

```python
# app/main.py
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from app.exceptions import OrderNotFoundError, InsufficientStockError

app = FastAPI()

@app.exception_handler(OrderNotFoundError)
async def handle_order_not_found(request: Request, exc: OrderNotFoundError) -> JSONResponse:
    return JSONResponse(
        status_code=404,
        content={
            "detail": "Order not found",
            "code": "order_not_found",
            "order_id": exc.order_id,
        },
    )

@app.exception_handler(InsufficientStockError)
async def handle_insufficient_stock(request: Request, exc: InsufficientStockError) -> JSONResponse:
    return JSONResponse(
        status_code=409,
        content={
            "detail": "Insufficient stock",
            "code": "insufficient_stock",
            "product_id": exc.product_id,
            "requested": exc.requested,
            "available": exc.available,
        },
    )
```

```python
# app/api/orders.py
from fastapi import APIRouter, Depends
from app.services.orders_service import OrdersService

router = APIRouter()

@router.get("/orders/{order_id}", response_model=OrderResponse)
async def get_order(
    order_id: str,
    service: OrdersService = Depends(get_orders_service),
) -> OrderResponse:
    # OrderNotFoundError bubbles; global handler turns it into 404 JSON
    order = await service.get_by_id(order_id)
    return OrderResponse.model_validate(order)
```

Every error response now follows the `{"detail", "code", ...context}` shape. Client code can write a single handler:

```typescript
// client-side
catch (err) {
  if (err.response?.data?.code === "order_not_found") { ... }
}
```

## Pattern — error logging

Exception handlers are the place to log unhandled errors. Catch a final `Exception` and log structured context (request path, user id, exception type) before returning a generic 500. Don't include the stack trace in the response body — but DO log it.
