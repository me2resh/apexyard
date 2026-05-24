# Topology: Python FastAPI Service

**Version**: 1.0.0
**Stack**: Python 3.11+ + FastAPI + Pydantic v2 + SQLAlchemy 2.0 + Alembic migrations + JWT auth
**Use this when**: building an HTTP service with persistence, JWT auth, OpenAPI documentation, and async request handling.

## What this topology bundles

Pick this topology in `/handover` and the skill instantiates:

| Layer | Files instantiated | Where they land |
|-------|--------------------|-----------------|
| Architecture handbooks | `clean-architecture-layers.md`, `migration-safety.md` (always-load, blocking) | `handbooks/architecture/` |
| Language handbooks | `type-hints.md`, `pydantic-models.md`, `async-correctness.md` | `handbooks/language/python/` |
| Domain handbooks | `fastapi-dependencies/dependency-injection.md`, `fastapi-auth/jwt-validation.md`, `fastapi-errors/exception-handlers.md` | `handbooks/domain/<area>/` (each has `paths:` frontmatter) |
| CI pipeline | `fastapi-ci.yml` (mypy + ruff + pytest + alembic check + uvicorn boot smoke) | `.github/workflows/` |
| AgDR template | `agdr-python-fastapi.md` (ORM choice, async vs sync DB, auth strategy prompts) | `docs/agdr/agdr-python-fastapi.draft.md` |

## Why pick this topology

FastAPI is the most opinionated Python web framework: Pydantic validates at the HTTP boundary, dependency injection is a first-class primitive, OpenAPI is generated for free, and the async story is well-defined. Combined with strict mypy + SQLAlchemy 2.0's typed ORM, the **ambient affordances** are high for a Python project (which is saying something — Python's runtime typing is weaker than TS or Go by default).

If your codebase is Python but **not** FastAPI (Django, Flask, raw WSGI), this topology will over-fit. Run `/handover` without picking a topology.

## Ambient affordances this topology assumes

| Affordance | How it's provided | Why it matters to Rex |
|------------|-------------------|------------------------|
| Strict type hints | `mypy.ini` or `pyproject.toml` `[tool.mypy] strict = true` | Type-hint handbook can flag bare `Any` |
| Module boundaries | `app/api/` (HTTP layer), `app/services/` (business logic), `app/db/` (persistence), `app/domain/` (entities) | Clean-architecture handbook applies |
| Framework opinionation | FastAPI routing + DI + Pydantic validation throughout | Domain handbooks on DI and JWT are enforceable |
| Test coverage signal | `pyproject.toml` with `[tool.coverage]` block; `pytest-cov` configured | Coverage gates apply |
| Lint baseline | `ruff.toml` or `[tool.ruff]` in `pyproject.toml` | Ruff is the baseline; replaces flake8 + isort + bandit |

## Files in this bundle

```
python-fastapi/
├── VERSION
├── README.md
├── handbooks/
│   ├── architecture/
│   │   ├── clean-architecture-layers.md
│   │   └── migration-safety.md                              ← blocking (Alembic migrations)
│   ├── language/
│   │   └── python/
│   │       ├── type-hints.md
│   │       ├── pydantic-models.md
│   │       └── async-correctness.md
│   └── domain/
│       ├── fastapi-dependencies/
│       │   └── dependency-injection.md                      ← paths: app/api/**, app/dependencies/**
│       ├── fastapi-auth/
│       │   └── jwt-validation.md                            ← paths: app/auth/**, app/api/auth/**
│       └── fastapi-errors/
│           └── exception-handlers.md                        ← paths: app/api/**, app/exceptions/**
├── golden-paths/
│   └── fastapi-ci.yml
└── templates/
    └── agdr-python-fastapi.md
```
