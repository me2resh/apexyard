---
id: AgDR-0183
timestamp: 2026-09-29T12:00:00Z
agent: platform-engineer
model: composer
session: cursor-1403-worktree
trigger: user-prompt
status: executed
category: patterns
---

<!-- Uses the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Close the #1403 remainder: static `< <(` check and dash gap

> In the context of issue #1403 after PR #1419 closed the merge-gate
> fail-open, facing two deferred items (a static process-substitution
> check and a dash bad-substitution at `_lib-read-config.sh` line 35), I
> decided to guard the top-level `BASH_SOURCE` expansion behind
> `BASH_VERSION` and add a hook-suite static check for `< <(` in an
> explicit POSIX-sourced library list, to keep those libraries sourceable
> under bash POSIX mode and under dash, accepting that the static list
> starts with `_lib-read-config.sh` only and that calling `config_get`
> under dash still hits other bash-only constructs such as `local`.

## Context

PR #1419 (AgDR-0169) made merge gates fail closed when a sourced library
is missing. Two comment items on #1403 stayed open.

1. Tests 7a and 7b in `test_config_warn_dropped_defaults.sh` prove
   `_lib-read-config.sh` sources under `bash --posix` and
   `POSIXLY_CORRECT=1`. Bash 5.1 or later on Linux CI may allow process
   substitution in POSIX mode. A reintroduced `done < <(...)` could then
   pass those runtime tests.
2. Dash (Linux `/bin/sh`) rejects `${BASH_SOURCE[0]:-}` as a bad
   substitution. The top-level load of `_lib-read-config.sh` aborted
   before `config_get` was defined.

The process-substitution rewrite in `_config_warn_dropped_defaults` is
already on this base. This record adds the static pin and the dash fix.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Rewrite self-location without any `BASH_SOURCE` use | Works under every POSIX shell | Breaks the AgDR-0118 / AgDR-0120 self-location idiom shared across `_lib-*.sh` |
| Guard `${BASH_SOURCE[0]:-}` behind `[ -n "${BASH_VERSION:-}" ]` (chosen) | Small change. Dash skips the expansion. Bash paths stay identical | Under dash the sibling resolution-cache source is skipped. That is best-effort already |
| Scan every `_lib-*.sh` for `< <(` | Broad coverage | False-fails on bash-only libs such as `_lib-detect-bash-write.sh` that never claim POSIX sourcing |
| Explicit POSIX-sourced list starting with `_lib-read-config.sh` (chosen) | Matches the #1403 comment. Easy to extend | A new POSIX-sourced lib must be added to the list by hand |

## Decision

Chosen: **BASH_VERSION guard at the top-level load site**, and an
**explicit POSIX-sourced library list** for the static `< <(` check,
because both close the deferred items with the smallest safe change.

Under a non-bash shell the raw path stays empty. The resolution-cache
sibling source is skipped. `config_get` is still defined. Calling
`config_get` under dash is out of scope. That path still uses `local`.

The static check strips full-line comments. A comment that shows the
forbidden form does not fail the suite. A planted fixture with a real
`< <(` must fail the checker.

## Consequences

- `_lib-read-config.sh` sources under dash and still defines `config_get`.
- Reintroducing `< <(` into a listed POSIX-sourced library fails the hook
  test suite on every bash version.
- AgDR-0169's deferred comment items are closed by this change.
- Full dash support for every function body in the library is not claimed.

## Artifacts

- Issue: me2resh/apexyard#1403
- Parent: docs/agdr/AgDR-0169-dispatcher-fail-closed-merge-gates.md
- Related: docs/agdr/AgDR-0120-memoise-session-scoped-resolution.md
- Tests: `.claude/hooks/tests/test_posix_sourced_libs.sh`
- Tests: case 7c in `.claude/hooks/tests/test_config_warn_dropped_defaults.sh`
- Code: `.claude/hooks/_lib-read-config.sh` (BASH_VERSION guard)
