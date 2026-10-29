# Cursor Shell Gate Classification

> In the context of GH-1909, facing Cursor shell calls entering edit checks, I decided to share shell classification and add payload-aware dispatch to preserve the Bash gates, accepting one extra dispatcher invocation per non-Bash call.

## Context

- The operator reproduced the failure with cursor-agent 2026.10.22 on 2026-10-29.
- The stream names the call `shellToolCall`. The hook payload carries `tool_input.command`.
- Settings select the Bash dispatcher only for the `Bash` matcher. Edit matchers also select the protected-target gate.
- This record was written on 2026-10-29 for me2resh/apexyard#1909.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Add shell names to each matcher and hook | Small changes at each site | Duplicates classification and misses unknown names |
| Share classification and add wildcard dispatch | Handles command-shaped shell calls consistently | Adds a filtered dispatcher invocation |

## Decision

Chosen: **shared classification and wildcard dispatch**, because a tool name alone does not identify every shell transport.

The existing `_lib-fail-closed-json.sh` provides `hook_is_shell_call`. It accepts `Bash` (Claude Code) and `shellToolCall` (the reproduced Cursor stream). Other names require a non-empty command string and no file or notebook target. The stream name does not prove the name sent to hooks; the shape check covers that uncertainty.

The original Bash matcher keeps its existing behavior. The wildcard dispatcher entry skips Bash and non-shell payloads. Hooks normalize a shell classification locally before their existing branches. They retain the original JSON for downstream gates. The protected-target gate names the tool when an edit target is missing.

## Consequences

- Cursor shell calls run the existing Bash gates, including protected writes and ticket-first checks.
- File-target payloads retain edit checks unless they explicitly name a known shell tool.
- Malformed or targetless edits remain blocked. This change does not map Codex patch payloads or resolve #1900.
- #1900 can reuse the shared classification entry point without copying tool-name tests.

## Artifacts

- `.claude/hooks/_lib-fail-closed-json.sh`
- `.claude/hooks/tests/test_shell_call_classification.sh`
- `docs/harnesses/cursor.md`
