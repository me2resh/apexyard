---
name: onboard
description: "Guided first-run onboarding — capability tour, handover-vs-new-project branch, and a guided first win via a real filed ticket. The front door for a brand-new ApexYard fork."
disable-model-invocation: false
argument-hint: ""
effort: medium
allowed-tools: Bash, Read, Write, Skill
---

# /onboard — Guided First-Run Onboarding

This is increment 1 of the guided-onboarding walking skeleton (technical
design: `docs/technical-designs/onboarding-increment-1.md`, ticket #910),
now layered with increment 2's **depth adaptivity** (technical design:
`docs/technical-designs/onboarding-increment-2.md` § D2/D7, ticket #914).
`/onboard` is a **thin orchestrator + router**, not a replacement for
`/setup` or `/handover` — it sequences those two skills (plus `/feature`)
behind a capability tour and an explicit branch. It never edits `/setup`,
`/handover`, or `/feature`; their direct and scripted behaviour stays
byte-for-byte unchanged (see AgDR-0097).

**This flow now renders in one of two depth modes — `terse` or `guided`
— off a single shared session marker, not a forked skill** (US-5/FR-6).
Terse renders every step exactly as increment 1 did (byte-for-byte
identical output — NFR Backward-compat). Guided adds one short
"why this matters" framing sentence after each major step. Depth mode
changes **only** explanatory narration — it never changes which gate
fires, which approval is required, or any role boundary (the
"presentation only" invariant, mechanically guarded by
`.claude/hooks/tests/test_depth_mode.sh`'s invariant case). See Step 3.5
below for derivation, and "Depth mode override + transparency" for the
mid-session override (FR-6) and the "what mode am I in?" affordance
(FR-9).

**The per-term teach-in-context glossary + just-in-time asides (#913) are
now wired into this flow.** In guided mode, the first time this skill
uses one of the five core terms — issue/ticket, PR, merge, branch, CI —
toward the adopter, it weaves in a short inline parenthetical explaining
it, once per term per session (design § D3). See "Just-in-time glossary
asides" below for the mechanism. Terse mode sees zero asides — this is
structural, not a formatting choice (the same `$mode` gate Step 3.5
derives). The **ambient any-session lookup + full `/tutorial` glossary
render** (#915) is still a sibling ticket, not yet built as of this
ticket — asking "what's a merge?" outside a guided `/onboard` run isn't
wired up yet.

## Path resolution

Read the registry path via `portfolio_registry` and the onboarding config
path via `portfolio_onboarding_path` — both from
`.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any
bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
```

## Process

### 0. Mark this session as bootstrap (REQUIRED)

`/onboard` runs before any portfolio is configured, so no project tickets
can exist yet. Write the bootstrap marker so `require-active-ticket.sh`
exempts this skill's writes (it's on the `ticket.bootstrap_skills` list in
`.claude/project-config.defaults.json`):

```bash
mkdir -p .claude/session && echo "onboard" > .claude/session/active-bootstrap
```

Clear this marker on **every** exit path below (success, bail, decline) —
see the final step. `clear-bootstrap-marker.sh` sweeps stale markers from
interrupted sessions as a backstop, same as `/setup`.

### 1. Detect fresh-fork state

Source the shared detector (single source of truth — AgDR-0098; the same
function `onboarding-check.sh` uses):

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-fresh-fork.sh"
state=$(fresh_fork_state)   # fresh | configured | not-a-fork
```

Branch on `$state`:

- **`not-a-fork`** — this isn't an ApexYard fork (no `onboarding.yaml`, no
  `onboarding.example.yaml`). Say so plainly and stop — there's nothing to
  onboard:

  ```
  This doesn't look like an ApexYard fork (no onboarding.yaml or
  onboarding.example.yaml found). If you meant to set up ApexYard, fork
  me2resh/apexyard first, then run /onboard from the fork.
  ```

  Clear the bootstrap marker and exit.

- **`configured`** — the fork is already set up. Don't force the full
  first-run flow (that would re-run config bootstrap and the guided first
  win on someone who's past that stage). Offer a lightweight re-run
  instead:

  ```
  This fork is already configured. Want to:
    1. Replay the capability tour (roles / skills / gates, 60 seconds)
    2. Re-run /setup to update your config
    3. Nothing — exit

  (1/2/3)
  ```

  - **1** → render the tour (Step 2 below), then exit.
  - **2** → invoke the `Skill` tool with `skill: setup` and hand off entirely.
  - **3** → exit.

  Clear the bootstrap marker on every branch above.

- **`fresh`** — proceed to Step 2, the full guided flow.

### 2. Capability tour

Read `docs/onboarding/capability-tour.md` and render it verbatim (it's
already terse and scannable — don't summarize or re-word it). Tell the
adopter up front they can skip:

```
Before we configure anything, a 60-second tour of the three ideas that make
ApexYard different — say "skip" any time to jump straight to setup.
```

Then render the file's content. If the adopter says "skip" at any point
(before or during), stop rendering and move to Step 3 immediately.

This is the **same** content `/tutorial` (#911) will render later — never
paraphrase or fork the prose here; both skills read the one shared file.

### 3. Phase 2 — config bootstrap via `/setup`

Invoke the `Skill` tool with `skill: setup` to run the full config bootstrap
(company info, tech stack, defaults). This is `/setup`'s Steps 2–7,
unmodified — `/onboard` does not re-implement any of it.

**Capture the technical-level signal (D5).** While `/setup`'s Step 2 asks
"tell me about your company and tech stack," read that answer for how
technically fluent it reads (mentions of specific languages/frameworks/CI
tools vs. a vague or absent description). Infer silently:

- Fluent, specific stack description → `engineer`
- Vague, absent, or genuinely ambiguous → ask one direct fallback question:

  ```
  Quick one — have you used git/GitHub before, or is this new to you?
  ```

  Answer maps to `engineer` (used before) or `non-engineer` (new to it).

Record the captured signal — increment 2 (#914) now acts on this
immediately, in the very next step:

```bash
mkdir -p .claude/session && echo "$SIGNAL" > .claude/session/onboarding-tech-level
```

Where `$SIGNAL` is `engineer`, `non-engineer`, or `ambiguous` (if neither
signal was usable). Never block on this — a wrong guess costs little,
since the adopter can override the derived depth mode in plain language
at any point (NFR Reversibility — see "Depth mode override + transparency"
below).

### 3.5 Depth mode derivation (#914 — design § D2)

Immediately after writing the tech-level signal above, derive the
session's effective **depth mode** — the setting that actually controls
rendering verbosity for the rest of THIS flow, and for any later
`/tutorial` run this session (D2's signal-vs-mode split: the tech-level
signal is the *inference input*; depth mode is the *effective setting*
the adopter can flip).

Source the shared helper and derive from the signal just captured:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-onboarding-depth-mode.sh"
mode=$(depth_mode_derive_from_signal "$SIGNAL") || mode=""
```

- `$SIGNAL` is `engineer` → `$mode` is `terse`.
- `$SIGNAL` is `non-engineer` → `$mode` is `guided`.
- `$SIGNAL` is `ambiguous` (the derive call fails, `$mode` is empty) —
  this shouldn't normally happen here since Step 3's fallback question
  already resolved `engineer`/`non-engineer`, but handle it defensively:
  ask the SAME one-line fallback question from Step 3 if you haven't
  already, map the answer (`engineer`→`terse`, `non-engineer`→`guided`),
  and set `$mode` directly. Never leave `$mode` empty.

Write it:

```bash
depth_mode_write "$mode"
```

From this point on, render the rest of `/onboard` **in `$mode`**:

- **`terse`** — render every remaining step exactly as increment 1 did.
  No framing sentences, no "why this matters" narration. Output is
  byte-for-byte identical to increment 1 (NFR Backward-compat).
- **`guided`** — after each major step (capability tour, the `/setup`
  handoff, the handover/new-project branch, the guided first win), add
  ONE short plain-language "why this matters" sentence before moving on.
  Keep it to a single sentence — this is generic narration, not a
  per-term glossary aside (that's #913's job once it lands; this flow
  already gates on the same `$mode` marker, so no rework is needed here).

Depth mode is overridable for the rest of this session from any later
step — see "Depth mode override + transparency" immediately below.

### Depth mode override + transparency (design § D2, FR-6/FR-9)

At any point after Step 3.5 (including during Steps 4–6), before writing
your own response, check the adopter's last message for two things:

**1. An override phrase.** Classify it with the shared helper:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-onboarding-depth-mode.sh"
new_mode=$(depth_mode_classify_override "$ADOPTER_MESSAGE")
```

If `$new_mode` is `guided` or `terse`, write it immediately and confirm in
one line, then continue the flow at the new depth from your very next
render (NFR Reversibility — no config file touched, effect is instant,
lossless):

```bash
[ -n "$new_mode" ] && depth_mode_write "$new_mode"
```

```
Switching to guided — I'll explain terms as they come up.
```

```
Switching to terse — I'll skip the plain-language explanations.
```

If `$new_mode` is empty, the message wasn't an override — continue
normally.

**2. A transparency question** ("what mode am I in?" or equivalent).
Answer plainly using the helper's canned report — don't hand-write a new
sentence each time:

```bash
depth_mode_report
```

This satisfies FR-9: it reads the marker (default `terse` if absent) and
states the current mode plus how to switch. Answering this question is a
**read** — it never writes anything.

### Just-in-time glossary asides (#913 — design § D3)

From Step 3.5 onward, any time you are about to use one of the five core
terms — **issue/ticket, PR, merge, branch, CI** — toward the adopter for
the first time this session, check whether a short plain-language aside
is due and, if so, weave it into your sentence as a single parenthetical.
This can fire at any later step — most commonly Step 4 (the branch talks
about the repo and may reach for "issue"/"ticket"), Step 5 (the guided
first win names "ticket", "PR", "merge", "branch", "CI" directly in the
"idea → ticket → PR → review → merge" framing), and the closing message.
Don't wait for a dedicated "glossary step" — call this the first time you
reach for the term, wherever that happens to be.

Source the shared helper (it reads the depth-mode marker internally via
`_lib-onboarding-depth-mode.sh`'s `depth_mode_read` — no separate mode
check needed):

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-onboarding-glossary-seen.sh"
aside=$(glossary_maybe_aside "ticket")   # term key: issue|ticket, pr, merge, branch, ci
rc=$?
```

- **`$rc` is `1`, `$aside` empty** — say the term plainly, no aside. This
  is the common path: terse mode (the design's structural "zero asides"),
  the term already glossed once this session, or an unmapped term.
- **`$rc` is `0`** — `$aside` holds that term's plain-language definition,
  already sliced to exclude the glossary's "**Example**:" line (a short
  paragraph, not the whole entry). Compress it into ONE short
  parenthetical, right where you use the term:

  ```
  …I've opened a ticket for this (a ticket is just a tracked to-do item
  we can both refer back to by number).
  ```

  Keep it to a single sentence — this is a per-term gloss, not the
  generic "why this matters" framing Step 3.5 already adds in guided
  mode; the two are complementary, never merge them into one longer
  aside.

Never hand-craft your own explanation for a term instead of calling the
helper — the seen-set (`.claude/session/onboarding-glossary-seen`) is
what guarantees "once per term, per session" is actually true, and it
only updates through `glossary_maybe_aside`/`glossary_seen_add`. Terse
mode's output is byte-for-byte unaffected by this section — the helper's
mode gate is the same one Step 3.5 wrote, so a terse session renders
exactly as it did before #913 landed.

### 4. Phase 3 — handover-vs-new-project branch

Ask directly:

```
Are you handing over an existing repo, or starting a brand-new project?
  1. Handing over an existing repo
  2. Starting something new

(1/2)
```

#### 4a. Handing over (existing repo)

Ask for the repo path or URL if not already clear from context, then invoke
the `Skill` tool with `skill: handover` and pass that repo path/URL as its
argument. Let `/handover`'s full assessment flow run to completion
unmodified — this is exactly what a direct `/handover <repo>` invocation
does. `/handover` registers the project in `apexyard.projects.yaml` itself
(its own Step 7); `/onboard` does not touch the registry on this branch.

#### 4b. Starting new (lightweight registration)

This is intentionally **lighter** than `/handover` — no harnessability
assessment, no codebase read, just enough to register a project so
`/feature` has somewhere real to file. Ask, one at a time:

**i) Project name**

```
What should we call this project? (short, lowercase, kebab-case — this
becomes the folder name under projects/ and workspace/)
```

**ii) Repo status**

```
Does this project already have a GitHub repo?
  1. Yes — give me the owner/repo
  2. Not yet — should I create one now? (gh repo create, I'll confirm first)
  3. No repo yet, and not creating one right now (fully greenfield)

(1/2/3)
```

- **1** → record `repo: {owner/repo}` as given.
- **2** → confirm the exact `gh repo create` invocation (name, visibility)
  before running it; on success record the created `owner/repo`.
- **3** → no `repo` field — record this project as repo-less for now. This
  is the greenfield-no-repo edge case D6 calls out; Step 5 below handles it
  honestly.

**Append to the registry** (mirrors `/handover`'s own Step 7 — same
mechanism, minimal entry):

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
REGISTRY=$(portfolio_registry)

if command -v yq >/dev/null 2>&1; then
  yq eval -i '.projects += [{"name": "{name}", "repo": "{owner/repo or omit}", "workspace": "workspace/{name}", "docs": "projects/{name}", "status": "active"}]' "$REGISTRY"
else
  cat >> "$REGISTRY" <<'YAML'
  - name: {name}
    repo: {owner/repo or omit}
    workspace: workspace/{name}
    docs: projects/{name}
    status: active
YAML
fi
```

Validate the same way `/handover` does (`yq eval '.' "$REGISTRY"` or the
`python3 -c 'import yaml; ...'` fallback); on failure, restore the
pre-write backup and tell the adopter to fix the file manually — never
leave the registry broken. Confirm success:

```
✓ Registered {name} in apexyard.projects.yaml
```

### 5. Phase 4 — guided first win via `/feature`

Only proceed here **after** the branch above has resolved (D6) — a real
registered project (or an honest "no repo yet") must exist before offering
to file a ticket; never fabricate a ticket number.

```
Want to try filing your first ticket? It's a real GitHub issue, not a demo
— I'll walk you through it with /feature.

(yes/no)
```

- **Adopter declines** → skip straight to Step 6 (closing).
- **Adopter accepts, and a real repo target exists** (handover path always
  has one; new-project path has one unless the operator chose greenfield
  option 3) → invoke the `Skill` tool with `skill: feature`, letting
  `/feature`'s full flow run (user story, acceptance criteria, confirmation,
  real `gh issue create` via `tracker_create`). When it returns the real
  issue reference, celebrate honestly — **never** fabricate a `#N`:

  ```
  🎉 First ticket filed — {owner/repo}#{N}: {title}
  That's the loop: idea → ticket → PR → review → merge. You just did step one.
  ```

- **Adopter accepts, but no real repo exists yet** (greenfield-no-repo,
  D6's must-handle edge case) — do NOT fabricate a ticket. Defer honestly:

  ```
  Your project doesn't have a repo yet, so there's nowhere real to file a
  ticket into. Once you've got a repo (create one with `gh repo create`,
  or run /onboard again), run /feature any time — no need to redo the tour.
  ```

### 6. Closing

Always end with a pointer to the standalone re-entry point:

```
Come back anytime with /tutorial to replay this tour — it works on any
fork state and never changes anything. Your depth mode carries over.
```

### 7. Clear the bootstrap marker (REQUIRED — every exit path)

```bash
rm -f .claude/session/active-bootstrap
```

Run this on success, on the `not-a-fork` bail, on the `configured`
re-run-offer exits, and on any decline/cancel path. Never leave it set.

## Rules

1. **Never re-implement `/setup`, `/handover`, or `/feature`.** Invoke them
   via the `Skill` tool and let their own flows run. This orchestrator adds
   a tour, a branch, and a first-win prompt around them — nothing more.
2. **Never fabricate a ticket number.** The guided first win only reports a
   real `#N` returned by `/feature`'s `tracker_create` call. If there's no
   real repo target, decline honestly (Step 5).
3. **One question at a time.** Same conversational rule as `/setup`,
   `/handover`, and `/feature`.
4. **Depth mode changes rendering only, never a gate.** Terse vs guided
   controls explanatory narration alongside `/onboard`'s output — it must
   NEVER change which gate fires, which approval is required, or any role
   boundary. If you catch yourself about to skip a real gate/permission
   check because the adopter is in guided mode (or add one because
   they're in terse), that's a bug — stop and render the SAME underlying
   gate, just described at the current mode's verbosity (design §
   "Depth mode is presentation only"; mechanically guarded by
   `.claude/hooks/tests/test_depth_mode.sh`'s invariant case).
5. **The tour content lives in one file.** Never inline or paraphrase
   `docs/onboarding/capability-tour.md` — both `/onboard` and `/tutorial`
   read the same asset verbatim.
6. **Per-term glossary asides (#913) are wired in; the ambient
   any-session lookup + full `/tutorial` glossary render (#915) is still
   a sibling ticket, not part of this flow yet.** In guided mode, gloss a
   term via `glossary_maybe_aside` (see "Just-in-time glossary asides"
   above) the first time you use it toward the adopter — never invent a
   per-term definition by hand, and never fabricate a glossary lookup
   outside a guided `/onboard`/`/tutorial` run ahead of #915 landing.
7. **Only ever write the depth-mode marker via the shared helper**
   (`_lib-onboarding-depth-mode.sh`'s `depth_mode_write`) — never hand-edit
   `.claude/session/onboarding-depth-mode` with a raw `echo`/redirect.
   This keeps derivation, override, and the invariant test all going
   through one code path.
8. **Only ever touch the glossary-seen marker via the shared helper**
   (`_lib-onboarding-glossary-seen.sh`'s `glossary_seen_add` /
   `glossary_maybe_aside`) — never hand-edit
   `.claude/session/onboarding-glossary-seen` with a raw `echo`/redirect.
   This is what keeps "once per term, per session" mechanically true and
   testable (`.claude/hooks/tests/test_glossary_asides.sh`).

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
