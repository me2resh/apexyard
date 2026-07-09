# Harness support — Codex

**Status:** Adapter **merged** (#730, [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md)); live Codex-runtime conformance test pending.

Codex support is **generated** from the canonical `.claude/` runtime rather than hand-maintained, so the two agent surfaces can't drift by hand. This page is the short orientation; the full generate / drift-check / tracking-policy workflow lives in **[`docs/codex-adapter.md`](../codex-adapter.md)** (kept at its existing path — linked here, not duplicated or moved).

## What's enforced vs advisory today

**Delegated (blocking, by construction):** the generated `.codex/hooks.json` keeps the commands that exec the *unmodified* `.claude/hooks/*.sh`. A `PreToolUse` gate that exits `2` blocks the action under Codex the same way it does under Claude Code — the merge gate, red-CI block, ticket-first, secrets/leak-protection, and the review gates all run the same audited bash. The adapter's in-repo test (`.claude/hooks/tests/test_sync_codex_adapter.sh`) proves the generated command path preserves the hook stdin and exit-code contract across the adapter boundary (block on `exit 2`, allow on `exit 0`, skip on a non-matching predicate).

**Advisory:** the generated skills/agents carry the same guidance content as Claude Code's, but Claude-Code-specific advisory banners (role triggers, drift notices) are not part of Codex's documented hook shape.

## How it works (transport)

`bin/sync-codex-adapter.sh` emits:

- `.claude/skills/` → `.agents/skills/` (rewriting only the skill path references)
- `.claude/agents/*.md` → `.codex/agents/*.toml`, translating model-tier labels via the shared [`.claude/harness-models.json`](../../.claude/harness-models.json) matrix (`opus`→`gpt-5.5`, `sonnet`→`gpt-5.4`, `haiku`→`gpt-5.4-mini`)
- `.claude/settings.json` → `.codex/hooks.json`, preserving the commands that exec `$r/.claude/hooks/*.sh`

It deliberately does **not** copy the hooks, rules, migrations, or registries into `.codex/` — those stay canonical under `.claude/`. Claude Code's handler-level `if` predicates (not part of Codex's documented hook shape) are compiled into the generated shell command as a preflight filter.

## How to generate

```bash
bin/sync-codex-adapter.sh            # generate the adapter
bin/sync-codex-adapter.sh --check    # verify generated files still match .claude/ (non-zero on drift)
bin/sync-codex-adapter.sh --clean    # remove generated .agents/ and .codex/ trees before regenerating
```

Tracking policy, gitignore guidance, and CI `--check` enforcement: [`docs/codex-adapter.md`](../codex-adapter.md).

## Gaps + tracking

The one honest gap is **live Codex-runtime conformance**: the in-repo bash test proves command delegation and exit-code preservation, but a credentialed, model-driven Codex turn *actually* being blocked by a gate has not been recorded yet — that depends on Codex loading trusted project hooks and invoking matching hook events as documented. This is the same last-mile asterisk every non-Claude adapter carries, and it is exactly the bar the [rebrand trigger](README.md#rebrand-trigger) requires ≥2 adapters to clear.

## Related AgDRs

- [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md) — Codex adapter generation; delegate gates to the `.claude/` runtime
- [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md) — hooks stay bash (the source of truth the adapter execs)
- [AgDR-0087](../agdr/AgDR-0087-reasoning-agents-require-frontier-model.md) — frontier-model floor for reviewer roles (why the label mapping keeps `opus` on Codex's strongest model)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
