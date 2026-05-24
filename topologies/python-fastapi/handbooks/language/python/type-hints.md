# Handbook: Type Hints (FastAPI variant)

**Scope:** PRs touching `**/*.py` files in a FastAPI project.
**Enforcement:** advisory.

## The rule

Every Python file in this codebase declares type hints on public function signatures AND class attributes. `mypy` must run in strict mode:

```toml
# pyproject.toml
[tool.mypy]
strict = true
warn_redundant_casts = true
warn_unused_ignores = true
warn_return_any = true
disallow_untyped_defs = true
disallow_incomplete_defs = true
check_untyped_defs = true
```

| Required | Pattern |
|---|---|
| Every public function | `def fetch_user(id: UserId) -> User \| None:` — no bare `def fetch_user(id):` |
| Every class attribute | `name: str`, `email: Email` — no untyped instance attrs |
| `Any` usage | Only with `# type: ignore[<error-code>]` AND a comment explaining why |
| `# type: ignore` (no error code) | Forbidden. Always pin the specific code: `# type: ignore[arg-type]` |
| Untyped third-party imports | Add to `pyproject.toml` `[[tool.mypy.overrides]]` with `ignore_missing_imports = true` and document why |

## Why

Python's runtime typing is weaker than TS or Go by default. `mypy --strict` is the only mechanism that brings Python close to the static guarantees we'd otherwise have. Without strict mode, every `def fetch(id)` is implicitly `def fetch(id: Any) -> Any` and the type checker pulls zero weight.

FastAPI specifically uses type hints AT RUNTIME (for OpenAPI generation, request validation, dependency injection). A bare `def get_user(id)` route handler with no hints produces invalid OpenAPI, silent type errors, and dependency-injection failures that surface only at request time. Type hints in FastAPI are load-bearing infrastructure, not documentation.

## What Rex flags

Surface a finding when:

1. A new function in `app/` is added without a return type annotation (`-> ...`).
2. A new function parameter doesn't have a type annotation (`def foo(bar):` instead of `def foo(bar: Bar):`).
3. A class instance attribute is set in `__init__` without a class-level annotation.
4. `Any` is used without a `# type: ignore[code]` comment AND a justification.
5. `# type: ignore` appears WITHOUT a specific error code.
6. `pyproject.toml`'s `[tool.mypy]` section is removed or weakened (`strict = false`, `disallow_untyped_defs = false`).
7. A FastAPI route handler returns a Pydantic model but doesn't declare `-> ResponseModel` in the signature — the OpenAPI schema will be wrong.

## Sample finding

> **Type hints (FastAPI)** — `app/api/orders.py:18` declares `async def create_order(order):` — no parameter type, no return type. FastAPI uses type hints at runtime for request validation; without `order: CreateOrderRequest`, the body isn't validated and the OpenAPI schema is empty. Add the annotation.
>
> **Type hints (FastAPI)** — `app/services/users.py:24` uses `# type: ignore` without a code. Pin to the specific error: `# type: ignore[arg-type]  reason: sqlalchemy's Column doesn't narrow to str in this context`.

## What's NOT a violation

- Stub `__init__.py` files (empty or import-only) — no functions to annotate.
- Test code under `tests/` — `mypy --strict` is excluded by convention; tests use `pytest.fixture` shapes that don't play well with strict mode.
- Generated code (Alembic migrations under `alembic/versions/`) — out of scope; flag the generator config if it produces too much un-typed code.
- `Any` for catch-everything signature in framework internals (a decorator that wraps arbitrary callables) — must have a comment.

## Recipe — fixing untyped legacy code

If you're touching a file that has untyped functions:

1. **Pyright/mypy --strict tells you exactly what's missing.** Run `mypy app/<file>.py --strict` and address each error.
2. **For dynamic boundaries** (request bodies, JSON parses), use Pydantic. Pydantic parses untyped data into a typed value at the boundary; the rest of the code holds typed values.
3. **For ORM rows**, SQLAlchemy 2.0's typed `Mapped[T]` annotations close the gap. Migrate from 1.x-style `Column(String)` to `Mapped[str]`.
4. **For external libraries with no type stubs**, install the `<package>-stubs` if it exists. Failing that, add the import to `tool.mypy.overrides` with a justification.

The first three are mechanical. The fourth is a sprint-scale cleanup.
