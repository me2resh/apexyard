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

## Evolution (CI regressions on #1926)

Unconditional `. _lib-fail-closed-json.sh || exit 2` in every remapping hook broke fixture sandboxes that copy a hook without that sibling library (process-budget, command-scrub false-positive checks, legacy markers, fan-out, tracker diagnostics). Claude Code Bash and Edit/Write paths must not load the library: remap only for `shellToolCall` and other unknown command-shaped names.

The wildcard dispatcher early-outs used bare `exit 0`, which violates AgDR-0256 D9 33 (`test_prmeta_1759.sh`). Planned skip now sets `_dispatch_complete=1` and `exit "$_rc"` with `_rc=0`.

`test_settings_fail_closed.sh` and `test_manage_portfolio_adapters.sh` now treat the wildcard `dispatch-bash.sh --shell-alias-only` entry as an intended seventh fail-closed settings entry and select the primary Bash matcher when exercising block behaviour.

## Artifacts

- `.claude/hooks/_lib-fail-closed-json.sh`
- `.claude/hooks/tests/test_shell_call_classification.sh`
- `docs/harnesses/cursor.md`
