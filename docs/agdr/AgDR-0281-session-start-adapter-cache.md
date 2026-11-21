# AgDR-0281: Cache the SessionStart adapter comparison

> In the context of SessionStart latency, facing repeated adapter generation, I decided to cache comparisons by content to reduce startup work, accepting hashing overhead.

## Context

Issue #1927 reports a minute before the first agent turn. Adapter generation repeats at every start.
The current worktree has no installed adapter. Its dispatcher completes in about 1.25 seconds.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Generate every start | No cache state | Repeats generation |
| Cache input and installed output content | Reuses verified comparisons | Reads input content |
| Skip headless checks | Lowest latency | Loses diagnostics |

## Decision

Chosen: **content cache**, because unchanged inputs produce the same comparison.
The hash covers the generator, settings, model matrix, skill trees, agent sources, and installed adapter paths.
The cache preserves diagnostics, including drift warnings. Missing, malformed, or unreadable caches require another comparison.
Symlink inputs or output roots disable caching. Failed checks and timeouts retry on the next start.
Cache replacement uses an atomic rename under `.claude/session/`.
The upstream fetch uses the existing portable watchdog with a three-second limit.

## Consequences

Warm starts read files without generating a temporary adapter. Cache removal restores the previous comparison behavior.
No enforcement check is removed. Network failure remains silent.

## Artifacts

- `.claude/hooks/_lib-adapter-check-cache.sh`
- `.claude/hooks/tests/test_session_start_speed.sh`
- Issue #1927. Recorded 2026-10-29T20:22:07Z by Codex.

## Additional cause and plugin decision

On 2026-10-29, the owner supplied real `claude -p` measurements from the ops root.
Normal startup took 57 and 80 seconds. Disabling MCP still took 80 seconds.
An empty folder took 2.4 seconds. Disabling apexyard-status reduced startup to 5.5 seconds.
The supplied debug trace attributed 496 processes to plugin lookups during startup.
These measurements identify plugin startup refreshes as the dominant reported cause.

The plugin no longer awaits refreshes during session startup or turn completion.
It requires an observed UI render before enabling any refresh or timer.
The available local types expose no session-mode flag. An actual render demonstrates a usable UI surface.
The first background refresh follows the first completed turn after that render.
Headless sessions perform no plugin lookups. Interactive sessions retain previous atom values during refreshes.
A shared semaphore limits process concurrency to four. GitHub calls retain their five-second timeout.
ORBIT reads each repo ref once and batches issue and PR searches per initiative.
Batched queries return at most 100 results. Large initiatives can exceed this display subset.
Measured startup took 57-80 seconds before the change and 7.6 seconds with the plugin change.
Headless sessions ran 0 plugin lookups.
