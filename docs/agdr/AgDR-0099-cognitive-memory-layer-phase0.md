# Cognitive memory layer — Phase 0 scaffold

> In the context of adopters having no single, governed home for cross-session, cross-project experience (informal notes bolted on outside the framework's governance model), facing a maintainer-approved but larger design space (a SQLite/FTS recall engine, capture/recall hooks, a `/learn` self-improving-skills loop) that deserves its own sign-off before it lands, I decided to ship only a docs-only `.claude/memory/` scaffold — a README that draws the boundary, tracked example templates, and a gitignored home for real per-clone content — to achieve a low-risk, reversible foundation that adopters can start using today, accepting that the scaffold's own functional value is latent until a future, separately-approved phase adds capture and recall.

## Context

me2resh/apexyard#692 originally proposed a full cognitive-memory system: a SQLite/FTS recall engine, `SessionStart`/`PostToolUse` capture hooks, and a `/learn` self-improving-skills loop, alongside the scaffold. The maintainer reviewed the proposal (2026-06-24 comment) and explicitly scoped this contribution down to **Phase 0 only** — a documented `.claude/memory/` home — deferring the engine, the hooks, and the skills to a future issue that will need its own AgDR and maintainer alignment. The maintainer's six acceptance criteria for Phase 0:

1. Markdown + scaffold only — `.claude/memory/` with `MEMORY.md`, `USER.md`, `README.md`, and a gitignored `db/`. No Python, no hooks, no new skills in this PR.
2. Optional + fail-soft by construction — nothing else may require it; its absence changes no behavior.
3. README does the heavy lifting — what it is, that it's optional, and how it relates to (and does NOT duplicate) Claude Code's native memory + AgDRs.
4. No new runtime dependencies; respects the ops-root resolution conventions.
5. An AgDR recording the decision + an explicit "out of scope for now" list.
6. No behavioral wiring — no SessionStart/PostToolUse hooks, no skill nudges, in this PR.

A follow-up agent-generated Product × Tech review (2026-07-03, Omar/Hisham, advisory) additionally flagged a leak/privacy risk in a literal reading of AC 1: if `MEMORY.md` and `USER.md` themselves were tracked files (rather than the `db/` gitignore alone), any real cross-project or adopter-specific notes written into them would be committed and pushed to the public upstream fork — the exact failure mode `docs/agdr/AgDR-0064-onboarding-example-file-and-guard.md` already fixed for `onboarding.yaml` (real config leaking into public git history).

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Track `MEMORY.md` / `USER.md` directly (literal AC 1 reading), only `db/` gitignored | Matches the AC's file list most literally | Real per-adopter memory content becomes committed, public-fork content by default — the onboarding.yaml leak class this framework already fixed once |
| Example-file + gitignore, mirroring `onboarding.example.yaml` / `onboarding.yaml` (chosen) | Safe path is the default; reuses an established, well-understood framework convention; adopters get a documented starting point without risking a public leak | The literal filenames `MEMORY.md`/`USER.md` in AC 1 are read as "the tracked artifact", not "the gitignored local file" — flagged explicitly in the PR as a deliberate interpretation, not silently reinterpreted |
| Track real files but instruct adopters "don't put private info in them" | No new convention to learn | Relies purely on adopter discipline for a public fork; the whole point of the `.env.example` pattern this repo already uses is to not rely on discipline for this exact class of leak |

## Decision

Chosen: **example-file + gitignore**, matching `onboarding.example.yaml` / `onboarding.yaml`.

- Track `.claude/memory/README.md` (the boundary-drawing doc), `.claude/memory/MEMORY.example.md`, `.claude/memory/USER.example.md` (placeholder templates, headings only, no real content), and `.claude/memory/db/.gitkeep` (holds the directory so `db/` exists post-clone).
- Gitignore the real, per-clone files: `.claude/memory/MEMORY.md`, `.claude/memory/USER.md`, and any `.claude/memory/db/*` content (SQLite files, should Phase 1+ ever add them) — mirroring the `.claude/session/` and `onboarding.yaml` gitignore blocks already in `.gitignore`.
- No hook backstop is added in this PR (unlike `block-onboarding-in-git.sh`) — Phase 0 explicitly ships **no hooks** (AC 6). If real memory content starts leaking upstream in practice, a follow-up PR can add a placeholder-diff guard the same way #517 did for onboarding — that is out of scope here.

This directly satisfies AC 1 (the four named files/dirs exist, `db/` is gitignored) while resolving the ambiguity the literal wording left open, in the direction the framework's own established convention and the Product × Tech review both point.

## Consequences

- `.claude/memory/` ships in every fork from this PR onward: `README.md` + two `.example.md` templates + `db/.gitkeep`, all tracked; `MEMORY.md`, `USER.md`, and `db/*` (except `.gitkeep`) gitignored.
- Nothing else in the framework reads, requires, or references these files at runtime — no `SessionStart`/`PostToolUse` hook touches them, no skill nudges an adopter toward them (AC 2, AC 6). An adopter who never looks at `.claude/memory/` sees byte-for-byte identical framework behavior.
- The README explicitly draws the boundary against `docs/agdr/` (point-in-time technical decisions) and Claude Code's own native session memory (`~/.claude/projects/.../memory/MEMORY.md`, per-conversation) so adopters don't confuse the three.
- Phase 1+ (recall engine, capture hooks, `/learn`) is explicitly out of scope for this AgDR and this PR. It will need its own AgDR and separate maintainer sign-off, per the maintainer's 2026-06-24 comment on #692.
- Fork-drift surface: every adopter fork now inherits a new tracked directory. If a later phase restructures `.claude/memory/`, that adopter forks need a small migration step — kept explicitly minimal here to limit that blast radius.

## Artifacts

- Issue: me2resh/apexyard#692
- Files: `.claude/memory/README.md`, `.claude/memory/MEMORY.example.md`, `.claude/memory/USER.example.md`, `.claude/memory/db/.gitkeep`, `.gitignore`, `CLAUDE.md`, `docs/agdr/AgDR-0099-cognitive-memory-layer-phase0.md`
- Related: AgDR-0064 (onboarding example-file + gitignore convention, the pattern this decision mirrors)
