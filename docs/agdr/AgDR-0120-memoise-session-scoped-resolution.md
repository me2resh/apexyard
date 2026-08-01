# Memoise Session-Scoped Ops-Root, Config, and Portfolio-Path Resolution Across Hooks

> In the context of a single `Bash` tool call firing up to 48 separate hook processes that each independently re-walk to the ops root, re-read `project-config`, and re-resolve the portfolio paths — 48 identical answers computed 48 times, ~92% of the measured 1617ms of per-call hook overhead — I decided to add a session-scoped, cross-process FILE cache (reusing the existing ops-root pin directory and session id) that the existing per-process caches consult on their cold start, invalidated on every read by an explicit fingerprint of the ops root plus the two config files' (mtime, size), to achieve most of the redundant work eliminated without weakening any gate, accepting a narrow, explicitly-documented residual risk (a symlink swapped into a portfolio path's directory chain mid-session, between two reads, with the config itself unchanged) in exchange for not re-deriving every portfolio path's own filesystem-existence walk on every read.

## Context

Issue me2resh/apexyard#1013 measured the cost precisely: 48 hooks match `Bash` in `.claude/settings.json`; a sequential pass costs 1617ms; 48 bare no-op process spawns cost 128ms (8%); the remaining 92% is each hook's own setup logic, redone identically 48 times per command. The issue is explicit that the fix is NOT "fewer processes" — it's "don't recompute the same three answers 48 times": ops-root resolution, the merged `project-config` JSON, and the resolved portfolio paths (registry, workspace_dir, etc.).

**What already existed before this change (verified, not re-implemented):**

- `_lib-ops-root.sh`'s `resolve_ops_root()` already has a **pin-first, cross-process** cache: a SessionStart hook (`pin-ops-root.sh`, #381) writes the resolved ops root to `${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-<session>`, and `resolve_ops_root()` consults that pin (re-validated against the anchor conditions on every read) before falling back to the walk-up. This already solves ops-root resolution's cross-process cost — it is cheap (a file read + a couple of `stat`-equivalent tests), not a subprocess-spawn-heavy operation.
- `_lib-read-config.sh` (`_CONFIG_CACHE`, `_CONFIG_ROOT_CACHE`) and `_lib-portfolio-paths.sh` (`_PORTFOLIO_ROOT_CACHE`, and one `_PORTFOLIO_*_CACHE` per resolver) already memoise their answers **within one hook's process**. Call the same resolver twice in one script and the second call is a variable read.

**What was missing**, confirmed by instrumenting `jq` invocations across `.claude/hooks/*.sh`: `_config_load()` re-reads and re-merges (`jq -s '.[0] * .[1]'`) `project-config.defaults.json` + `project-config.json` from disk in every fresh process that touches config — and separately, every `portfolio_*` resolver's cold path chains a `config_get` (1 `jq` spawn) through `_portfolio_resolve` → `_portfolio_canonicalize` (multiple `dirname`/`basename`/`cd`+`pwd -P` subshells). `portfolio_validate()` alone calls five of these resolvers in one hook. None of that per-process work survives to the next hook's process.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Cache every `config_get` filter result, keyed by filter string | Would eliminate essentially all `jq` spawns, including per-filter ones | Unbounded key space — caching an arbitrary caller-supplied jq filter string means trusting a fingerprint match to answer for a query this code has never seen validated; exactly the "clever cache that can go wrong" the issue's own Risks section warns against. Rejected. |
| Cache only the ops-root pin harder (shrink its already-cheap cost further) | Simple | Not where the cost is — confirmed empirically (see Verification below) that the ops-root pin read is a handful of cheap builtin tests, not a subprocess-spawn source. Diminishing return. |
| A session-scoped cache FILE for (b) merged config JSON and (c) each portfolio resolver's final absolute path, consulted by the existing per-process cold-start path, fingerprinted on (ops root, config files' mtime+size) | Bounded, known key space (one JSON blob + 8 named path resolvers); reuses the SAME pin directory and session-id keying the ops-root pin already established (no second resolution mechanism); every cache entry is provably a pure function of its fingerprint's inputs | Does not eliminate `config_get`'s per-filter `jq` spawn (accepted — see Consequences); a documented narrow residual risk on the portfolio-path canonicalization (see Decision) |
| Exported env vars from a SessionStart hook, consulted by later hook processes | Would avoid a file entirely | **Does not work.** Each of the 48 hooks is a separate, independently-spawned process tree — not a child of the SessionStart hook's shell — so `export`ed vars from SessionStart do not reach them. A file under the session pin dir is the channel that already demonstrably works for this exact problem (the ops-root pin). |

## Decision

Chosen: **a session-scoped cache FILE per cached value, self-describing (fingerprint + value together in the same file), keyed on `$CLAUDE_CODE_SESSION_ID` in the existing pin directory** — because it reuses a channel already proven to survive the cross-process boundary, and because per-file self-description means no cache entry ever depends on another file's write having "already happened" (no ordering assumption between files, no lock needed).

### What gets cached, and what deliberately doesn't

| Cached | Not cached | Why not |
|---|---|---|
| The merged `project-config` JSON text (`_config_load`'s output) | Individual `config_get <filter>` results | Unbounded caller-supplied filter strings — see Options Considered |
| Each of the 8 `portfolio_*` resolvers' final absolute path (registry, projects_dir, ideas_backlog, onboarding, workspace_dir, custom_skills_dir, custom_handbooks_dir, agent_routing) | — | — |
| (Implicitly, via reuse) ops-root resolution | A second ops-root resolver/cache | `resolve_ops_root()` already has one (#381); adding a second, differently-shaped cache for the same fact is exactly the "two hand-maintained resolvers that silently disagree" failure this issue's own Risks section cites (apexyard-premium#537) as a warning from a different codebase |
| — | GH API / CI / PR-review state read by other hooks | Out of scope by design — this is `project-config` + portfolio-path resolution ONLY, never dynamic forge state; caching that would be the actual "confidently wrong" gate-relevant failure the issue warns about |

### Staleness model — "correct-or-cold, never confidently-wrong"

Every cached value here is a pure function of exactly three inputs: the resolved ops root, `.claude/project-config.defaults.json`'s (mtime, size), and `.claude/project-config.json`'s (mtime, size) — or the literal token `ABSENT` when that file doesn't exist. `_resolution_cache_config_fingerprint()` combines the three into one opaque string; **every cache file stores its own fingerprint alongside its value** (fingerprint on line 1, value on the rest), so no file's validity depends on another file's state or write order.

On every single read — not once per session, every read — the current fingerprint is recomputed fresh (two `stat` calls) and compared byte-for-byte against the stored one. Anything other than an exact match (file absent, mismatch, unreadable) is a miss, and the caller falls straight through to the pre-existing, unchanged cold-path logic. This means a `.claude/project-config.json` edit mid-session — the exact scenario the issue names as "worse than the latency it saves" — invalidates every dependent cache entry on the very next read; nothing can serve a pre-edit answer once the file has changed.

`stat` has two incompatible flavours (GNU vs. BSD/macOS). When neither succeeds, the fingerprint is the literal token `UNKNOWN`, and both the read and write paths explicitly refuse to trust or store anything under it (`[ "$fp" != "UNKNOWN" ] || return 1` on every code path that touches a fingerprint). This is the issue's "when in doubt, don't cache that value" rail, applied per-platform.

### Why a file, not exported env

A SessionStart hook's `export`ed variables do not reach the independently-spawned per-hook processes — verified against how the harness already invokes hooks (each is `exec`'d fresh via `.claude/settings.json`'s wrapper, not a child of any prior hook's shell). A cache file under the session pin directory is the channel that already demonstrably survives this boundary, because the ops-root pin (#381) already relies on exactly this mechanism successfully.

### The accepted residual risk — portfolio-path canonicalization under a mid-session symlink swap

`_portfolio_canonicalize()` walks up to the nearest *existing* ancestor of a path and resolves it via `cd && pwd -P`, appending any not-yet-existing tail literally. A cached portfolio path is therefore provably correct for as long as (ops root, config) are unchanged **and** no directory along that specific path's chain changes what it points to (e.g., a plain directory later replaced by a symlink) between the write and a subsequent read in the same session. This is different from — and much narrower than — the "wrong ops-root or config" failure the issue is centrally worried about: it requires an actual filesystem topology change mid-session on a path segment that a `.claude/project-config.json` edit would not itself invalidate (that edit IS separately caught by the fingerprint). I judge this an acceptable, narrow, honestly-documented trade — the threat model here is honest staleness, not adversarial symlink swaps on the operator's own local fork — and it is the trade the issue explicitly permits ("if a safe cache proves awkward for one of the three, cache the other two and say so"). All three ARE cached; this paragraph is the "say so."

### Mechanism

New file `.claude/hooks/_lib-resolution-cache.sh`, sourced by `_lib-read-config.sh` and `_lib-portfolio-paths.sh` at module-load time via the same "raw `BASH_SOURCE[0]`, best-effort sibling lookup, silently skip on failure" idiom already established for `_lib-ops-root.sh` sourcing elsewhere in this file family (AgDR-0118) — never a hard dependency; a self-location failure just means no speedup, never a wrong answer.

- `_config_load()` (`_lib-read-config.sh`): before doing its disk-read + `jq -s` merge, tries `_resolution_cache_read_json <fingerprint>`. On a hit, returns the cached JSON text directly — byte-identical to what the merge would have produced, because that's exactly what got cached. On a miss, computes exactly as before, then opportunistically writes the result for the next process.
- Every `portfolio_*` resolver (`_lib-portfolio-paths.sh`): now routes its cold-path computation through one shared `_portfolio_resolve_with_session_cache <name> <config_key> <default>` helper, which tries the session cache first and falls through to the pre-existing `_portfolio_get` + `_portfolio_resolve` chain (unchanged) on any miss.
- `_portfolio_root()`: now prefers `resolve_ops_root()` (the existing pin-aware resolver) over redoing its own independent walk-up, when that function is available — a straight consolidation onto the ops-root pin that already exists, not a new cache. Preserves the one real behavioural difference (`_portfolio_root()` falls back to the git toplevel on a miss; `resolve_ops_root()` returns empty) by only short-circuiting on a pin **hit**, never a miss.

### Fail-safe posture (all four acceptance-criteria requirements, verified empirically — see Verification)

- **No `CLAUDE_CODE_SESSION_ID`** (git hooks, CI, a bare `bash script.sh`): every cache function returns 1 immediately; behaviour is the pre-#1013 code path, unchanged. This is why standalone git-hook installs in managed projects (which run these libs with no Claude Code session at all) are unaffected.
- **`APEXYARD_DISABLE_RESOLUTION_CACHE=1`**: same no-op, independent of `APEXYARD_OPS_DISABLE_PIN` (untouched). `bin/run-hook-tests.sh` sets both for the whole suite, mirroring the existing pin-isolation rationale (#528) — a sandboxed test must never read or pollute the real session's cache.
- **Unwritable cache directory** (read-only FS, sandbox): every write silently returns 1 (stderr swallowed); the value being cached was already computed BEFORE the write attempt, so a write failure never changes what's returned, only whether the next process gets to skip the work this one just did.
- **Cold or invalidated cache**: byte-for-byte the same code path as before this AgDR — the cache-read attempt is purely additive, gated by a fingerprint match, and every fallback runs the exact pre-existing logic.

## Consequences

- Cross-process cost for the merged config JSON and the 8 portfolio path resolvers drops from "redone every hook process" to "computed once per session generation, read cheaply thereafter" — measured before/after numbers are in the PR description (48-hook sequential-pass benchmark, matching the issue's own methodology).
- `config_get <filter>`'s own per-call `jq` spawn is **unchanged** — still one `jq` process per filter, per call, regardless of this cache. The win here is narrower than "no more `jq` calls anywhere"; it's specifically "the disk-read + merge that produces the JSON those filters run against is no longer redone 48 times," plus the much larger portfolio-path canonicalization chains (multiple subshells per resolver) collapsing to a cache read.
- `_portfolio_root()` now converges with `resolve_ops_root()`'s answer whenever a pin is available, removing one instance of the "two independently-maintained resolvers for the same fact" pattern this issue's own Related section warns about (apexyard-premium#537) — a side benefit, not the primary ask, and scoped narrowly (only short-circuits on a hit; the existing walk-up fallback for un-anchored managed-project clones is untouched).
- New escape hatch `APEXYARD_DISABLE_RESOLUTION_CACHE=1`, independent of the existing `APEXYARD_OPS_DISABLE_PIN`.
- New session-scoped files accumulate under `${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}` with no automatic cleanup — same pre-existing limitation the ops-root pin already has (nothing sweeps `ops-root-<session>` files either). Not addressed here; out of scope for this issue, and no worse than the status quo.
- No hook's gating decision changes: every value this AgDR caches (ops root, project-config, portfolio paths) is config/filesystem-derived, never forge state (CI status, PR review state, merge eligibility) — those remain live-read by every hook, exactly as before.

## Verification

- `.claude/hooks/tests/test_resolution_cache.sh` (new): cold-cache-matches-uncached, cross-process reuse (merge `jq -s` call proven absent on a warm second process via a logging `jq` shim), staleness (a `project-config.json` edit between two same-session reads is picked up, never served stale), fingerprint `UNKNOWN` is never a valid cache key even if deliberately forged, unwritable cache dir degrades with no error, disable flag prevents any file from being written, ops-root mismatch is never trusted.
- Full existing hook test suite (`bin/run-hook-tests.sh`) run unchanged and green — no gate's behaviour changed.
- `shellcheck --severity=warning` clean on all three touched/added files.

## Artifacts

- `.claude/hooks/_lib-resolution-cache.sh` — new shared session-cache library
- `.claude/hooks/_lib-read-config.sh` — `_config_load()` consults the session cache
- `.claude/hooks/_lib-portfolio-paths.sh` — all 8 `portfolio_*` resolvers + `_portfolio_root()` consult it
- `.claude/hooks/tests/test_resolution_cache.sh` — new test coverage
- `bin/run-hook-tests.sh` — exports `APEXYARD_DISABLE_RESOLUTION_CACHE=1` for the whole suite, mirroring the existing `APEXYARD_OPS_DISABLE_PIN=1` isolation
- PR: perf(#1013) — memoise session-scoped ops-root + config resolution across hooks
