---
name: tutorial
description: "Standalone, side-effect-free re-entry to the capability tour — replays the roles/skills/gates walkthrough any time, on any fork state. No /setup or /handover coupling."
disable-model-invocation: false
argument-hint: ""
effort: low
allowed-tools: Read, Bash
---

# /tutorial — Replay the Capability Tour

This is ticket #911 (M3) of the guided-onboarding walking skeleton (technical
design: `docs/technical-designs/onboarding-increment-1.md`, § D3/D4 and the
"Standalone `/tutorial` Reusability Spec"). `/tutorial` is a **standalone,
read-only re-entry point** to the same capability tour `/onboard` shows on
first run — for the adopter who skipped it, missed it, or just wants to see
it again without faking a fresh fork.

Ships **tour-only** in this increment. The teach-in-context glossary (US-4)
is increment 2 and is **out of scope here**.

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
- Touches the active-ticket marker or any other session state required for
  its own function (it may read `.claude/session/onboarding-tech-level` if
  present, purely to pick a rendering nuance — never required)

Zero side effects. Running `/tutorial` should leave `git status` exactly as
it was before the command ran.

## Process

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
"What's a gate?" sections plus the "How the loop works" closer). No
depth-mode branching this increment — increment 1 is terse-only everywhere,
including here (matches `/onboard`'s D5 scope caveat).

Open with a one-line frame so the adopter knows this is a replay, not a
first-run flow:

```
Replaying the ApexYard capability tour — the same 60-second orientation
/onboard shows on first run. Nothing on your fork changes by running this.
```

Then render the tour content.

### 3. Close

End with a short pointer back to normal work — no branch, no follow-up
questions, no first-win prompt (that's `/onboard`'s job, not this skill's):

```
That's the tour. Run /tutorial again any time — it's always safe, always
free of side effects.
```

## Rules

1. **Never duplicate tour content.** Read `docs/onboarding/capability-tour.md`
   fresh every invocation; never inline, cache, or hand-copy its prose into
   this skill file. If the tour content needs to change, it changes in one
   place and both `/onboard` and `/tutorial` pick it up automatically.
2. **No side effects, ever.** No writes to `onboarding.yaml`, the registry,
   the active-ticket marker, or the bootstrap marker. If a future increment
   needs `/tutorial` to record something, that's a new design decision, not
   an assumption to make here.
3. **Works on any fork state.** Configured, fresh, or pre-dating this
   feature entirely — the read-and-render behaviour must be identical in
   all three. Do not branch on `fresh_fork_state()`.
4. **Tour-only, this increment.** No glossary rendering, no on-demand term
   lookup — increment 2 territory (see the technical design's Non-Goals and
   Open Questions).

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
