# Handbook: Clean Architecture Layering (FastAPI variant)

**Scope:** all PRs in a FastAPI project.
**Enforcement:** advisory.

## The rule

A FastAPI codebase under ApexYard's Python topology is organised in four layers with a strict dependency direction:

```
domain/  ←  services/  ←  api/   ←  main.py + dependencies/
                          ↑
                        db/ (infrastructure)
```

| Layer | Maps to | What lives there | CAN import | CANNOT import |
|---|---|---|---|---|
| `app/domain/` | Plain dataclasses / Pydantic models without I/O | Entities, value objects, business invariants | `pydantic` (for shape), stdlib | `fastapi`, `sqlalchemy`, `httpx`, anything I/O |
| `app/services/` | Use cases | Service classes that orchestrate domain ops | `domain/`, ports (Protocols) | `fastapi`, ORM concrete classes |
| `app/api/` | FastAPI routers and request/response models | `APIRouter` definitions, Pydantic request/response schemas | `services/`, `domain/`, `fastapi`, `dependencies/` | `db/` directly — go through a service |
| `app/db/` | SQLAlchemy models, migrations, repositories | ORM models, repository classes implementing the ports | `domain/` (to construct entities), `sqlalchemy` | `api/`, `services/` (one-way arrow) |
| `app/dependencies/` | FastAPI DI providers | `Depends(get_db)`, `Depends(get_current_user)` | `services/`, `db/`, `fastapi` | (outermost — wires the world) |

## Why

Python's lack of compile-time module boundaries makes this layering more important than in TS or Go — there's no compiler error to catch a cross-layer import. The rule is enforced by review (this handbook) and by structuring `__init__.py` files to NOT re-export inner-layer types from outer layers.

When violated — e.g. a domain entity importing SQLAlchemy to fetch its own data — the domain becomes welded to the ORM. The team can't replace SQLAlchemy without a rewrite. Tests need a DB connection just to instantiate an entity. Three months in, the domain is just a thin wrapper around the ORM and provides zero abstraction value.

## What Rex flags

Surface a finding when:

1. A file under `app/domain/` imports from `fastapi`, `sqlalchemy`, `httpx`, `redis`, or any I/O library.
2. A file under `app/services/` imports concrete ORM classes from `app/db/` (should import the Protocol/port instead).
3. A file under `app/api/` imports from `app/db/` directly — should go through a service.
4. A Pydantic request/response model lives outside `app/api/` (e.g. in `app/domain/`) — request/response schemas are HTTP-boundary concerns; domain models are separate.
5. A repository in `app/db/` returns ORM model instances to the service layer (it should return domain entities — adapter pattern).

## Sample finding

> **Clean architecture (FastAPI)** — `app/api/users.py:12` imports `from app.db.models import User` and queries directly via `db.query(User).filter(...)`. The router shouldn't know about ORM models. Add a service in `app/services/users_service.py` that depends on a `UserRepository` Protocol; have `app/db/user_repository.py` implement it. The router calls `users_service.get_by_id(...)`.

## What's NOT a violation

- `app/dependencies/` importing from any layer — the dependencies module is the wiring point, by definition outermost.
- A migration script under `alembic/versions/` importing ORM models — migrations need the schema; that's their job.
- Tests under `tests/` cross-importing freely — test code is its own boundary.

## Why this is its own handbook (not the universal one)

The universal clean-architecture handbook names `src/domain/`, `src/application/`, `src/infrastructure/`. FastAPI projects conventionally use `app/<layer>/` and split out an explicit `dependencies/` for DI providers. This variant maps the universal rule onto that shape.
