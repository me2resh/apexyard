---
name: prototype
description: Create a throwaway UX/demo prototype ticket (mockup / demo flow) — answers "what should it look and feel like?". DISCARD-by-default; same AgDR + coverage exemptions as /spike.
argument-hint: "<short title of the prototype>"
allowed-tools: Bash, Read, Write
---

# /prototype — Create a Throwaway Prototype Ticket

Creates a structured GitHub Issue for a **prototype** — a disposable UX/demo artifact (clickable mockup, demo flow, interactive proof-of-concept UI) built to answer *"what should this look and feel like?"*. The output is the **learning / chosen direction**, not shippable code: a prototype is thrown away once the direction is decided.

> **The taxonomy — three skills, two axes (throwaway vs kept, technical vs UX).**
>
> | Skill | Question it answers | Lifecycle |
> |-------|---------------------|-----------|
> | `/spike` | "Will this **technically** work?" | **THROWAWAY** — discarded after the technical answer is in (`/spike-close`). |
> | **`/prototype`** | "What should this **look and feel** like?" | **THROWAWAY** — discarded after the UX/demo direction is chosen (`/prototype-close`). |
> | `/walking-skeleton` | "Is the **whole architecture** wired end-to-end?" | **KEPT** — the production spine you flesh out. Full SDLC. |
>
> `/prototype` and `/spike` are **both throwaway** — the difference is the *question*. A spike answers a **technical feasibility** question ("will library X scale?", "can we replace Auth0?"). A prototype answers a **UX/demo direction** question ("which onboarding flow feels right?", "what should the dashboard look like for the investor demo?"). If your question is "will it work?", file a `/spike` instead. If you need a minimal-but-**kept** end-to-end slice, you want `/walking-skeleton`. See `workflows/sdlc.md` § Phase 1.

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the ideas backlog via `portfolio_ideas_backlog` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
```

Defaults match today's single-fork layout (`./apexyard.projects.yaml`, `./projects`, `./projects/ideas-backlog.md`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir, ideas_backlog}` keys in `.claude/project-config.json`. Don't hardcode literal `apexyard.projects.yaml` or `projects/` paths in bash blocks — the helper resolves whichever mode the adopter is in. See `docs/multi-project.md`.

## Usage

```
/prototype Which onboarding flow feels right
/prototype Dashboard look-and-feel for the investor demo
/prototype Clickable checkout mockup to test the 2-step vs 1-step
```

## Process

### 0. Write the active-issue-skill marker (REQUIRED — me2resh/apexyard#268)

Before any `gh issue create` (or other tracker CLI), write this skill's name to the active-issue-skill marker so `require-skill-for-issue-create.sh` lets the command through. At skill entry:

```bash
# Resolve the ops-fork root the SAME way the hooks do (_lib-ops-root.sh):
# anchor on the .apexyard-fork marker (split-portfolio v2 — onboarding.yaml
# lives in the sibling portfolio repo, NOT the ops fork), falling back to the
# onboarding.yaml + apexyard.projects.yaml pair (single-fork v1).
ops_root="$PWD"; r="$PWD"
while [ "$r" != / ]; do
  if [ -f "$r/.apexyard-fork" ] || { [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ]; }; then
    ops_root="$r"; break
  fi
  r=${r%/*}
done
mkdir -p "$ops_root/.claude/session"
echo "prototype" > "$ops_root/.claude/session/active-issue-skill"
```

Remove the marker on **every** exit path (success, early-exit, user cancel, error):

```bash
rm -f "$ops_root/.claude/session/active-issue-skill"
```

The `clear-issue-skill-marker.sh` SessionStart hook sweeps stale markers from killed sessions, but a clean exit should never leave one behind. See AgDR-0030.

### 1. Resolve the target repo

Read `.claude/session/current-ticket` to determine which repo we're working in. If no active ticket, check `apexyard.projects.yaml` for managed projects. If only one project, use it. If multiple, ask:

```
Which project is this prototype for?
```

If no projects are registered, ask for the repo in `owner/repo` format.

### 2. Verify the prefix is on the whitelist

Read `.ticket.prefix_whitelist` from `.claude/project-config.*.json`. If `Prototype` (case-insensitive) is not in the list, warn and stop:

```
This fork's ticket schema doesn't include 'Prototype' as a valid prefix.
Either add it to .claude/project-config.json → .ticket.prefix_whitelist, or
file the ticket using whichever prefix the fork uses for exploration work.
```

(The shipped default in `.claude/project-config.defaults.json` includes `Prototype`. This check exists for forks that have customised the whitelist.)

### 3. Parse or ask for the title

Take the title from `$ARGUMENTS`. If empty, ask:

```
What's the prototype? Give me a short title.
```

### 4. Gather details (one question at a time)

Ask conversationally — do NOT batch all questions. Wait for each answer before asking the next. Fields a–d are required; e is optional.

**a) Direction Question (required)**

```
What's the single "what should this look and feel like?" question this
prototype answers? Format: "We're exploring {direction}; the prototype
tells us {what we'll decide}."
(One sentence. A prototype answers a UX/demo-direction question, NOT a
technical-feasibility one. If your question is "will this work?", you want
/spike — push back and redirect.)
```

If the user gives a technical-feasibility question ("will X scale?", "can we integrate Y?"), stop and redirect to `/spike` — that's a different tool.

**b) Fidelity (required)**

```
What kind of disposable artifact is this, and how far does it go? Examples:
  - Clickable mockup (Figma / static HTML, no real backend)
  - Demo flow (wired screens, stubbed data, happy-path only)
  - Interactive proof-of-concept UI (real framework, fake everything else)

Whatever you pick, it's a throwaway for learning a direction — not the
start of production code. Which fidelity?
```

**c) Budget (required)**

```
What's the hard cap on time/effort? Examples:
  - 1 day of one engineer
  - 2 days, then we decide
  - Until the stakeholder demo on Friday

At the budget cap, the prototype ENDS regardless of polish. What's yours?
```

Reject vague answers ("a while", "until it's pretty") — push for an explicit time/effort cap.

**d) Disposition (required — PROMOTE or DISCARD)**

```
What happens when the prototype closes — PROMOTE or DISCARD?

  PROMOTE — if the direction is chosen, file a fresh [Feature] ticket for
            production-shaped delivery; the prototype artifact is NOT
            lifted into production, the feature re-implements the direction.
  DISCARD — if the direction is rejected (or "not now"), write a memo at
            docs/prototype-memos/<slug>.md with what we learned.

"Decide later" is NOT allowed — that's how a throwaway mockup gets
accidentally promoted into production. Pick one.
```

If the user says "decide later" or "depends", explain the rule and ask again. The author must commit to one path in advance. DISCARD-by-default is the prototype norm — a prototype exists to be thrown away once the direction is clear; PROMOTE just means the *direction*, not the artifact, survives.

**e) Approach (optional)**

```
Any sketch of what you'll mock up? (or press Enter to skip)
NOT a tech design, NOT a PRD — a few bullets: which screens / flows, what
tools (Figma, static HTML, v0, the real framework with stubs), what you're
deliberately faking.
```

### 5. Show the formatted ticket for confirmation

Resolve the prototype body template via the portfolio helper so adopter overrides win when present:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
template=$(portfolio_resolve_template tickets/prototype.md)   # → custom-templates/tickets/prototype.md if present, else templates/tickets/prototype.md
```

Single-fork adopters (no `portfolio` block) and adopters with no override fall straight through to `templates/tickets/prototype.md`. Adopters who want a customised prototype-body shape drop their version at `<private_repo>/custom-templates/tickets/prototype.md`. See `templates/README.md` for the path-mirroring convention.

**Backward-compat fallback**: if `portfolio_resolve_template` returns empty (template file missing — partial adopter setup), fall back to the inline heredoc body below and print a one-line WARN on stderr (`WARN: tickets/prototype.md template missing — using inline fallback`).

Display the full ticket using the resolved template's section headings (the default `templates/tickets/prototype.md` shape is reproduced below):

```
Here's the ticket I'll create:

---
**[Prototype] {title}**

## Direction Question
{direction question}

## Fidelity
{fidelity}

## Budget
{budget}

## Disposition
{PROMOTE | DISCARD}
{one-sentence rationale}

## Approach
{approach or "—"}
---

Labels: prototype
Repo: {owner/repo}

Suggested branch when you start work:
  prototype/<TICKET-ID>-{slug}

Create this ticket? (yes / edit / cancel)
```

### 6. Handle response

- **yes** / **looks good** / **go** → create the issue
- **edit** / **change X** → ask what to change, update, re-show
- **cancel** / **no** → abort

### 7. Create the GitHub Issue

```bash
gh issue create --repo {owner/repo} \
  --title "[Prototype] {title}" \
  --label "prototype" \
  --body "{formatted body}"
```

The `prototype` label is the trigger that downstream hooks (AgDR-required hooks, coverage gates) read to apply the workflow exemptions — the same mechanism `/spike` uses with the `spike` label. If the label doesn't exist on the target repo, the skill will create it via `gh label create prototype --color "C5DEF5" --description "Throw-away UX/demo prototype; exempt from AgDR + coverage gates"` (idempotent — `gh label create` errors on duplicate, the skill swallows that).

### 8. Return the URL + branch suggestion

```
Created: {owner/repo}#{number} — {title}
{url}

When you start work:
  /start-ticket {owner/repo}#{number}
  git checkout -b prototype/GH-{number}-{slug}
```

### 9. Remind the operator about the disposition gate

```
When the prototype closes, run /prototype-close to record the disposition:
  /prototype-close --promote   # direction chosen → file a [Feature]
  /prototype-close --discard   # direction rejected → write a memo

Closing the prototype without running this gate is allowed (closure is the
operator's call) but skips the memo / promotion artefact and leaves no
record of what was learned.
```

## Rules

1. **One question at a time.** Never batch questions. Wait for each answer.
2. **Always confirm before creating.** Show the full ticket and get explicit "yes".
3. **All four required fields are mandatory.** Direction Question, Fidelity, Budget, Disposition — none can be skipped or deferred.
4. **Disposition is PROMOTE or DISCARD only.** "Decide later" is not allowed; reject it and re-ask. DISCARD-by-default is the norm.
5. **UX/demo question, not a technical one.** If the user's real question is feasibility ("will it work?"), redirect to `/spike`. If they want a kept end-to-end slice, redirect to `/walking-skeleton`.
6. **Labels.** `prototype` always — it's the exemption trigger. Priority labels (P0/P1/etc.) are NOT applied — prototypes are time-boxed by Budget. The accepted prefix list reads from `.claude/project-config.*.json` → `.ticket.prefix_whitelist`; `[Prototype]` must be in that list.
7. **Branch suggestion.** Always `prototype/<TICKET-ID>-<slug>`. The branch name is what AgDR-exemption hooks check (alongside the `[Prototype]` active-ticket marker and the `prototype(...)` PR type).
8. **No PRD, no tech design.** Prototypes describe a direction to explore, not a feature. Don't ask for user stories, ACs, or design specs — those belong on the follow-up `[Feature]` ticket if the disposition is PROMOTE.

## Workflow exemptions for prototype work

A prototype PR is exempt from the production SDLC subset listed below — the **same surgical exemptions as `/spike`**; everything else still applies. The exemptions are mechanical (the AgDR hooks detect the `[Prototype]` prefix, the `prototype(...)` PR type, or the `prototype/` branch and skip), not advisory.

| Gate | Production work | Prototype work |
|------|----------------|----------------|
| Pre-Build (parent epic, story tickets, ACs, design review) | Required | Skipped — the prototype ticket IS the unit |
| AgDR for technical decisions (`require-agdr-for-arch-pr.sh`, `require-agdr-for-arch-changes.sh`) | Required | Skipped — ship a memo on `/prototype-close --discard` instead |
| Test coverage > 80% | Required | Skipped — coverage is irrelevant for throw-away mockups |
| Code Reviewer agent (Rex) | Required on every PR | **Required** — even throw-away code gets a sanity check |
| Security Auditor (auth/crypto/secrets diff) | Required | **Required** — security gates fire regardless of intent |
| Glossary in PR body | Required | **Required** — prototype PRs explain WHAT DIRECTION WAS LEARNED, which is the artefact |
| QA Engineer verification | Required (AC verification) | **Required** (Direction verification: did we learn what to build?) |
| Disposition decision before close | N/A | **Required** — operator must declare PROMOTE or DISCARD via `/prototype-close` |

See `.claude/rules/workflow-gates.md` § Spike work for the rule statement (which covers prototype work under the same exemption set), `.claude/skills/spike/SKILL.md` (the throwaway technical sibling), and `.claude/skills/walking-skeleton/SKILL.md` (the kept end-to-end slice).

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
