# Harness support — Cursor

**Status:** Adapter **merged** (#831 → PR #838, [AgDR-0091](../agdr/AgDR-0091-cursor-adapter-generation.md)); live Cursor-runtime conformance test pending ([#840](https://github.com/me2resh/apexyard/issues/840)).

Cursor support follows the same declarative-generate pattern as Codex: `.cursor/hooks.json` is **generated** from the canonical `.claude/` runtime and every generated hook **delegates to the unmodified `.claude/hooks/*.sh`** — gate logic never forks. The full generate / drift-check workflow lives in **[`docs/cursor-adapter.md`](../cursor-adapter.md)** (linked here, not duplicated).

## What's enforced vs advisory today

**Delegated (blocking, by construction):** Cursor's hook contract natively treats **exit code 2 as deny**, so the bash hooks' block semantics pass through without translation. The generated `beforeShellExecution` entries carry every shell-command gate — the two-marker merge gate (both `gh pr merge` and `gh api …/merge` shapes), red-CI block, ticket-first, secrets/leak-protection — each deciding via the canonical bash hook. The in-repo smoke test (`.claude/hooks/tests/test_sync_cursor_adapter.sh`, 25 assertions) proves the stdin remap and exit-code preservation across the adapter boundary.

**failClosed hardening:** the 9 security-critical gates (merge gates, red-CI, design/architecture review, secrets scan, trust-chain/leak hooks) are generated with Cursor's `"failClosed": true` — a crashed or timed-out gate hook **blocks** instead of failing open. This is a net hardening over Claude Code's own posture. Advisory/process hooks stay fail-open, matching their native behaviour.

**Advisory:** a generated `.cursor/rules/apexyard.mdc` carries the advisory governance bridge (git conventions, ticket vocabulary, reporting rules) as Cursor rules content.

## How it works (transport)

`bin/sync-cursor-adapter.sh` emits `.cursor/hooks.json` from `.claude/settings.json`:

- **Event mapping:** `Bash` → `beforeShellExecution` · `Edit|Write|MultiEdit` → `preToolUse` (matcher) · `SessionStart` → `sessionStart` · `UserPromptSubmit` → `beforeSubmitPrompt`, with post-tool events split the same way.
- **Stdin remap:** Cursor delivers the shell command top-level (`{"command": …}`); the generated command re-wraps it into the Claude-Code shape (`{"tool_name":"Bash","tool_input":{"command":…}}`) before piping to the hook — so the hooks run byte-identical logic on both harnesses.
- Claude Code's handler-level `if` predicates are compiled into the same `Bash(glob)` preflight filter the Codex adapter uses; unconditional hooks get glob `*` (remapped, never skipped).
- No hook bodies are copied; every entry execs `$r/.claude/hooks/*.sh`.

## How to generate

```bash
bin/sync-cursor-adapter.sh            # generate .cursor/hooks.json + rules
bin/sync-cursor-adapter.sh --check    # verify generated files still match .claude/ (non-zero on drift)
bin/sync-cursor-adapter.sh --clean    # remove generated .cursor tree before regenerating
```

## Gaps + tracking

- **Live Cursor-runtime conformance** — the in-repo smoke proves delegation by construction; a credentialed Cursor turn actually being blocked has not been recorded. The conformance test must explicitly assert the top-level-`.command` stdin contract (if Cursor's schema drifts from it, shell gates would fail open silently). Tracked in **#840**.
- The `preToolUse`/`postToolUse` passthrough path (non-shell tools) carries only process/advisory hooks; its `tool_input` field names are unverified against a real Cursor session — every enforcement-critical gate rides the verified shell path. Also #840.

## Related AgDRs

- [AgDR-0091](../agdr/AgDR-0091-cursor-adapter-generation.md) — Cursor adapter generation; delegate gates to the `.claude/` runtime
- [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md) — the Codex precedent this adapter mirrors
- [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md) — hooks stay bash (the source of truth the adapter execs)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
