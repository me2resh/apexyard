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
Use `active_bootstrap_marker_path` and `active_issue_skill_marker_path` in one library. Use the suffix and sanitization from `active_reviewer_marker_path`. Resolve `CLAUDE_CODE_SESSION_ID` first, then `APEXYARD_SESSION_ID`. Return no path when both are empty. Do not use the review helper's shared-path fallback: these markers grant exemptions.

For one migration release, detect each old file, claim an atomic notice directory, and tell the operator to run the skill again. Ignore the old file. Keep the notice directory so repeated hooks issue no duplicate notice. Remove this detection after the migration release. There is no legacy authorization fallback.

SessionStart clears only the current session's exemption files. Role banners retain other sessions' markers for seven days. Missing identity keeps role banners active.

## Consequences

- Skills must use the resolver on entry and on every cleanup path.
- Adapters export `APEXYARD_SESSION_ID` to hooks and skill shells. Claude Code keeps precedence. No shared default is permitted.
- Interactive harness checks remain a recorded follow-up. They are not a merge condition under the amended AC5.

2026-10-19 (#1783): opencode and pi strip an inherited `CLAUDE_CODE_SESSION_ID` from hook and shell env so the adapter id decides; the resolver precedence above is unchanged.

## Architecture evolution

### Before

An opencode or pi process started from a shell that already exported `CLAUDE_CODE_SESSION_ID` forwarded that value to gate hooks and skill shells. The resolver preferred it over `APEXYARD_SESSION_ID`, so every adapter session in that shell shared the parent Claude Code marker paths.

### After

Both adapters remove `CLAUDE_CODE_SESSION_ID` from the environment they pass to hooks and from the prefix they add to agent shell commands (pi also clears it on the process at session start). Marker paths then follow each adapter's own `APEXYARD_SESSION_ID`. Claude Code sessions still set and use `CLAUDE_CODE_SESSION_ID` unchanged.

## Artifacts

- Issue #1532.
- Timestamp: 2026-10-19T00:00:00Z. Agent: Codex. Trigger: user prompt.

## Manual checklist for the PR

Automated tests cover Claude Code, opencode and pi for session-id transport and marker isolation. The eight interactive `/setup` and `/bug` runs are a recorded follow-up. They are not a merge condition under the amended AC5.

2026-10-19: AC5 amended with CEO confirmation (see #1532).

| Harness | `/setup` | `/bug` | Session id evidence |
|---------|----------|--------|---------------------|
| Claude Code | Resolver tested; manual run follow-up | Resolver tested; manual run follow-up | `CLAUDE_CODE_SESSION_ID` wins over the adapter variable |
| Cursor | Mapping inspected; manual run follow-up | Mapping inspected; manual run follow-up | `cursor-session-pin.sh` maps `session_id` or `conversation_id` to `CLAUDE_CODE_SESSION_ID` through its JSON `env` output |
| opencode | Shell and hook transport tested; manual run follow-up | Shell and hook transport tested; manual run follow-up | Native tool-call `sessionID`, exported as `APEXYARD_SESSION_ID` |
| pi | Shell and hook transport tested; manual run follow-up | Shell and hook transport tested; manual run follow-up | `sessionManager.getSessionId()` at `session_start`, exported as `APEXYARD_SESSION_ID` |

opencode carries the native id per tool call because one server can host concurrent sessions.
The adapter passes it to hook subprocesses and prefixes Bash commands with a quoted export after gate evaluation.
pi exports its native id in the process environment at each session start.
A random UUID supplies a process-lifetime fallback if pi has no native id.
Child shells and hook subprocesses inherit that environment. No new dependency is required.

The adapter tests verify stable ids within sessions and different ids across sessions.
The marker suite verifies sanitization, Claude Code precedence, cross-session denial, legacy denial, and missing-id denial.
These checks do not prove that `/setup` or `/bug` completes interactively. The eight interactive runs are not done. They are not a merge condition under the amended AC5.

The migration notice still uses stderr. A successful SessionStart hook can claim the notice before a blocking gate runs.
A harness that hides stderr from successful SessionStart hooks can hide this notice. This visibility limit remains unverified.
Run the skill again to create a keyed marker. Restart only when the loaded skill text is outdated.
