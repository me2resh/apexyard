# New gate modes and verification trailers

> Facing false blocks from new checks, we chose explicit gate registration and advisory verification trailers to preserve existing enforcement.

## Context

The owner approved this boundary for me2resh/apexyard#2094 on 21 November 2026.
Existing gates must retain their enforcement behavior. Config alone must never register a gate.
New checks need an observation period before enforcement.
Commit history needs queryable verification evidence.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Apply modes to every existing gate | One uniform setting | Config could weaken existing controls. The owner rejected this option. |
| Require literal registration for new gates | Existing controls retain enforcement | Each new gate needs a reviewed library change. |

## Decision

We chose literal registration because config must not weaken existing controls.
The shared library starts with an empty allowlist. No existing gate calls the mode mechanism.

New gates declare their names and defaults. Their default is enforce unless they declare observe.
Unknown gates refuse mode resolution. Invalid config modes use enforce.

Observe mode records fixed event identifiers and UTC timestamps. It never records command text.
Each observation appends one JSON line to the gitignored session log.
The status briefing appends the retained event count to its role line.

Verification trailers remain advisory in the existing commit-format hook.
Missing, invalid, empty, or repeated trailers warn. These warnings never block.
The existing subject checks and command checks retain their exit codes.
Git's trailer parser supplies the same classification for warnings and history reports.

## Consequences

- Registering a gate requires a code change and review.
- No production gate becomes configurable through this change.
- Logging failures warn and allow in observe mode.
- Interactive messages retain the existing hook's validation limits.
- Supported cat-heredoc messages receive trailer warnings without changing their subject-validation exception.
- Counts cover the retained local log rather than one session identifier.
- The recent-commit report groups valid values, missing trailers, and invalid trailers.

## Artifacts

- Owner decision: supplied with issue #2094 in this implementation request.
- Mode library: `.claude/hooks/_lib-gate-mode.sh`.
- Trailer parser: `.claude/hooks/_lib-verified.sh`.
- History command: `bash bin/verified-commits.sh [count]`.
- Regression suite: `.claude/hooks/tests/test_gate_modes_verified.sh`.
