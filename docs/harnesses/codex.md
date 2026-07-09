# Harness support — Codex

**Status:** ⏳ **Not enforcing in headless (2026-07-09).** The adapter generates a schema-correct `.codex/hooks.json` and the model mapping is right, but a definitive probe showed `codex exec -m gpt-5.5` runs a benign shell command *without* firing the project `.codex/hooks.json` hook (empty instrumentation log) — so headless `codex exec` does **not** honor project hooks. Not live-proven. Adapter merged (#730, [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md)).

Codex support is **generated** from the canonical `.claude/` runtime rather than hand-maintained, so the two agent surfaces can't drift by hand. This page is the short orientation; the full generate / drift-check / tracking-policy workflow lives in **[`docs/codex-adapter.md`](../codex-adapter.md)** (kept at its existing path — linked here, not duplicated or moved).

## What's verified vs not

- **Verified correct:** the generated `.codex/hooks.json` schema (validated against the Codex hooks docs, AgDR-0088) and the model mapping — `opus`→`gpt-5.5` is the real ChatGPT-account default, `sonnet`→`gpt-5.4`, `haiku`→`gpt-5.4-mini`. The in-repo test (`.claude/hooks/tests/test_sync_codex_adapter.sh`) proves the generated command path preserves the hook stdin and exit-code contract (block on `exit 2`, allow on `exit 0`, skip on a non-matching predicate).
- **NOT achieved:** live enforcement on the headless `codex exec` surface. A `codex exec -m gpt-5.5` run had a shell command reach execution with the project hook not firing — so on that surface the gate is bypassed, not enforced.
- **Untested (and likely required):** the interactive `codex` TUI and/or a **user-level** `~/.codex/hooks.json`. Codex may only load hooks in interactive mode or from a user-level config — mirroring the Cursor user-level finding. Verifying that path is the open item.

**Codex is a declarative-hooks adapter.** Unlike opencode and pi — imperative-plugin adapters whose gate runs inside the harness's own tool-call event, and which are therefore live-proven in headless/CLI — Codex delegates through a static `hooks.json` the harness must *load*. Its headless CLI (`codex exec`) doesn't load a project-level one, the same shape as the `cursor-agent` CLI. That single design difference is why Codex hasn't cleared the live bar. See the architectural split in the [harness index](README.md#support-matrix) for the full framing.

## What's enforced vs advisory today

**Delegated (by construction, but not firing in `codex exec`):** the generated `.codex/hooks.json` keeps the commands that exec the *unmodified* `.claude/hooks/*.sh`. By design a `PreToolUse` gate that exits `2` blocks the action the same way it does under Claude Code — the merge gate, red-CI block, ticket-first, secrets/leak-protection, and the review gates all run the same audited bash. The gap is the *loading*: the headless `codex exec` surface does not invoke these project hooks, so this delegation is currently unexercised there.

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

## Preconditions

- **Do not rely on `codex exec` (headless) for enforcement today** — it runs shell commands without firing the project `.codex/hooks.json` hook, so gates are bypassed on that surface. Treat it as advisory-only until the interactive/user-level path is verified.
- The generated hooks assume Codex loads a trusted **project** `.codex/hooks.json`; the open work is establishing whether the interactive `codex` TUI or a **user-level** `~/.codex/hooks.json` is what actually loads them (mirroring the Cursor user-level finding).

## Gaps + tracking

The honest gap is **the hook doesn't fire on `codex exec`**: the in-repo bash test proves command delegation and exit-code preservation *by construction*, but a definitive 2026-07-09 probe showed the headless CLI runs a command with the project hook not firing. So a credentialed, model-driven Codex turn actually blocked by a gate has **not** been recorded — and on the surface tested, isn't achievable. The next step is verifying the interactive TUI and/or user-level `~/.codex/hooks.json` path. This keeps Codex below the [rebrand trigger](README.md#rebrand-trigger) bar (which opencode + pi have cleared). Tracked in #840.

## Related AgDRs

- [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md) — Codex adapter generation; delegate gates to the `.claude/` runtime
- [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md) — hooks stay bash (the source of truth the adapter execs)
- [AgDR-0087](../agdr/AgDR-0087-reasoning-agents-require-frontier-model.md) — frontier-model floor for reviewer roles (why the label mapping keeps `opus` on Codex's strongest model)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
