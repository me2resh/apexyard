# AgDR-0216: Isolate hook tests from the live session pin and caches

> For issue #1549, I chose a per-suite isolation helper plus a runner env wrapper so hook tests cannot overwrite `~/.claude/apexyard` pins or resolve-cache files when run under a live Claude Code / Cursor session.

## Context

Hooks write per-session state under `${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/`:
`ops-root-<CLAUDE_CODE_SESSION_ID>` and `resolve-cache-<CLAUDE_CODE_SESSION_ID>-*`.
A live agent shell exports that session id. Direct `bash test_*.sh` inherited it and overwrote the operator's real pin and caches.

Runner-only exports (`APEXYARD_OPS_DISABLE_PIN`, `APEXYARD_DISABLE_RESOLUTION_CACHE`) were not enough: they did not cover direct invocation, and they left `CLAUDE_CODE_SESSION_ID` / `APEXYARD_OPS_PIN_DIR` pointing at the live location.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Runner-only env wrapper | One place to change. | Direct `bash test_*.sh` still pollutes. |
| Per-suite helper source + runner belt-and-suspenders | Protects both entry points. | 178 includes to maintain; needs a lint. |
| Chroot / fake `$HOME` for every suite | Strong isolation. | Heavy; breaks suites that intentionally use `$HOME`. |

## Decision

Chosen: **per-suite helper + runner wrapper + required-helper lint + write-capable regression**, because direct and runner entry points both need coverage, and a read-only smoke suite cannot prove the pin stays untouched.

Helper behaviour:

- unset `CLAUDE_CODE_SESSION_ID`
- `APEXYARD_OPS_DISABLE_PIN=1`
- `APEXYARD_DISABLE_RESOLUTION_CACHE=1`
- `APEXYARD_OPS_PIN_DIR` → disposable temp dir (shared via `_APEXYARD_TEST_PIN_DIR` when the runner sets it)

Include path uses `${BASH_SOURCE[0]:-$0}` so `source ./test_foo.sh` still finds the helper (plain `$0` is `/bin/bash` when sourced).

Pin-behaviour suites (`test_resolve_ops_root_pin.sh`, `test_resolution_cache.sh`) unset the disable flags and set a private pin dir per case after sourcing the helper, so their assertions stay non-vacuous.

## Consequences

- Direct `bash test_*.sh` under a live session no longer mutates `~/.claude/apexyard`.
- The required-helper check fails closed when a hook-invoking suite omits the include or uses `$0` instead of `BASH_SOURCE`.
- The regression suite proves overwrite without the helper and byte-identity with it, using a write-capable mini suite (not a read-only lib smoke test).
- The runner removes the shared suite pin dir on EXIT so a full run does not leave ~N temp directories.

## Architecture evolution

### Before

Isolation was runner-only. Suites that sourced libs or called `pin-ops-root.sh` under an inherited `CLAUDE_CODE_SESSION_ID` could rewrite the operator's live pin and resolve-cache files. Includes used `dirname "$0"`, which breaks when a test is sourced. The regression used `test_ops_root.sh`, which never writes the pin dir, so "victim unchanged" could pass with the helper removed.

### After

Every hook-invoking suite under `.claude/hooks/tests/` sources `_test-session-isolation.sh` via `BASH_SOURCE`. The runner still wraps each suite and shares one temp pin dir cleaned on EXIT. The regression asserts a write path (`pin-ops-root`) both with and without the helper. Pin-behaviour suites keep overriding the helper per case.

## Artifacts

- Issue #1549
- PR #1567
- `.claude/hooks/tests/_test-session-isolation.sh`
- `.claude/hooks/tests/test_session_isolation_helper_required.sh`
- `.claude/hooks/tests/test_session_isolation_regression.sh`
- `bin/run-hook-tests.sh`
