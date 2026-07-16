# Cognitive memory layer (Phase 0 — scaffold)

This directory is a **governed, optional home for cross-session, cross-project
experience** — the notes an adopter would otherwise bolt on outside the
framework entirely (a stray `notes.md`, a private wiki page, tribal knowledge
that lives in someone's head). It gives that experience one documented place
inside apexyard's SDLC, without requiring anything to use it.

This is **Phase 0** — a docs-only scaffold. It ships two markdown files, no
code, no hooks, no new skills. See `docs/agdr/AgDR-0099-cognitive-memory-layer-phase0.md`
for the decision record and the explicit out-of-scope list below.

## What's here

| Path | Tracked? | Purpose |
|------|----------|---------|
| `README.md` (this file) | Yes | What this layer is, what it isn't, how to use it |
| `MEMORY.example.md` | Yes | Placeholder template — copy to `MEMORY.md` and fill in locally |
| `USER.example.md` | Yes | Placeholder template — copy to `USER.md` and fill in locally |
| `MEMORY.md` | **No** (gitignored) | Your real cross-project / cross-session notes — per-clone, local only |
| `USER.md` | **No** (gitignored) | Your real operator preferences / working style notes — per-clone, local only |
| `db/` | Yes (empty, via `.gitkeep`) | Reserved for a future structured store. Empty in Phase 0 — no database, no code reads or writes here yet. |

The tracked `.example.md` files are placeholders (headings only, no real
content) — the same `.env.example` convention this framework already uses for
`onboarding.yaml` (see `onboarding.example.yaml` and
`docs/agdr/AgDR-0064-onboarding-example-file-and-guard.md`). Copy an example to
its real name and fill it in locally; the real file never gets committed.

```bash
cp .claude/memory/MEMORY.example.md .claude/memory/MEMORY.md
cp .claude/memory/USER.example.md .claude/memory/USER.md
```

## Why not just track `MEMORY.md` / `USER.md` directly?

Because this repo is typically a **public fork** that opens PRs upstream to
`me2resh/apexyard`. Real cross-project notes — client names, internal
decisions, adopter-specific context — belong on your machine, not in public
git history. The example-file + gitignore split keeps the safe path the
default, the same way `onboarding.yaml` does for company config. See
`docs/agdr/AgDR-0099-cognitive-memory-layer-phase0.md` for the full reasoning.

## What this is NOT

This layer deliberately does not duplicate two things the framework and the
harness already provide:

| Compared to… | How it differs |
|--------------|-----------------|
| **AgDRs** (`docs/agdr/`) | An AgDR is a point-in-time technical **decision** record — what was chosen, why, what the trade-off was. This layer is for accumulating **experience** over time (what tends to work, what an adopter prefers, recurring gotchas) — it doesn't replace or duplicate a single decision's record. |
| **Claude Code's native session memory** | The harness already maintains its own per-project, per-conversation memory (e.g. `~/.claude/projects/<project>/memory/MEMORY.md`) scoped to a single machine's Claude Code installation. This layer is apexyard's own **portfolio-governed** layer — part of the framework's tracked structure, reviewable and versionable the same way roles, rules, and skills are — not a replacement for the harness's own memory feature. Nothing here changes how the harness's native memory behaves. |

## Optional and fail-soft (by construction)

Nothing in the framework reads, requires, or references `.claude/memory/` at
runtime. No hook, no skill, no `CLAUDE.md` instruction depends on its
presence or contents. An adopter who never creates `MEMORY.md` or `USER.md`
sees byte-for-byte identical framework behavior — this is a scaffold you can
adopt at your own pace, not a new requirement.

## Explicitly out of scope for Phase 0

The original proposal (me2resh/apexyard#692) envisioned more than a docs
scaffold. The maintainer approved Phase 0 (this directory) while explicitly
deferring the rest to a future issue, its own AgDR, and separate maintainer
sign-off:

- A SQLite/FTS **recall engine** — a queryable store with structured search.
- `SessionStart` / `PostToolUse` **capture hooks** — automated write-to-memory
  behavior triggered by session events.
- A `/learn` or similar **self-improving-skills loop** — skills that adjust
  themselves based on accumulated memory.
- Any new runtime dependency (Python, a database driver, etc.) to support the
  above.

None of that exists yet. This directory is the documented, governed home
those future phases would eventually build on top of — not a preview of them.

## Split-portfolio note

Split-portfolio v2 adopters keep other adopter-specific content (custom
skills, custom handbooks, `onboarding.yaml`) in a private sibling repo rather
than the public framework fork — see `docs/multi-project.md`. Phase 0 makes
no decision about where a real `MEMORY.md`/`USER.md` should live in that
model; because both are already gitignored (never committed to either repo
by default), this is a non-issue for now. A future phase that adds capture
tooling should resolve its paths through the ops-root helper
(`.claude/hooks/_lib-portfolio-paths.sh`) the same way every other
portfolio-aware path in this framework does, rather than hardcoding
`.claude/memory/`.
