# AgDR-0249: Share the preflight environment check

> In the context of #1745, facing failures before setup, I decided to expose
> one read-only shell script through the CLI and a skill, accepting that
> checks which need jq must report a skipped result when jq is absent.

## Context

The hook layer can block diagnosis inside Claude Code. Users need the same
report in a Bash terminal. The report must run on Bash 3.2 without jq.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Separate CLI and skill checks | Separate interfaces | Detection can differ |
| Shared skill script | One implementation; follows status/briefing.sh | CLI depends on the skill directory |

## Decision

Chosen: **shared skill script** at `.claude/skills/preflight/preflight.sh`.
`bin/apexyard doctor` delegates to it, as status delegates to briefing.sh.
The script uses the existing root, hooks-path, portfolio, and onboarding
helpers. It disables session pins and resolution caches to prevent writes.
It does not run configurable hook commands. It times the tracked dispatcher
with a trivial payload and a watchdog. It does not change timeout settings.
No dependency or gate behavior changes.

## Consequences

- WARN and FAIL rows each print one fix. The user must run the fix.
- Missing jq does not prevent tool, remote, hooks-path, or Windows checks.
- Timing is approximate and does not establish a safe long-command limit.
- Windows path fixtures test drive-letter and mount forms without Windows.

## Artifacts

- `.claude/skills/preflight/preflight.sh`
- `.claude/skills/preflight/tests/test_preflight.sh`
- `bin/apexyard`
- Refs #1745
