# Harness support — opencode

**Status:** In progress — tracked by **#821**. Spike proved the adapter-over-bash pattern viable; the adapter is being built now. Not shipped yet.

opencode is a plugin-extensible agent harness. ApexYard's opencode support follows the same principle as every other adapter: **bash owns the gate decisions**, and a thin opencode-native layer carries each tool call into the unmodified `.claude/hooks/*.sh` scripts. This page describes the *intended* shape so adopters know what's coming; it deliberately claims nothing as done.

## What's enforced vs advisory today

**Today:** nothing mechanical under opencode yet — the plugin isn't shipped. An opencode user gets ApexYard's **advisory** governance now by reading the repo's `AGENTS.md` (the universal entry doc harnesses like Cursor/Aider/Cline/pi auto-load) plus the rules and skills as plain markdown.

**Intended (once #821 lands):** the same delegated gate set the pi and Codex adapters enforce — the two-marker merge gate, red-CI block, design/architecture review gates, secrets/leak-protection, and ticket-first / migration-ticket-first edit blocking — with each decision made by the canonical bash hook, not re-implemented in the plugin.

## How it works (transport)

Intended shape: a **TypeScript plugin** registered on opencode's tool-call hook that, for each matching tool call, reconstructs the stdin JSON the bash hook expects, spawns the unmodified hook, and maps its exit code (`2` = block, `0` = allow) to opencode's block/allow contract. The gate set is **derived from `.claude/settings.json`'s hook wiring** — the same "one config, two harnesses" property the pi dispatcher has — so adding a gate stays a one-place change rather than a per-harness edit. This is the **live-extension** adapter shape described in the [harness index](README.md#adapter-authoring-pattern-for-future-harnesses), mirroring the pi dispatcher.

## How to install / generate

Not applicable yet. Install instructions will ship with the adapter under **#821** (which will add `docs/opencode-adapter.md` and a dedicated AgDR). This page will link to those once merged.

## Gaps + tracking

- **The adapter itself** — the plugin, its gate table, and ops-root resolution — is unbuilt on `main`/`dev` today. Tracked as **#821**.
- **Live model-turn conformance** — the same last-mile asterisk as every adapter: proving a real, credentialed opencode turn is actually blocked by a gate (not just a by-construction transport test) will be an explicit AC on #821.

## Related AgDRs

- [AgDR-0082](../agdr/AgDR-0082-pi-gate-dispatcher-adapter.md) — the pi gate-dispatcher, the live-extension precedent this adapter follows
- [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md) — hooks stay bash; harnesses reach them via adapters
- A dedicated opencode-adapter AgDR will be added by **#821**.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
