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

## JSON output

\#1745 constraint 5 names an optional `--json` flag.
This change does not add that flag.
The terminal report is the result.
A later change can add JSON output to the same script.

## Architecture evolution

### Before

`bin/apexyard` used the directory of `BASH_SOURCE[0]` when no fork was found.
A symlink on `PATH` made that directory the directory on `PATH`.
The shell then exited 127 because `preflight.sh` was absent.
The timing probe sent `SIGTERM` only to the dispatcher process.
A child of that process kept running after the report ended.
The Windows path check compared the raw `git` text with `pwd -P`.
Git Bash prints `C:/...` and `pwd -P` prints `/c/...` for the same directory.
A healthy Git Bash host then reported `WARN windows-paths`.

### After

The CLI resolves the real script path and then runs `preflight.sh` from that directory.
It calls `readlink` on each symlink until the target is a normal file.
A missing `preflight.sh` prints one message and exits 2.
The timing probe starts in its own process group.
Children stay in that group because the dispatcher script does not enable job control.
The watchdog signals that group, so the dispatcher and its children stop.
The Windows check compares both paths after `cygpath -u` when `cygpath` is present.
With no `cygpath`, the check maps a leading `X:/` to `/x/` and then compares.
The upstream check accepts `ssh://git@github.com/me2resh/apexyard` with or without `.git`.

## Artifacts

- `.claude/skills/preflight/preflight.sh`
- `.claude/skills/preflight/tests/test_preflight.sh`
- `bin/apexyard`
- Refs #1745
