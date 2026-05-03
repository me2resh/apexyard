# Sunset the voice-prompts-on-pause feature

**Supersedes:** [AgDR-0009](AgDR-0009-voice-prompts-on-pause.md).

> In the context of the voice-prompts-on-pause feature shipping in dev as opt-in OFF on 2026-04-21 (PR #135, AgDR-0009) with the design framing "Phase 1: macOS-only via `say`, Phase 2: cross-platform, Phase 3: cloud TTS", facing the dual outcomes that (a) two months of opt-in availability produced zero adopters who turned it on and (b) the Phase 1 implementation itself was disabled in this fork's local override on 2026-05-03 with the rationale "bundled macOS Daniel voice was unreliable / robotic and tripped on non-question messages" before the feature ever reached a tagged release, I decided to **remove** the feature entirely from the framework rather than maintain disabled-by-default opt-in indefinitely — deleting the hook, the test, the wired-in Stop matcher entry, the `voice_prompts` config block in defaults + override, and the documentation section, while preserving AgDR-0009 in place as a historical record of the original decision (decision records are history, not configuration), to achieve a smaller adoption surface (no mysterious opt-in feature in fresh-fork `/setup` config dumps; no maintenance during framework refactors), accepting that any future need for "speak the assistant's question aloud" is a fresh design problem worth its own AgDR (likely cloud-TTS-first rather than `say`-first based on the Phase 1 reliability lessons), and that this change ships as part of the v1.2.0 release without an adopter-facing changelog mention because the feature never reached `main` (no released tag ever shipped it; adopters never saw it exist).

## Context

PR #135 / AgDR-0009 shipped the voice-prompts-on-pause feature with a phase plan: macOS `say` first, cross-platform second, cloud TTS third. The feature was always opt-in OFF; an adopter had to flip `voice_prompts.enabled` to `true` in `.claude/project-config.json` to wake the Stop hook.

What actually happened:

- **No adopter opted in.** Across the apexstack fork's two-month run, the feature was never enabled in any production session. No issue reports. No usage signals. No demand surfacing in adopter conversations.
- **Phase 1 was unreliable.** The shipped macOS `say` invocation with the bundled "Daniel" voice tripped on non-question messages, sounded robotic, and surfaced enough false positives that this fork itself disabled the feature on 2026-05-03 — the same week we started thinking about whether to keep it.
- **Phase 2 / Phase 3 never began.** No work toward cross-platform support. No cloud-TTS plumbing. The feature was frozen at Phase 1.
- **Feature still cost real bytes.** 9k of hook script, 9k of test, a Stop matcher entry, a config block in defaults, an override in this fork, and a documentation section in `docs/project-config.md`. All maintained, none firing.

This is the worst flavour of dead code: opt-in OFF means it's invisible to adopters who don't read the config carefully, but it ages, requires occasional maintenance during refactors, and clutters every fresh-adopter `/setup` config dump as a mysterious feature they have to ignore.

The pre-release moment for v1.2.0 is the right time to decide: keep the feature dormant, or pull it out cleanly. Keeping it perpetuates the maintenance cost; pulling it shrinks the framework surface to what's actually used.

## Options

### Option A — Keep the feature; mark it experimental

| Pros | Cons |
|------|------|
| Future adopters who want it can opt in | Bytes still maintained; opt-in OFF means it's invisible until the maintainer's next refactor breaks it |
| AgDR-0009's phase plan stays viable | No evidence anyone wants Phase 2 / Phase 3 work — would be speculative effort |

Rejected. Two months of zero adoption is enough signal — the feature isn't pulling its weight.

### Option B — Keep the feature; aggressively dogfood it

| Pros | Cons |
|------|------|
| Forces the reliability issues to surface and get fixed | This fork already disabled it because Phase 1 was unreliable; reversing that decision pre-release is moving in the wrong direction |
| Could find latent demand | "Build it and they will come" — they didn't |

Rejected. We already tried; the bundled voice was the bottleneck, not the framing.

### Option C — Remove the feature entirely; preserve AgDR-0009 as history (CHOSEN)

| Pros | Cons |
|------|------|
| Smallest adoption surface — `/setup` config dumps shrink, fresh-fork docs are cleaner | Any future "speak the question aloud" work starts from scratch — but that's a feature, not a bug |
| AgDR-0009 still readable as the decision record of the original phase plan; AgDR-0013 explains the supersession | Writing the supersession AgDR is overhead — paid here, once |
| No adopter-visible behaviour change (feature never reached `main`) | None — supersession is internal, not a breaking change |
| Pre-release timing — feature gets pulled in the same v1.2.0 that introduces hardened merge gates and bootstrap exemption; clean v1.2.0 cut | None |

**Chosen.** Same reasoning shape as past framework cleanups: when a config-driven feature has had a fair shot at adoption and produced no signal, retire it. AgDR-0009 stays in place as the historical record; AgDR-0013 explains the supersession.

### Option D — Remove the feature AND remove AgDR-0009

| Pros | Cons |
|------|------|
| Cleanest — no AgDR-supersession chain | Decision records are history; deleting them rewrites that history. Future readers asking "why was this feature in the codebase?" would have no answer. |
| Frees the next sequential AgDR number | Wrong reason to delete an AgDR |

Rejected. AgDRs are append-only — they describe decisions made at a point in time, and stay readable even after the decisions are reversed or superseded. Same convention as ADRs in the broader software engineering literature.

## Decision

**Option C — remove the feature entirely; preserve AgDR-0009 as history; this AgDR (AgDR-0013) records the supersession.**

Concrete deletions (all in the same PR as this AgDR):

1. `.claude/hooks/voice-prompt-on-pause.sh` — gone
2. `.claude/hooks/tests/test_voice_prompt_on_pause.sh` — gone
3. `.claude/settings.json` — Stop hook entry removed (the entire `Stop` matcher block became empty after this and is removed)
4. `.claude/project-config.defaults.json` — `voice_prompts` block removed
5. `.claude/project-config.json` (this fork's local override) — `voice_prompts` block removed (file becomes `{}`)
6. `docs/project-config.md` — entire `## Voice prompts` section removed
7. `docs/agdr/AgDR-0010-portfolio-config-and-self-healing.md` — line 32 example reference to `voice_prompts` swapped for `leak_protection` / `ticket` (still-current config blocks)

Preserved:

- `docs/agdr/AgDR-0009-voice-prompts-on-pause.md` — kept verbatim. The phase plan and Phase 1 reasoning still describe the original decision faithfully. A `Supersedes` header in this AgDR (AgDR-0013) creates the cross-link.
- AgDR-0010's line 115 reference to AgDR-0009 — kept. AgDR-0010 references AgDR-0009 as the precedent for the default-OFF / opt-in-via-config pattern, which is still true historically. The pattern survives even though this specific instance of it doesn't.

Bundled with [#77](https://github.com/me2resh/apexyard/issues/77) — the bundle adjusts hook/skill counts in `CLAUDE.md` and the v0.3.0 stats line in `CHANGELOG.md` to reflect the post-removal reality.

## Consequences

### Now smaller

- 24 hooks instead of 25 (one removed). The hook count line in `CLAUDE.md` is updated.
- `/setup` config dumps no longer surface a `voice_prompts` block on fresh forks. Cleaner first-impression.
- `.claude/project-config.defaults.json` is shorter; the schema is one block lighter.

### Now lossier

- Adopters who wanted the feature (none surfaced) lose the opt-in. They can vendor the old hook + skill into their fork from git history if needed.
- Phase 2 / Phase 3 work on cross-platform / cloud TTS would need to start from scratch with a fresh AgDR. That's the right thing — Phase 1's lessons (avoid `say` reliability, prefer cloud TTS for consistency) inform the future design but don't constrain it.

### No adopter-facing changelog mention

The feature never reached a tagged release on `main`. The dev branch had it for two months but no adopter who pulls v1.2.0 will see a regression — they never had it in the first place. The published v1.2.0 changelog therefore doesn't enumerate "voice-prompts feature retired" as an adopter-visible change, because from the adopter's perspective there's nothing to be retired. The framework's internal record (this AgDR + the preserved AgDR-0009) captures the full story for future contributors.

### Future work — when "speak the question aloud" comes back

If the use case re-surfaces (e.g. accessibility for users who've stepped away from the keyboard, or remote-pairing scenarios where audio cues help), the work starts as a fresh AgDR. Likely shape:

- **Cloud TTS first**, not local. ElevenLabs / OpenAI TTS / Google. Better voices, consistent across platforms, single integration point.
- **Opt-in via a less generic config name** — `audio_alerts` or `pause_audio` rather than `voice_prompts`. The latter became overloaded with "voice = speech synthesis" connotations.
- **Tighter trigger heuristic** — Phase 1 fired on too many turn-ends. A future implementation should require an unambiguous "I'm waiting" signal, not a heuristic over the last paragraph.

None of that is committed work — the feature is currently retired with no successor scheduled.

## Artifacts

- `me2resh/apexyard#157` — the removal ticket
- `me2resh/apexyard#77` — bundled hook-count fix
- AgDR-0009-voice-prompts-on-pause.md — preserved historical record (the original Phase 1 design)
- This AgDR (AgDR-0013) — the supersession record
- PR (TBD) bundling #157 + #77 — the actual deletion commits + this AgDR
