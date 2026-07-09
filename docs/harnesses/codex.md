# Harness support — Codex

**Status:** ✅ **Live-proven (2026-07-09)** — a real `codex exec --dangerously-bypass-hook-trust -m gpt-5.5` model turn's `git add -A` fired the delegated `block-git-add-all.sh` (hook logged, verbatim block message, clean exit 2, nothing staged). Equivalent to the opencode/pi delegated-execution proofs. Adapter merged (#730, [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md)).

Codex support is **generated** from the canonical `.claude/` runtime rather than hand-maintained, so the two agent surfaces can't drift by hand. This page is the short orientation; the full generate / drift-check / tracking-policy workflow lives in **[`docs/codex-adapter.md`](../codex-adapter.md)** (kept at its existing path — linked here, not duplicated or moved).

## What's verified

- **Live delegated enforcement:** with hook-trust granted, a credentialed `codex exec -m gpt-5.5` turn issued `git add -A` and the unmodified `.claude/hooks/block-git-add-all.sh` fired and blocked it — clean exit 2, verbatim hook output, nothing staged. This is the live end-to-end conformance proof the [rebrand trigger](README.md#rebrand-trigger) requires; Codex is one of three adapters (with opencode and pi) that have cleared it.
- **Schema + model mapping correct:** the generated `.codex/hooks.json` schema is validated against the Codex hooks docs (AgDR-0088), and the model mapping is right — `opus`→`gpt-5.5` is the real ChatGPT-account default, `sonnet`→`gpt-5.4`, `haiku`→`gpt-5.4-mini`. The in-repo test (`.claude/hooks/tests/test_sync_codex_adapter.sh`) proves the generated command path preserves the hook stdin and exit-code contract (block on `exit 2`, allow on `exit 0`, skip on a non-matching predicate).

**It was a trust gap, not a capability gap.** An earlier probe saw `git add` reach execution with the hook not firing — but that was because Codex loads project-local hooks only when the `.codex/` layer is **trusted** (per the Codex docs: project-local hooks load only when the `.codex/` layer is trusted). Grant trust and the delegated bash runs exactly as under Claude Code. This puts Codex alongside opencode (`--auto`) and pi (`-a`) — every adapter enforces in headless once its precondition (a trust/approval flag or config location) is satisfied. See the precondition pattern in the [harness index](README.md#support-matrix).

## What's enforced vs advisory today

**Delegated (blocking, live-proven with trust):** the generated `.codex/hooks.json` keeps the commands that exec the *unmodified* `.claude/hooks/*.sh`. A `PreToolUse` gate that exits `2` blocks the action under Codex the same way it does under Claude Code — the merge gate, red-CI block, ticket-first, secrets/leak-protection, and the review gates all run the same audited bash. The `git add -A` block above exercised this path live.

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

- **Project `.codex/hooks.json` requires hook-trust to load.** Grant it one of three ways: `/hooks` (the interactive trust command), `--dangerously-bypass-hook-trust` (a headless one-off — how the live proof was run), or install the hooks to **user-level** `~/.codex/hooks.json` (trusted by default). Without trust, Codex runs the command without firing the project hook — the "trust gap" the earlier probe hit. This is the Codex analog of opencode's `--auto` and pi's `-a`.
- Run from inside an apexyard ops fork so the delegated hooks resolve the ops root.

## Gaps + tracking

No enforcement gap remains: with hook-trust granted the delegated gate fires cleanly during a real `codex exec` turn, and Codex is now one of the three live-proven adapters that cleared the [rebrand trigger](README.md#rebrand-trigger) bar. The residual ergonomics item is making the trust step frictionless — e.g. an install path that seeds user-level `~/.codex/hooks.json` so adopters don't need the `--dangerously-bypass-hook-trust` flag per run. Tracked in #840.

## Related AgDRs

- [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md) — Codex adapter generation; delegate gates to the `.claude/` runtime
- [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md) — hooks stay bash (the source of truth the adapter execs)
- [AgDR-0087](../agdr/AgDR-0087-reasoning-agents-require-frontier-model.md) — frontier-model floor for reviewer roles (why the label mapping keeps `opus` on Codex's strongest model)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
