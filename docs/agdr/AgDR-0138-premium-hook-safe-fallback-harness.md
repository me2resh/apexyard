# Premium-hook safe-fallback harness — `_lib-premium-hook.sh`

> In the context of premium-touching hooks (`reindex-on-session-start.sh`, the `apexyard-premium#514` search self-heal, future premium hooks not yet written) each hand-rolling the same "never block, always exit 0, silent-when-absent, timeout-guarded" shape, facing the risk that every new premium hook is a fresh chance to get that safety wrong, I decided to **centralize the shape into one sourced library (`_lib-premium-hook.sh`) exposing `premium_hook_run`**, to achieve safe-by-construction premium hooks that can never break framework/free users, accepting a small API-learning cost for hook authors and a feature-flag-default design choice needed to keep the very first retrofit (`reindex-on-session-start.sh`) behaviour-preserving.

## Context

`me2resh/apexyard#514` (the apexyard-search config self-heal) surfaced that premium-touching hooks each hand-roll their own version of the same safe-fallback contract: gate on install-presence, timeout-guard the slow work, swallow non-zero exit, never let a premium hook block or fail a session. `reindex-on-session-start.sh` already does this by hand (kill-switch, `command -v apexyard-search`, `timeout`/`gtimeout`, `|| true`, `exit 0`). Copy-pasting this shape per hook means every new premium hook is a fresh chance to drop one of the properties — e.g. forgetting the timeout guard, or propagating a non-zero exit code. `me2resh/apexyard#890` asks for the primitive: one audited, sourced lib that centralizes the three safety properties so future premium hooks are safe-by-construction rather than safe-by-careful-copy-paste.

A constraint shaping the design: `reindex-on-session-start.sh` (the first hook retrofitted) has **never** gated on `features.yaml` — its only gate has always been `command -v apexyard-search`. If the harness's feature-flag gate defaulted to "disabled when unconfigured", retrofitting this hook would silently stop the reindex from running for every existing adopter who has `apexyard-search` installed and on PATH but has never written a `features.yaml` `search:` block — a real regression, not a hypothetical one.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **One sourced lib (`_lib-premium-hook.sh`) with `premium_hook_run <feature_key> <presence_check_cmd> <payload_cmd> [default_enabled]`, feature-flag defaulting configurable per call-site** | Centralizes gate + timeout + swallow + always-0 in one audited place; the `default_enabled` param lets a behaviour-preserving retrofit (default `"true"`) coexist with a stricter explicit-opt-in posture for brand-new premium hooks (default `"false"`) | One more parameter to explain in the header doc |
| Harness always fails closed (feature must be explicitly `enabled: true`) | Simplest mental model — premium features are opt-in by construction | Breaks `reindex-on-session-start.sh` for every adopter who has the CLI installed but no `features.yaml` `search:` block — a real regression the acceptance criteria explicitly forbid |
| Leave each premium hook to hand-roll its own safe shape (status quo) | Zero migration cost | The exact problem #890 exists to close — every new premium hook re-derives (and can get wrong) the same three properties |
| A Python-side harness (since `apexyard-premium`'s budget enforcer is already Python) | Consistent language with some premium components | Most premium-touching *hooks* in this repo are bash (`reindex-on-session-start.sh`, `validate-search-config.sh`); a bash lib matches where the gate/timeout/swallow logic actually needs to live (PreToolUse/SessionStart hook scripts) |

## Decision

Chosen: **`_lib-premium-hook.sh` exposing `premium_hook_run` (plus the standalone `premium_feature_enabled` and `premium_bin_present` helpers)**, because it centralizes the three safety properties in one place while the `default_enabled` parameter resolves the tension between "new premium hooks should default closed" and "the first retrofit must not regress."

Specifics:

- **`premium_hook_run <feature_key> <presence_check_cmd> <payload_cmd> [default_enabled]`** — the single entry point. `presence_check_cmd` and `payload_cmd` are shell command *strings*: the presence check runs via `eval` in the current shell (cheap, and still sees the lib's own helpers like `premium_bin_present`); the payload runs via `bash -c` in a **new child process** so the timeout wrapper (`timeout -k 2 …` / macOS `gtimeout`, same preference order as `reindex-on-session-start.sh`) can actually kill it if it hangs — a `timeout` around an in-process `eval` cannot do that.
- **Gate = feature flag AND presence**, both silent-no-op on failure. `premium_feature_enabled <feature_key> [default_enabled]` reads `features.yaml` (resolved via `_lib-ops-root.sh` / `_lib-read-config.sh` / `_lib-portfolio-paths.sh`, the same candidate-path order `validate-search-config.sh` already uses: portfolio root, then ops root, then `$APEXYARD_PORTFOLIO_ROOT`), scoped-block matching a top-level `<feature_key>:` key with a nested `enabled: true|false` — not a blanket grep, so it can't false-positive on an unrelated feature's flag.
- **`default_enabled` resolves the retrofit tension**: when the key is entirely absent from `features.yaml`, `premium_feature_enabled` falls back to the caller-supplied default (`"true"` unless the caller passes `"false"`). An **explicit** `enabled: false` in `features.yaml` always wins regardless of the default — that's the new capability (an admin kill-switch that doesn't require uninstalling the CLI). `reindex-on-session-start.sh` passes `"true"` (preserving its pre-#890 install-presence-only gate); a brand-new premium hook authored after this AgDR should default to `"false"` (explicit opt-in) unless it has the same install-base-compatibility constraint.
- **Fail-safe execution**: the payload always runs inside the timeout wrapper; its exit code is swallowed (`|| true`); the wrapper degrades to no timeout if neither `timeout` nor `gtimeout` exists (payload still runs, just unbounded — matches the pre-existing `reindex-on-session-start.sh` fallback, not a new gap).
- **Always 0**: `premium_hook_run` has no code path that returns non-zero. Missing required args (`feature_key`, `payload_cmd`) are a silent no-op, not an error.
- **The convention**: any new premium-touching hook MUST route its premium-only work through `premium_hook_run` instead of hand-rolling gate/timeout/swallow logic. This AgDR is the citation for that convention (see the lib's own header comment).

## Consequences

- `reindex-on-session-start.sh` is retrofitted onto the harness with no observable behaviour change: no CLI → silent; kill-switch → silent; CLI present + no `features.yaml` → reindex still runs; a throwing or hanging `apexyard-search` invocation still can't block the session. See `.claude/hooks/tests/test_reindex_on_session_start.sh`.
- Adopters gain a new, optional capability for free: setting `search: { enabled: false }` in `features.yaml` disables the reindex hook without uninstalling `apexyard-search`.
- The `apexyard-premium#514` search self-heal hook (`validate-search-config.sh`, not yet merged onto this branch — it lives in a concurrent PR) is **not** retrofitted in this change. It is a read-only, non-blocking hook by design (see its own header) with a different intent-gate shape (OR, not AND, between `.mcp.json` presence and `features.yaml`), so retrofitting it needs its own follow-on ticket once #514 merges, rather than being force-fit into this harness's AND-shaped gate.
- Future premium hooks (the `apexyard-premium` budget enforcer's shell wrapper, any hook for the `loops`/`playbooks`/`growth` premium features referenced in `.claude/skills/*.framework.bak`) have one audited call site to route through instead of re-deriving the safe shape.
- The `default_enabled` parameter is a small but load-bearing API surface: a future maintainer adding a new premium hook must consciously choose `"true"` vs `"false"` rather than get a one-size-fits-all default. Documented in the lib's header and in this AgDR so the choice isn't accidental.

## Artifacts

- Issue: me2resh/apexyard#890
- Lib: `.claude/hooks/_lib-premium-hook.sh`
- Retrofit: `.claude/hooks/reindex-on-session-start.sh`
- Tests: `.claude/hooks/tests/test_lib_premium_hook.sh`, `.claude/hooks/tests/test_reindex_on_session_start.sh`
- Related: `apexyard-premium#371` (original reindex hook), `apexyard-premium#514` (search self-heal — follow-on retrofit once merged)
