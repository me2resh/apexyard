# Gate the hook test suite in CI

> In the context of ~64 mechanical-enforcement test scripts of which only 2 ran in CI, facing the fact that a hook regression ships green because the suites are advisory, I decided to add a discovery runner (`bin/run-hook-tests.sh`) + a `tests.yml` workflow that runs the whole suite on every PR and fails the job on any failure, with a documented quarantine list for tests that genuinely can't run headless, to achieve real regression protection, accepting that a small, explicitly-listed set of environment-dependent tests is excluded (and tracked) rather than letting them flake the gate.

## Context

The framework's safety is the hooks (merge gate, ticket-first + per-worktree tiers, onboarding/secrets/leak guards, validators, portfolio path resolution). ~64 `test_*.sh` assert that behaviour, but only `test_subpack_extraction` and `test_site_counts` ran in CI; `shellcheck.yml` lints syntax, never runs the suites. So the tests were advisory — several issues this session (review-marker naming, worktree detection) were caught only by running suites by hand. #526.

A local triage on macOS showed 52/64 passing; the 12 failures split into (a) macOS `/private/var` symlink artifacts that pass on Linux, and (b) genuinely stale/drifted tests. CI on Linux is the authoritative oracle for which is which.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Discovery runner + tests.yml, fail-on-any, short documented quarantine (chosen) | Real gate immediately; no hardcoded test list to maintain; quarantine is explicit + logged | A few env-dependent tests excluded until fixed |
| Hardcode the list of tests to run in the workflow | Simple | Drifts the moment a test is added; the gap that created this problem |
| Fix every failing test first, then gate with zero quarantine | Purest gate | Couples the gate to unbounded pre-existing test debt; delays protection indefinitely |
| Allowed-failures (run but don't fail the job) | Nothing blocks | Not a gate — same advisory non-enforcement we're replacing |

## Decision

Chosen: **`bin/run-hook-tests.sh` (glob-discovery, per-test timeout, fail-on-any) + `.github/workflows/tests.yml` (PR + push to dev/main, jq installed, git identity set)**. Tests that genuinely can't run headless, or are known-failing and tracked, go in the runner's `QUARANTINE` array — each entry must cite a reason and is printed as `SKIP` (never silently dropped). The quarantine is a **ratchet**: the gate enforces the passing majority now; quarantined entries get follow-up tickets to fix + un-quarantine.

Linux CI determines the real failing set (macOS symlink noise excluded). Genuinely-stale failures are either fixed in-scope when trivial, or quarantined with a tracking ticket when they represent separate debt.

## Consequences

- Hook regressions now fail CI on the PR that introduces them — the suite is a gate, not a suggestion.
- The runner is reusable locally (`bash bin/run-hook-tests.sh`), so contributors get the same signal pre-push.
- A small, visible quarantine set remains until follow-ups clear it; the list is in one place with reasons.
- Adding a new `test_*.sh` is auto-discovered — no workflow edit needed.

## Artifacts

- Issue: me2resh/apexyard#526
- Files: `bin/run-hook-tests.sh`, `.github/workflows/tests.yml`
- The exact quarantine list + any in-scope test fixes are recorded in the PR.
