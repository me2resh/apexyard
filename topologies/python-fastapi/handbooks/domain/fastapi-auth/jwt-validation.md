---
paths:
  - "app/auth/**"
  - "app/api/auth/**"
  - "app/dependencies/auth.py"
  - "app/middleware/**"
---

ENFORCEMENT: blocking

# Handbook: JWT validation — auth boundaries in FastAPI

**Scope:** PRs touching the auth subsystem.
**Enforcement:** **blocking** — security-critical surface.

## The rule

Every protected route validates the JWT **at the boundary**, via a `Depends(get_current_user)` dependency. The dependency:

1. Reads the `Authorization: Bearer <token>` header.
2. Verifies the signature using the configured public key (asymmetric) or shared secret (symmetric, less preferred).
3. Verifies the `exp` (expiration) claim.
4. Verifies the `iss` (issuer) claim against the configured value.
5. Verifies the `aud` (audience) claim against the configured value.
6. Loads the user record from the DB (don't trust the token's `sub` claim alone — the user might have been deleted/suspended).
7. Returns the typed `User` (or raises `HTTPException(401)`).

| Required | Not negotiable |
|---|---|
| Signature verification | YES — never decode without verification (`jwt.decode(token, options={"verify_signature": False})` is forbidden outside test code) |
| Algorithm pinning | YES — pass `algorithms=["RS256"]` explicitly; never trust the `alg` in the token header (algorithm-confusion attack) |
| Expiration check | YES — let `python-jose` / `pyjwt` handle it via the verify call; don't manually parse `exp` |
| DB lookup | YES — token validity ≠ user validity (deleted, suspended, password-changed since issue) |
| Token in URL query string | NEVER — tokens belong in headers, NEVER in `?token=` (gets logged everywhere) |
| Token in browser cookies | OK for first-party web (HTTP-only, Secure, SameSite=Strict); avoid for API-only services |

## Why

JWT is footgun-shaped. Three classes of CVE keep recurring:

1. **`alg=none` acceptance** — token says `{"alg":"none"}`, library accepts without signature. Pin algorithms explicitly.
2. **HMAC-vs-RSA confusion** — token signed with the public key as an HMAC secret. Pin algorithms explicitly.
3. **Outdated token honoured** — user reset their password / was suspended, but old tokens still work because the verifier only checks `exp`. Always DB-lookup.

The blocking enforcement matches the cost — a JWT validation bug usually leaks data or escalates privilege. Not the kind of finding that should sit advisory.

## What Rex flags (BLOCKING)

Surface a **request-changes** finding when:

1. A new protected route doesn't include `Depends(get_current_user)` (or a documented dependency that wraps it).
2. The `get_current_user` dependency calls `jwt.decode(...)` without `algorithms=["..."]` pinned.
3. `jwt.decode(...)` is called with `options={"verify_signature": False}` outside of test code.
4. The dependency reads the JWT but doesn't perform a DB lookup of the user (uses claim data directly).
5. A token is read from `request.query_params` or `request.url` (token in URL).
6. The `iss` and `aud` claims aren't verified in the dependency.
7. A custom auth dependency is added that doesn't go through the central `get_current_user` (multiple auth paths increase the surface — one canonical path).

## Sample finding

> **JWT validation (BLOCKING)** — `app/auth/jwt.py:18` calls `jwt.decode(token, key)` without `algorithms=["RS256"]`. The library default is permissive — an attacker can send a token with `alg=HS256` and the public key as the HMAC secret. Pin: `jwt.decode(token, key, algorithms=["RS256"], audience=settings.audience, issuer=settings.issuer)`.
>
> **JWT validation (BLOCKING)** — `app/dependencies/auth.py:12` extracts `user_id = payload["sub"]` and returns `User(id=user_id, ...)` without a DB lookup. If the user was deleted/suspended after the token was issued, the old token still works. Add `user = await db.get(User, user_id); if user is None or user.suspended: raise HTTPException(401)`.

## What's NOT a violation

- Public routes that explicitly opt out — `@router.get("/health", dependencies=[])` is fine for health checks. Mark with `# public: no auth required` comment.
- Webhook handlers using signature verification (Stripe, GitHub) — different mechanism, same principle (verify before trust); don't use `get_current_user` for those.
- API-key auth on a separate sub-router — fine if it goes through its own `get_api_key_user` dependency that follows the same principles (signature verification, key lookup).
- Test fixtures that mock `get_current_user` via `app.dependency_overrides` — explicit and isolated.

## The standard pattern

```python
# app/dependencies/auth.py
from typing import Annotated
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError, jwt
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.dependencies import get_settings, get_async_db
from app.db.models import User

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="auth/login")

async def get_current_user(
    token: Annotated[str, Depends(oauth2_scheme)],
    settings: Settings = Depends(get_settings),
    db: AsyncSession = Depends(get_async_db),
) -> User:
    credentials_error = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(
            token,
            settings.jwt_public_key,
            algorithms=["RS256"],
            audience=settings.jwt_audience,
            issuer=settings.jwt_issuer,
        )
    except JWTError:
        raise credentials_error

    user_id = payload.get("sub")
    if not user_id:
        raise credentials_error

    user = await db.get(User, user_id)
    if user is None or user.suspended:
        raise credentials_error

    return user
```

Every protected route signature is now:

```python
@router.get("/orders", response_model=list[OrderResponse])
async def list_orders(
    user: User = Depends(get_current_user),
    service: OrdersService = Depends(get_orders_service),
) -> list[OrderResponse]:
    return await service.list_for_user(user.id)
```

## Threat-model link

Run `/threat-model` against the auth subsystem after the first handover. The threat model captures Spoofing + Tampering + Disclosure scenarios specific to JWT; this handbook enforces the rules that close them.
