# Voice prompts on assistant pause — macOS `say` Stop hook + config gate

**Superseded by:** [AgDR-0013](AgDR-0013-sunset-voice-prompts.md) (feature retired in v1.2.0). The decision recorded below is preserved as history; the feature itself is no longer in the framework.

> In the context of long ApexYard sessions where the assistant pauses for human input ("approved?", "merge X?", "design call: a/b/c?") and the user has stepped away from the keyboard, facing zero attentional signal that input is needed, I decided to ship a configurable Stop hook that speaks the question aloud via macOS `say` (Daniel voice for a Jarvis-from-Iron-Man feel) gated behind a project-config flag defaulting to OFF, to achieve attentional surfacing without forcing TTS on every adopter, accepting that the initial phase is macOS-only and uses a heuristic question-detector rather than ML.

## Context

ApexYard's interaction pattern in long sessions involves many discrete pause points where the assistant cannot proceed without explicit user input — per-PR merge approvals, design-review (a/b/c) choices, ambiguous "which path do you want", tool-result confirmations. These pauses are surfaced as plain text messages in the terminal. If the user has stepped away from the keyboard, the conversation stalls silently — the assistant is "waiting" but giving zero attentional signal.

This is a quality-of-life problem, not a correctness problem. The fix doesn't change the conversational mechanics; it adds an audible cue.

The user explicitly asked for a "Jarvis-from-Iron-Man" feel — a British-accented, premium-quality male voice. macOS bundles `Daniel (Premium)` which is the closest free voice to that style. ElevenLabs and OpenAI TTS would produce closer fidelity but at recurring per-character cost; macOS `say` is local + free.

The user also explicitly scoped initial phase to TTS-only (no voice input). They reply via keyboard.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Status quo — no audible signal | Zero work | Friction unchanged; user must babysit the terminal |
| **macOS `say` Stop hook with regex trigger heuristic, default OFF (CHOSEN)** | Free, local, no PII leaves the machine, ships immediately on adopter macOS, default-OFF is zero-impact for adopters who don't opt in | macOS-only (Linux/Windows are Phase 2), trigger heuristic is conservative regex (false-negatives preferred), voice quality limited to OS-bundled voices |
| OpenAI TTS / ElevenLabs from initial phase | Best voice quality (true Jarvis fidelity possible), cross-platform | Cost per spoken character (~$15/M chars for OpenAI, more for ElevenLabs), network dependency, privacy implications (assistant text would leave the machine), API-key management complexity |
| ML-based question detection in the trigger | More accurate "is this asking for input?" classification | Heavyweight; defers v1 indefinitely; adds an inference dep |
| Notification daemon / system-tray icon instead of TTS | Less intrusive than speech | Not "Jarvis-style" — defeats the user's explicit ask |

## Decision

Chosen: **macOS `say` Stop hook + regex trigger heuristic, default OFF, project-config-gated**.

Three reasons it wins:

1. **Initial-phase scope matches the user's framing.** They asked for "speak the question; I'll reply via keyboard". `say` does that and nothing more.
2. **Default-OFF makes this a pure-additive change for upstream.** Adopters who pull this commit see no behaviour change until they explicitly flip `voice_prompts.enabled` in their `.claude/project-config.json`.
3. **The trigger model is the load-bearing piece, not the TTS provider.** Once the heuristic is proven on real conversations, swapping `say` for OpenAI TTS (Phase 3) is a small change behind the same trigger gate. Starting with `say` lets us iterate on the trigger without the cost/privacy decisions.

### Trigger heuristic (default `questions-only`)

The hook speaks if the last assistant message:

- Ends with `?` (after stripping trailing whitespace + trailing markdown emphasis chars), OR
- Contains a recognised "Reply with X" / "Approved?" / "Confirm Y" / "(a)/(b)/(c)" / "which path" / "proceed?" pattern in its last paragraph

Anything else — informational summaries, tool-result reports, progress updates — is silent. The bias is toward false-negatives (a missed prompt is annoying; a TTS reading a 200-line tool output is unbearable).

A `trigger: "always"` mode exists for debugging the hook itself; production adopters use `questions-only`.

### Spoken-text extraction

The hook extracts only the **last paragraph** of the trigger message — typically where the call-to-action lives — not the full message. Markdown is stripped before TTS (`say` doesn't interpret backticks / asterisks / link syntax well). The result is truncated to `max_chars` (default 200) at the nearest sentence boundary.

This produces utterances like *"Reply approve 354 to write the CEO marker, or ship 354 to merge"* rather than reading 200 lines of glossary tables.

## Consequences

### Positive

- **Default-OFF is a pure-additive change.** No behaviour change for existing forks until they opt in.
- **Single platform hides cross-platform complexity.** Linux/Windows fork-out paths can be added in Phase 2 without re-architecting the trigger model.
- **Local + free.** No API keys, no PII leaving the machine, no recurring cost.
- **Tests are deterministic.** A `VOICE_PROMPTS_SYNC=1` env var makes the hook run `say` synchronously instead of fire-and-forget, so the test runner doesn't have to race against orphaned background processes.
- **Hook overhead on every turn-end is sub-millisecond** in the disabled state — the fast-path is a single `config_get_or` call before exit 0.

### Negative

- **macOS-only.** Adopters on Linux / Windows see no benefit until Phase 2. Acknowledged trade-off; the trigger model + config schema can be designed once and the platform layer added without re-architecting.
- **Trigger heuristic false-positives possible.** A tool-result message that happens to end with `?` would get read aloud. Mitigation: deliberate conservative heuristic, configurable, easy to disable per-session.
- **TTS sound-output collision.** If the user is on a call when the hook fires, `say` will speak through the active output device. Acceptable side-effect; an env-var override could disable per-session in Phase 2.
- **Privacy.** When/if Phase 3 adds cloud TTS providers (OpenAI, ElevenLabs), assistant text would leave the local machine. That is an AgDR-worthy decision in its own right; this AgDR explicitly does NOT cover it.

### Reversibility

Fully reversible. Set `voice_prompts.enabled` to `false` in `.claude/project-config.json` (or remove the key entirely) and the hook is a sub-millisecond no-op on every Stop event. To remove the hook entirely, drop the `Stop` entry from `.claude/settings.json` and the hook script no longer fires. No data, no config drift.

## Future phases (NOT in this AgDR)

- **Phase 2** — cross-platform TTS (Linux `espeak` / `spd-say`, Windows `Add-Type ... SpeechSynthesizer`). Same trigger model, OS-detection in the hook.
- **Phase 3** — high-quality cloud TTS providers (OpenAI TTS, ElevenLabs). New config field `provider`. AgDR-worthy on cost vs quality vs privacy.
- **Phase 4** — voice input. Whisper-based STT, voice-trigger phrases ("approve PR 354", "merge"). Significant scope; needs its own design.
- **Phase 5** — per-message overrides (a way for the assistant to mark a message as "speak this" or "skip TTS" inline).

## Artifacts

- Branch: `feature/#134-voice-prompts`
- Ticket: me2resh/apexyard#134 — *"[Chore] Configurable Jarvis-style voice prompts when waiting for user input"*
- Files: `.claude/hooks/voice-prompt-on-pause.sh`, `.claude/hooks/tests/test_voice_prompt_on_pause.sh`, `.claude/project-config.defaults.json` (new `voice_prompts` block), `.claude/settings.json` (new `Stop` hook entry), `docs/project-config.md` (new section), this AgDR.
- Related AgDRs: AgDR-0007 (release-cut branch model — this PR targets `dev`), AgDR-0001 (rule-mechanization-hooks — establishes the Stop hook as the right shape).
