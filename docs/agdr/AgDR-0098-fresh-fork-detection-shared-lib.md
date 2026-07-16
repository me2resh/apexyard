# Extract fresh-fork detection into a single shared library `_lib-fresh-fork.sh`

> In the context of the guided first-run flow needing to know whether a fork is fresh (increment 1, PRD #902/#905), facing the PRD Technical Constraint that forbids a second competing detection mechanism, I decided to extract `onboarding-check.sh`'s inline detection into one sourceable library `_lib-fresh-fork.sh` consumed by both the hook and `/onboard`, to achieve a single structural source of truth, accepting a behaviour-preserving refactor of an existing SessionStart hook plus a new shared library that other code depends on.

## Context

The guided first-run orchestrator (`/onboard`, see AgDR-0097) must decide, on invocation, whether the fork is `fresh` (run the full guided flow), `configured` (offer a re-run only), or `not-a-fork` (bail). That is exactly the judgement `onboarding-check.sh` (SessionStart hook) already makes today to decide whether to print its "not configured — run /setup" banner.

The PRD Technical Constraint is explicit: *"The new first-run flow must not introduce a second, competing fresh-fork detection mechanism — it extends the one `/setup` already uses (`onboarding.yaml` absent or placeholder)."* Today that logic lives **inline** inside `onboarding-check.sh`: resolve `onboarding.yaml` via `portfolio_onboarding_path` (handling single-fork **and** split-portfolio v2), then treat *absent-file-but-example-present* or *placeholder `company.name`* as unconfigured.

If `/onboard` re-implemented that check, two detectors would drift — precisely what the constraint prohibits. This introduces a new shared shell library other code depends on, so it is AgDR-class. Recorded at the recommendation of the Gate-3b design review (Tariq).

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. `/onboard` re-implements the detection inline** | No refactor of the existing hook | Two independent detectors that drift; directly violates the PRD "no second competing mechanism" constraint |
| **B. `/onboard` shells out to `onboarding-check.sh` and parses its banner text** | Reuses the one implementation | Couples to human-readable banner text (fragile); the hook emits a *message*, not a machine-readable state; awkward to test |
| **C. Extract detection into `_lib-fresh-fork.sh`; both the hook and `/onboard` source it** *(chosen)* | One structural source of truth; returns a machine-readable state (`fresh`/`configured`/`not-a-fork`); unit-testable in isolation; matches the framework's existing `_lib-*.sh` shared-library pattern (e.g. `_lib-audit-history.sh`) | A behaviour-preserving refactor of an existing SessionStart hook + a new library to maintain |

## Decision

Chosen: **Option C — extract into `_lib-fresh-fork.sh`**, exposing one read-only function:

```
fresh_fork_state()   # echoes: fresh | configured | not-a-fork ; exit 0
```

`onboarding-check.sh` becomes a thin caller (`[ "$(fresh_fork_state)" = fresh ] && echo "…run /onboard"`); `/onboard` sources the same function to gate its flow. This is the same behaviour-preserving-extraction shape the audit-persistence work used for `_lib-audit-history.sh` (AgDR-0019). The function is read-only (no writes, no network), so it is safe to call from both a SessionStart hook and a bootstrap skill. The "no second detector" guarantee becomes **structural**, not conventional — there is exactly one implementation, and it is the one `/setup`'s ecosystem already relies on.

## Consequences

- New library `.claude/hooks/_lib-fresh-fork.sh` with `fresh_fork_state()`, resolving `onboarding.yaml` via `portfolio_onboarding_path` (single-fork + split-portfolio v2).
- `onboarding-check.sh` refactored to source the lib; its banner behaviour is preserved (same rules, same paths) and its text updated to recommend `/onboard`.
- New unit test `.claude/hooks/tests/test_fresh_fork.sh` covers the three states and split-portfolio path resolution — the regression guard that lets the extraction ship safely.
- `/onboard` depends on this lib; the build order in #910 puts the lib + its tests first (task 1) before the hook rewire (task 2) and the orchestrator (task 4).

## Artifacts

- Technical design: `docs/technical-designs/onboarding-increment-1.md` § "D2" and § "Shared detection library — API"
- PRD: `docs/prds/onboarding-overhaul.md` (#902 / #905) — Technical Constraint
- Ticket: [me2resh/apexyard#909](https://github.com/me2resh/apexyard/issues/909) · PR [#917](https://github.com/me2resh/apexyard/pull/917) · build in [#910](https://github.com/me2resh/apexyard/issues/910)
- Prior art: AgDR-0019 (`_lib-audit-history.sh` behaviour-preserving extraction)
- Related: AgDR-0097 (`/onboard` first-run orchestrator)
