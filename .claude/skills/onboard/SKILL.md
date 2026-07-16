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
design: `docs/technical-designs/onboarding-increment-1.md`, ticket #910).
`/onboard` is a **thin orchestrator + router**, not a replacement for
`/setup` or `/handover` — it sequences those two skills (plus `/feature`)
behind a capability tour and an explicit branch. It never edits `/setup`,
`/handover`, or `/feature`; their direct and scripted behaviour stays
byte-for-byte unchanged (see AgDR-0097).

Ships **terse mode only** in this increment — the teach-in-context glossary
and terse/guided depth adaptivity are increment 2 (#911 and beyond). This
flow *captures* a technical-level signal (D5) but does not yet branch
rendering on it.

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

Record the captured signal — this is a one-line seam for increment 2, not a
rendering switch yet (increment 1 is terse-only regardless of the signal):

```bash
mkdir -p .claude/session && echo "$SIGNAL" > .claude/session/onboarding-tech-level
```

Where `$SIGNAL` is `engineer`, `non-engineer`, or `ambiguous` (if neither
signal was usable). Never block on this — a wrong guess costs nothing since
increment 1 doesn't act on it, and increment 2's reversibility NFR lets the
adopter override in plain language whenever depth adaptivity ships.

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

Always end with a pointer to the standalone re-entry point (even though
`/tutorial` ships in #911 — name it now so the reference lands with the
first PR that needs it):

```
Come back anytime with /tutorial to replay this tour — it works on any
fork state and never changes anything.
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
4. **Terse mode only, this increment.** Don't add glossary asides or
   depth-adaptive rendering — that's increment 2 (#911+). Capture the
   technical-level signal; don't act on it yet.
5. **The tour content lives in one file.** Never inline or paraphrase
   `docs/onboarding/capability-tour.md` — both `/onboard` and `/tutorial`
   read the same asset verbatim.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
