# Harness support — Cursor

**Status:** In progress — tracked by **#831**. Adapter being built now. Not shipped yet.

Cursor is an IDE-based agent harness that supports repo-local hooks with native `exit 2` blocking. That makes it a natural fit for the **declarative-generate** adapter shape (the same family as the Codex adapter): ApexYard generates a Cursor-native hook config that delegates every gate decision to the unmodified `.claude/hooks/*.sh`. This page describes the *intended* shape; nothing here is claimed as done.

## What's enforced vs advisory today

**Today:** nothing mechanical under Cursor yet — the generator isn't shipped. A Cursor user gets ApexYard's **advisory** governance now via the repo's `AGENTS.md` (which Cursor auto-loads) plus the rules and skills as plain markdown.

**Intended (once #831 lands):** the delegated gate set the Codex and pi adapters already enforce — the two-marker merge gate, red-CI block, design/architecture review gates, secrets/leak-protection, and ticket-first / migration-ticket-first edit blocking — each decided by the canonical bash hook. Security-critical gates are intended to **failClosed** (block if the hook can't run), not fail open.

## How it works (transport)

Intended shape: a generator emits a **`.cursor/hooks.json`** from `.claude/settings.json`, with each hook `command` exec'ing the unmodified `.claude/hooks/*.sh`. Cursor's native `exit 2` blocking maps directly to the hooks' existing block contract, so no exit-code translation layer is needed — the fidelity Codex's adapter proves in-repo carries over. This is the **declarative-generate** pattern from the [harness index](README.md#adapter-authoring-pattern-for-future-harnesses): the durable contribution is the generator + its tests, and the generated `.cursor/` tree is regenerable output.

## How to install / generate

Not applicable yet. Generate instructions will ship with the adapter under **#831** (which will add `docs/cursor-adapter.md` and a dedicated AgDR). This page will link to those once merged.

## Gaps + tracking

- **The generator itself** — emitting `.cursor/hooks.json` and its drift-check — is unbuilt on `main`/`dev` today. Tracked as **#831**.
- **Live model-turn conformance** — proving a real, credentialed Cursor turn is actually blocked by a gate (not just a generated-config test) will be an explicit AC on #831.

## Related AgDRs

- [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md) — the Codex generator, the declarative-generate precedent this adapter follows
- [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md) — hooks stay bash; harnesses reach them via adapters
- A dedicated Cursor-adapter AgDR will be added by **#831**.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
