---
name: tutorial
description: "Standalone re-entry to the capability tour + full glossary — replays the roles/skills/gates walkthrough and all five terms any time, respecting depth mode. No /setup or /handover coupling."
disable-model-invocation: false
argument-hint: ""
effort: low
allowed-tools: Read, Bash
---

# /tutorial — Replay the Capability Tour

This is ticket #911 (M3) of the guided-onboarding walking skeleton (technical
design: `docs/technical-designs/onboarding-increment-1.md`, § D3/D4 and the
"Standalone `/tutorial` Reusability Spec"), layered with increment 2's
**depth adaptivity** (ticket #914, § D2/D5/D7) and now grown by **#915 (M7)**
to also render the **full teach-in-context glossary** — US-6 in full
(technical design: `docs/technical-designs/onboarding-increment-2.md` § D5).
`/tutorial` is a **standalone, read-only re-entry point** to the same
capability tour `/onboard` shows on first run, plus the plain-language
glossary for the five core SDLC terms — for the adopter who skipped either,
missed them, or just wants to see them again without faking a fresh fork.

**#914 wired `/tutorial` onto the shared depth-mode marker** so it renders
in the adopter's current `terse`/`guided` mode (one short "why this
matters" sentence per section in guided mode; bare, byte-for-byte
unchanged rendering in terse — NFR Backward-compat). **This ticket (#915)
adds the full glossary render after the tour** — reading the same shared
`docs/onboarding/glossary.md` asset `/onboard`'s guided-mode asides already
read one term at a time (#913) — and lifts the "tour-only" scope note from
Rule #4 below. It does **not** touch the depth-mode marker's derivation,
override, or transparency logic (that stays #914's, unchanged), and it does
**not** touch `/onboard`'s asides or the glossary content itself (that
stays #913's).

## What this skill does NOT do

`/tutorial` is deliberately disconnected from `/onboard`, `/setup`, and
`/handover` — it must work identically whether the fork is fresh, already
configured, or predates this feature entirely (US-6 AC). Concretely, it
never:

- Reads or writes `onboarding.yaml`
- Triggers fresh-fork detection (it does **not** call `fresh_fork_state()` —
  see `.claude/hooks/_lib-fresh-fork.sh` — for gating; that function exists
  for `/onboard` and the SessionStart hook, not for this skill)
- Runs any part of the `/setup` or `/handover` flows
- Writes to `apexyard.projects.yaml` or any other registry
- Touches the active-ticket marker or the bootstrap marker

**One deliberate, narrow exception (design § D5):** this skill MAY both
read and write the depth-mode marker
(`.claude/session/onboarding-depth-mode`) — deriving or asking a mode, and
honouring a plain-language override mid-`/tutorial`, is "solicited"
teaching (the adopter is running `/tutorial` on purpose), not a side
effect the increment-1 contract forbids. It may also read
`.claude/session/onboarding-tech-level` if present, purely as a
derivation input — this skill never writes that file.

Zero OTHER side effects. Running `/tutorial` should leave `git status`
exactly as it was before the command ran, aside from the gitignored
depth-mode marker under `.claude/session/`.

## Process

### 0. Resolve depth mode (design § D2/D5)

Before rendering, resolve the session's depth mode:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-onboarding-depth-mode.sh"
mode=$(depth_mode_read)
```

If a mode is already set this session (from an earlier `/onboard` run, or
an earlier `/tutorial` invocation), `depth_mode_read` returns it —
`terse` or `guided` — and you're done; skip to Step 1.

If no mode marker exists yet (a cold `/tutorial` on a fork that never ran
`/onboard`), try to derive one from the increment-1 tech-level signal, if
present:

```bash
signal=$(cat .claude/session/onboarding-tech-level 2>/dev/null || echo "")
mode=$(depth_mode_derive_from_signal "$signal") || mode=""
```

If `$mode` is still empty (no usable signal), this is a **solicited** flow
(the adopter ran `/tutorial` on purpose), so it's fine to ask — use the
SAME one-line fallback question increment-1's `/onboard` D5 uses:

```
Quick one — have you used git/GitHub before, or is this new to you?
```

Map the answer (`engineer`→`terse`, `non-engineer`→`guided`), then write
it:

```bash
depth_mode_write "$mode"
```

Never block the tour on this — if the adopter doesn't want to answer,
default to `terse` (the safe default, design § D2/D7) and proceed.

### 1. Read the shared tour asset

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh" 2>/dev/null || true
```

The shared asset path is fixed and framework-relative, not portfolio-relative
— resolve it from the git toplevel, not via any portfolio-paths helper:

```bash
tour_path="$(git rev-parse --show-toplevel)/docs/onboarding/capability-tour.md"
```

Read `docs/onboarding/capability-tour.md` with the `Read` tool. This is the
**single source of truth** — the same file `/onboard` Phase 1 reads. Never
paraphrase, summarize, or re-word its content; render it close to verbatim
(D3 in the technical design — rendering parity between the two consumers is
the whole point of the shared-asset seam).

If the file is missing (a corrupted or very old fork), say so plainly and
stop:

```
Can't find the capability tour at docs/onboarding/capability-tour.md — this
fork may be out of date. Try /update to sync with upstream, or check the
file wasn't deleted.
```

Do not fabricate tour content as a fallback.

### 2. Render the tour

Print the file's content (the "What's a role?" / "What's a skill?" /
"What's a gate?" sections plus the "How the loop works" closer), rendered
in the `$mode` resolved in Step 0:

- **`terse`** — render exactly as increment 1 did: no framing, no
  extra sentences. Byte-for-byte identical to a terse-mode run
  (NFR Backward-compat).
- **`guided`** — after the tour content, add ONE short plain-language
  "why this matters" sentence (e.g. tying the roles/skills/gates tour
  back to what the adopter will actually see day to day). Keep it to a
  single sentence — this is generic tour framing, distinct from the
  per-term glossary render that follows in Step 3 below.

Open with a one-line frame so the adopter knows this is a replay, not a
first-run flow:

```
Replaying the ApexYard capability tour — the same 60-second orientation
/onboard shows on first run. Nothing on your fork changes by running this.
```

Then render the tour content.

### 3. Render the full glossary (design § D5, US-6 full — #915)

Immediately after the tour, read the shared glossary asset:

```bash
glossary_path="$(git rev-parse --show-toplevel)/docs/onboarding/glossary.md"
```

Read `docs/onboarding/glossary.md` with the `Read` tool — the same single
source of truth `/onboard`'s guided-mode asides (#913) slice one term from.
Render **all five entries, top to bottom, in file order** (issue/ticket,
PR, merge, branch, CI). Never re-type, paraphrase, or hand-copy the
definitions into this skill file — read the file fresh every invocation,
exactly like Step 1's tour read (the increment-1 no-duplication discipline,
extended to the glossary asset per design § "Backward Compatibility &
Reuse").

A `/tutorial` invocation is **solicited** — the adopter ran the command on
purpose — so the glossary is **always shown**, regardless of mode; depth
mode only tunes how it's rendered, it never withholds it (this is the same
solicited/unsolicited line the design draws for `/onboard`'s asides vs. the
on-demand lookup rule, `.claude/rules/glossary-lookup.md`):

- **`terse`** — render the five definitions compactly, one after another,
  no extra framing.
- **`guided`** — render the same five definitions, each with its
  "**Example**:" line if the entry has one (most already do — see the
  glossary's read contract).

Open this section with a one-line frame so it reads as a distinct part of
the reply, not a continuation of the tour prose:

```
And here's the glossary — the plain-language meaning of the five terms
you'll see most often:
```

If `docs/onboarding/glossary.md` is missing (same corrupted/very-old-fork
case as the tour asset), say so plainly, same shape as Step 1's fallback,
and skip straight to Step 4 — a missing glossary should not block the tour
render that already succeeded.

### 4. Depth mode override + transparency (design § D2, FR-6/FR-9)

Same handling as `/onboard`'s — before rendering, and at any later point
this session, check the adopter's message for an override phrase or a
transparency question:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-onboarding-depth-mode.sh"
new_mode=$(depth_mode_classify_override "$ADOPTER_MESSAGE")
[ -n "$new_mode" ] && depth_mode_write "$new_mode"
```

Confirm a switch in one line (`Switching to guided — …` /
`Switching to terse — …`), same as `/onboard`. For "what mode am I in?",
answer with `depth_mode_report` — a read, never a write. If the switch
happens after the glossary has already been rendered once this
invocation, there's no need to re-render it — the switch takes effect on
the *next* `/tutorial` run or the next `/onboard` aside, per the
Reversibility NFR; `/tutorial` itself doesn't loop.

### 5. Close

End with a short pointer back to normal work — no branch, no follow-up
questions, no first-win prompt (that's `/onboard`'s job, not this skill's):

```
That's the tour, and the glossary. Run /tutorial again any time — it's
always safe, always free of side effects.
```

## Rules

1. **Never duplicate tour or glossary content.** Read
   `docs/onboarding/capability-tour.md` and `docs/onboarding/glossary.md`
   fresh every invocation; never inline, cache, or hand-copy their prose
   into this skill file. If either asset's content needs to change, it
   changes in one place and every consumer (`/onboard`, `/tutorial`, the
   on-demand lookup rule) picks it up automatically.
2. **No side effects, except the depth-mode marker.** No writes to
   `onboarding.yaml`, the registry, the active-ticket marker, or the
   bootstrap marker — ever. The ONE exception is
   `.claude/session/onboarding-depth-mode` (design § D5): deriving,
   asking, writing, or overriding it is in-contract "solicited" teaching,
   and it's the only marker this skill may write. Always write it through
   the shared helper (`_lib-onboarding-depth-mode.sh`'s `depth_mode_write`)
   — never a raw `echo`/redirect.
3. **Works on any fork state.** Configured, fresh, or pre-dating this
   feature entirely — the read-and-render behaviour must be identical in
   all three (aside from depth-mode rendering, which depends on the
   marker/signal, not fork state). Do not branch on `fresh_fork_state()`.
4. **Tour + full glossary + depth-mode rendering (#911, #914, #915).**
   `/tutorial` now renders both shared assets end to end, respecting depth
   mode. What it still does NOT do: the per-term, first-encounter guided
   asides inside `/onboard` (that stays #913's — a different firing
   algorithm gated on a separate seen-set marker, § D3) and the ambient
   any-session single-term lookup (that's `.claude/rules/glossary-lookup.md`,
   also #915 — a rule, not this skill, so it fires even when `/tutorial`
   isn't running). This skill's contract is still "solicited, whole-asset,
   side-effect-free render" — it never gates content the way the asides do.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
