# Session keyed exemption markers

> In the context of concurrent sessions, facing shared gate exemptions, I decided to scope each exemption to its session. This prevents cross-session access. The decision accepts a required session id.

## Context

Issue #1532 identifies shared bootstrap and issue-skill exemptions. Role banner cleanup also deletes markers from other live sessions. AgDR-0166 provides the session suffix convention.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Shared paths | Supports callers without an id | Leaks exemptions between sessions |
| Session paths | Isolates gate state | Requires a harness session id |

## Decision

Chosen: **session paths**, because a shared exemption cannot identify its owner.
Use `active_bootstrap_marker_path` and `active_issue_skill_marker_path` in one library. Use the suffix and sanitization from `active_reviewer_marker_path`. Return no path when `CLAUDE_CODE_SESSION_ID` is empty. Do not use the review helper's shared-path fallback: these markers grant exemptions.

For one migration release, detect each old file, claim an atomic notice directory, and tell the operator to restart. Ignore the old file. Keep the notice directory so repeated hooks issue no duplicate notice. Remove this detection after the migration release. There is no legacy authorization fallback.

SessionStart clears only the current session's exemption files. Role banners retain other sessions' markers for seven days. Missing identity keeps role banners active.

## Consequences

- Skills must use the resolver on entry and on every cleanup path.
- Harness adapters must export a stable, unique `CLAUDE_CODE_SESSION_ID` before hooks and skill Bash blocks run. No process-id fallback is safe across separate tool calls.
- Manual harness checks remain required before release.

## Artifacts

- Issue #1532.
- Timestamp: 2026-10-19T00:00:00Z. Agent: Codex. Trigger: user prompt.

## Manual checklist for the PR

These checks have not run in this build environment. Record the result and actual adapter id before merge.

| Harness | `/setup` | `/bug` | Session id evidence |
|---------|----------|--------|---------------------|
| Claude Code | Pending | Pending | Record `CLAUDE_CODE_SESSION_ID` |
| Cursor | Pending | Pending | Record mapped `session_id` from cursor-session-pin.sh |
| opencode | Pending | Pending | No automatic mapping verified; record configured native id |
| pi | Pending | Pending | No automatic mapping verified; record configured native id |

The pi and opencode adapter sources do not supply an automatic mapping in this build. Their manual checks remain pending. If an adapter exports no id, both exemption gates stay closed. Configure the adapter to export its native session id. Do not use a shared default.
