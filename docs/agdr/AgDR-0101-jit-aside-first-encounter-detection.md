# Fire just-in-time glossary asides via a per-session seen-set marker, gated on guided depth mode

> In the context of the increment-2 teach-in-context asides needing to explain each core term exactly once, at its first encounter, in guided mode only (FR-5 / US-4), facing a choice between the agent tracking "already explained" in-context, a durable session-state seen-set, or a hook that injects asides into output, I decided to record surfaced terms in a **per-session seen-set marker** `.claude/session/onboarding-glossary-seen` consulted before each aside and gated on the active depth mode being `guided`, to achieve deterministic once-per-term asides that survive context compaction and are unit-testable, accepting one new gitignored session file and a clear-on-session-start sweep to keep it from leaking across sessions.

## Context

Increment-2's teach-in-context layer (technical design: `docs/technical-designs/onboarding-increment-2.md`, ticket #912) must surface a short plain-language aside the **first time** framework output uses each of the five core terms toward a guided-mode adopter (FR-5): *"the first time a ticket is created … a short plain-language aside accompanies it — not a wall of definitions up front."* The AC constraints are precise:

- **Once per term** — the aside for "ticket" fires on the first ticket mention, not every mention (US-4: "just-in-time … not a wall of definitions").
- **Guided mode only** — a terse-mode adopter sees **zero** asides by default (FR-5, US-4 AC).
- **Additive, not a mode switch** — a single parenthetical/one-liner that does not derail the task, and changes no gate or permission (NFR Consistency + US-5 AC).

"First encounter, once per session" needs a memory of what has already been surfaced. Where that memory lives — the agent's working context, a durable session file, or a hook — is a genuine mechanism choice with real reliability/testability trade-offs, so it is AgDR-class.

The related question of *how depth mode itself is stored and overridden* is resolved in the design body (§ D2, the `.claude/session/onboarding-depth-mode` seam), not here — this record covers only the **first-encounter** mechanism, which reads that mode as an input.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. In-context self-discipline** — the agent remembers, within the conversation, which terms it has already explained | Zero new state; simplest to write | Not durable across context compaction / a resumed session (the very long first-run sessions this targets are where compaction bites) → a term silently re-explained or, worse, never explained; nothing to unit-test; no mechanical account of "did terse see zero asides?" |
| **B. Per-session seen-set marker** `.claude/session/onboarding-glossary-seen` — append a term-key on first surface, check membership before each aside; gated on depth mode `guided` *(chosen)* | Deterministic once-per-term regardless of compaction; greppable + unit-testable ("after surfacing `ticket`, the file contains `ticket` and a second `ticket` mention emits no aside"); mirrors the framework's existing session-marker idiom (`active-bootstrap`, `active-issue`); cleared by the same `clear-*-marker` SessionStart sweep pattern | One new gitignored session file; a documented write/read/clear contract |
| **C. Hook injects asides** — a PostToolUse / UserPromptSubmit hook scans output for the five terms and appends definitions | Fully mechanical, agent can't forget | Hooks cannot edit assistant prose (they emit their own banners), so it can't produce an inline parenthetical — it would bolt a separate banner onto output, which *is* the "wall of definitions / mode switch" the AC forbids; scanning output to mutate teaching behaviour risks the NFR "additive text, not new gates"; heavyweight and invasive for a presentation nicety |

## Decision

Chosen: **Option B — a per-session seen-set marker gated on guided depth mode.**

Mechanism (detailed in the design § "D3 — Just-in-time aside firing"):

1. **Gate on mode first.** Before considering any aside, read the active depth mode from `.claude/session/onboarding-depth-mode` (§ D2 seam). If it is not `guided`, emit **no** aside and do not touch the seen-set — terse-mode's "zero asides" is structural, not conventional.
2. **Check the seen-set.** In guided mode, when about to use one of the five terms toward the adopter, read `.claude/session/onboarding-glossary-seen` (a newline-delimited list of term-keys already surfaced this session). If the term's key is already present, emit the term plainly with no aside.
3. **Surface + record.** If the key is absent, slice that term's plain-language sentence from `docs/onboarding/glossary.md` (per AgDR-0100's `term:` key), emit it as the single-line parenthetical alongside the natural output, and append the term-key to the seen-set.
4. **Clear on session boundary.** The marker is per-session (not fork-lifetime): a returning adopter gets the refresher again. It is swept by the existing SessionStart clear-marker pattern (same backstop that clears `active-bootstrap`), so an interrupted session cannot suppress asides forever.

"First encounter" is deliberately **per-session**, not per-fork: fork-lifetime suppression would need persistent state and would deny a returning non-technical adopter the very refresher US-4 exists to give. Per-session matches the "just-in-time, in this walkthrough" intent.

Rationale for B over A: the target sessions are long guided first-runs where context compaction is exactly when in-context memory fails — a durable marker is the difference between a deterministic aside and a coin-flip, and it is the only option that makes "terse saw zero asides" a testable assertion. Rationale for B over C: a hook cannot produce the *inline* parenthetical the AC mandates (hooks emit separate banners, not edits to prose), and mechanically scanning output to inject teaching would be the derailing "mode switch" the AC forbids — the aside is a presentation choice the skill makes, which is where the seen-set belongs.

## Consequences

- New per-session marker `.claude/session/onboarding-glossary-seen` (gitignored, per-machine), written by the guided-mode aside path in `/onboard` (#913) and read before each candidate aside. Newline-delimited term-keys matching AgDR-0100's `term:` keys.
- The aside path **depends on the depth-mode seam** `.claude/session/onboarding-depth-mode` (§ D2, built in #914). To let #913 and #914 build independently (they are sibling tickets, both blocked only by #912), the read contract defines a **safe default: absent depth-mode file → treat as terse → emit no asides.** So even if #913's asides land before #914's mode-writer, no aside ever leaks to a terse/unset adopter. This is the intra-increment ordering seam (analogous to increment-1's #910-asset-before-#911).
- The SessionStart clear-marker sweep is extended (or a sibling added) to clear `onboarding-glossary-seen`, mirroring `clear-bootstrap-marker.sh`. Build task under #913.
- Unit-testable: a bash test asserts (a) terse mode + term mention → seen-set untouched, zero asides; (b) guided mode + first mention → key appended, aside emitted; (c) guided mode + second mention → no aside. This is the regression guard that lets the mechanism ship (like increment-1's `test_fresh_fork.sh`).
- No gate, permission, or role boundary changes — the marker only decides whether an explanatory sentence accompanies otherwise-identical output (NFR + US-5 AC honoured).

## Artifacts

- Technical design: `docs/technical-designs/onboarding-increment-2.md` § "D2" (depth-mode seam) and § "D3" (aside firing)
- PRD: `docs/prds/onboarding-overhaul.md` (#902 / #905) — FR-5, US-4, US-5 AC
- Ticket: [me2resh/apexyard#912](https://github.com/me2resh/apexyard/issues/912) · build in [#913](https://github.com/me2resh/apexyard/issues/913) (asides) with the depth-mode seam from [#914](https://github.com/me2resh/apexyard/issues/914)
- Prior art: `active-bootstrap` / `clear-bootstrap-marker.sh` session-marker idiom (increment-1 design § "Bootstrap-gate coherence"); increment-1 `.claude/session/onboarding-tech-level` signal seam (§ D5)
- Related: AgDR-0100 (glossary storage — the asset this mechanism reads per-term)
