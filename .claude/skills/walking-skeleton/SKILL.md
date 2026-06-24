---
name: walking-skeleton
description: Scaffold a [Feature]-class ticket for the thinnest end-to-end slice — one trivial path wired through every architectural layer. KEPT and grown; full SDLC (NOT exempt like /spike).
argument-hint: "<feature or service the skeleton proves>"
allowed-tools: Bash, Read, Write
---

# /walking-skeleton — Scaffold the Thin End-to-End Slice

Creates a structured GitHub Issue for a **walking skeleton** — the thinnest possible end-to-end slice of a new feature or service: one trivial happy path wired through **every** architectural layer (UI → API → domain → store → deploy → back), with **no business logic beyond the thinnest happy path**. The skeleton actually runs and deploys, so integration and architecture are proven early. You then build the real product on top of it.

> **The taxonomy — three skills, two axes (throwaway vs kept, technical vs UX).**
>
> | Skill | Question it answers | Lifecycle |
> |-------|---------------------|-----------|
> | `/spike` | "Will this **technically** work?" | **THROWAWAY** — discarded after the answer is in (`/spike-close`). |
> | `/prototype` | "What should this **look and feel** like?" | **THROWAWAY** — discarded after the direction is chosen (`/prototype-close`). |
> | **`/walking-skeleton`** | "Is the **whole architecture** wired and deployable end-to-end?" | **KEPT** — the production spine you flesh out. Full SDLC. |
>
> The walking skeleton is the **opposite** of a spike/prototype: minimal but **production-shaped and kept**. This distinction prevents the common, expensive confusion where a throwaway exploration gets accidentally promoted into production. A walking skeleton is held to the full bar from day one *because* it stays — it is **NOT** exempt from the AgDR + coverage gates the way `/spike` and `/prototype` are. See `workflows/sdlc.md` § Phase 1 and `.claude/rules/workflow-gates.md`.

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
/walking-skeleton checkout — browser to a recorded "order placed" event
/walking-skeleton the new notifications service
/walking-skeleton sign-in flow end to end
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
echo "walking-skeleton" > "$ops_root/.claude/session/active-issue-skill"
```

Remove the marker on **every** exit path (success, early-exit, user cancel, error):

```bash
rm -f "$ops_root/.claude/session/active-issue-skill"
```

The `clear-issue-skill-marker.sh` SessionStart hook sweeps stale markers from killed sessions, but a clean exit should never leave one behind. See AgDR-0030.

### 1. Resolve the target repo

Read `.claude/session/current-ticket` to determine which repo we're working in. If no active ticket, check `apexyard.projects.yaml` for managed projects. If only one project, use it. If multiple, ask:

```
Which project is this walking skeleton for?
```

If no projects are registered, ask for the repo in `owner/repo` format.

### 2. Verify the prefix is on the whitelist

Read `.ticket.prefix_whitelist` from `.claude/project-config.*.json`. A walking skeleton is filed as a **[Feature]**-class ticket — it is kept and goes through the full SDLC. If `Feature` (case-insensitive) is not in the list, warn and stop:

```
This fork's ticket schema doesn't include 'Feature' as a valid prefix.
Either add it to .claude/project-config.json → .ticket.prefix_whitelist, or
file the ticket using whichever prefix the fork uses for delivery work.
```

(The shipped default includes `Feature`. This check exists for forks that have customised the whitelist.)

### 3. Parse or ask for the title

Take the feature/service name from `$ARGUMENTS`. If empty, ask:

```
What feature or service should the walking skeleton prove end to end?
Give me a short name.
```

### 4. Gather details (one question at a time)

Ask conversationally — do NOT batch all questions. Wait for each answer before asking the next. Fields a–d are required; e is optional.

**a) Layers crossed (required)**

```
List every architectural layer the slice must touch, in order. The
skeleton proves integration, so it has to pass through ALL of them, even
if each does the most trivial thing possible. Example for a web app:

  browser/UI → HTTP route → application handler → domain → datastore
  → response → deploy target

What are yours? (If you can't name the layers, the architecture isn't
defined enough for a skeleton yet — push back.)
```

If the user can't enumerate the layers, the skeleton isn't ready — say so and help them name the architecture first.

**b) The thinnest happy path (required)**

```
Describe the ONE trivial end-to-end path the skeleton exercises. It must
be real (actually runs/deploys), but contain no business logic beyond the
thinnest happy path. Examples:
  - "POST /orders with a hardcoded line item returns 201 and writes one
     row; a deployed smoke test reads it back."
  - "Click 'Sign in', the request reaches the auth handler, returns a
     stub token, the UI shows 'signed in'."

What's the single thin path?
```

Reject anything with branching logic, validation rules, or multiple
features — that belongs in the features built ON TOP of the skeleton.

**c) Definition of done — runs AND deploys (required)**

```
How do we prove the skeleton is alive? A walking skeleton is not done
until it actually runs end-to-end AND deploys (or runs in the target
environment). Give the concrete check(s):
  - "Deployed to staging; a smoke test hits the live URL and asserts 201."
  - "CI runs the slice end-to-end; the deploy job is green."

What's the proof-of-life?
```

The "actually deploys / runs in the real environment" bar is the whole
point — a skeleton that only runs on localhost hasn't proven the
architecture. Push for a deploy/run check.

**d) In scope vs out of scope (required)**

```
Draw the line explicitly. IN scope = the wiring (every layer, one thin
path, deploy). OUT of scope = every feature built later on top of the
skeleton (validation, error handling, additional endpoints, business
rules, real auth, edge cases).

Give me 2-3 IN bullets (the wiring) and 2-3 OUT bullets (features for
later). This boundary is what keeps a skeleton from quietly growing into
a half-built feature.
```

This in/out boundary is load-bearing — it is the AC that keeps the
skeleton thin. Don't skip it.

**e) Acceptance criteria (optional — derived if skipped)**

```
Any specific acceptance criteria beyond "every layer is wired, the thin
path runs, and it deploys"? (or press Enter to derive them from the
answers above)
```

If skipped, derive ACs from a–d. Every walking-skeleton ticket MUST carry, at minimum, these three ACs (kept work — full SDLC applies):

- [ ] Every named layer is exercised by the slice (integration proven, not mocked end-to-end)
- [ ] The slice actually runs/deploys in the target environment (proof-of-life check passes)
- [ ] The slice's domain logic has tests with **> 80% coverage** (this is KEPT code — NOT spike-exempt) and passes Rex code review + the security gate

### 5. Show the formatted ticket for confirmation

Resolve the ticket body template via the portfolio helper so adopter overrides win when present:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
template=$(portfolio_resolve_template tickets/feature.md)   # walking skeletons are [Feature]-class
```

A walking skeleton reuses the `[Feature]` body shape (it is a kept feature). Display the full ticket; the User Story names the skeleton, the Acceptance Criteria carry the three mandatory ACs from step 4e, and the Out of Scope section carries the OUT bullets from step 4d:

```
Here's the ticket I'll create:

---
**[Feature] Walking skeleton — {title}**

## User Story
As a team building {title}, I want the thinnest end-to-end slice wired
through every architectural layer ({layers}) so that integration and
architecture are proven early and we build the real product on top of it.

## Acceptance Criteria
- [ ] Every layer is exercised by the slice: {layers}
- [ ] The thin happy path runs end-to-end: {thin path}
- [ ] The slice actually runs/deploys: {proof-of-life}
- [ ] Domain logic of the slice has tests with > 80% coverage (KEPT code,
      not spike-exempt) and passes Rex + the security gate
- [ ] {any extra ACs from step 4e}

## In Scope (the wiring)
- {in bullet 1}
- {in bullet 2}

## Out of Scope (features built later on the skeleton)
- {out bullet 1}
- {out bullet 2}

## Glossary
| Term | Definition |
|------|------------|
| Walking skeleton | Thinnest end-to-end slice exercising the whole architecture; kept and grown into the product (Cockburn). |
---

Labels: enhancement
Repo: {owner/repo}

Suggested branch when you start work:
  feature/<TICKET-ID>-{slug}-skeleton

Create this ticket? (yes / edit / cancel)
```

### 6. Handle response

- **yes** / **looks good** / **go** → create the issue
- **edit** / **change X** → ask what to change, update, re-show
- **cancel** / **no** → abort

### 7. Create the GitHub Issue

```bash
gh issue create --repo {owner/repo} \
  --title "[Feature] Walking skeleton — {title}" \
  --label "enhancement" \
  --body "{formatted body}"
```

Note: a walking skeleton is filed under the normal feature label (`enhancement` by default) — **NOT** under `spike`. The label matters: there is **no** `walking-skeleton` exemption label, because the skeleton is held to the full SDLC. If your fork uses a different feature label, use that.

### 8. Return the URL + branch suggestion

```
Created: {owner/repo}#{number} — Walking skeleton — {title}
{url}

When you start work:
  /start-ticket {owner/repo}#{number}
  git checkout -b feature/GH-{number}-{slug}-skeleton
```

### 9. Remind the operator this is KEPT — full SDLC

```
This is a KEPT walking skeleton, not a throwaway. It goes through the
full SDLC:
  - tests with > 80% coverage on the slice's domain logic
  - Rex code review + security gate
  - all merge gates (NOT exempt like /spike or /prototype)

Build the real features ON TOP of the merged skeleton, one ticket at a
time. If you instead wanted to answer "will it technically work?" or
"what should it look like?", you wanted /spike or /prototype — both
throwaway.
```

## Rules

1. **One question at a time.** Never batch questions. Wait for each answer.
2. **Always confirm before creating.** Show the full ticket and get explicit "yes".
3. **Required fields are mandatory.** Layers crossed, the thinnest happy path, the runs-AND-deploys definition of done, and the in/out scope boundary — none can be skipped.
4. **KEPT, not throwaway.** A walking skeleton is filed as a `[Feature]` and held to the full SDLC. It is explicitly **NOT** exempt from the AgDR or > 80% coverage gates the way `/spike` and `/prototype` are. Do not apply the `spike` label or any exemption label.
5. **No business logic beyond the thinnest happy path.** The skeleton proves wiring, not behaviour. Branching, validation, edge cases, additional features → Out of Scope, built later on top.
6. **Actually runs/deploys.** The definition of done includes a real run/deploy check. A skeleton that only compiles, or only runs on localhost, hasn't proven the architecture.
7. **Branch suggestion.** Always `feature/<TICKET-ID>-<slug>-skeleton`.
8. **Cross-reference the taxonomy.** If the user really wanted a throwaway technical answer, redirect to `/spike`; if they wanted a throwaway UX/demo direction, redirect to `/prototype`.

## Where this sits in the SDLC

A walking skeleton is **Build-phase work like any feature** — it just happens to be the *first* feature, and its purpose is to prove the architecture rather than deliver user value. It carries no exemptions:

| Gate | Walking-skeleton work |
|------|------------------------|
| Pre-Build (ticket, ACs) | Required — the skeleton ticket carries the wiring ACs |
| AgDR for technical decisions | Required — the skeleton usually MAKES the architecture decisions (it's the first place they're committed); record them with `/decide` |
| Test coverage > 80% | Required — KEPT code; the slice's domain logic is tested |
| Code Reviewer agent (Rex) | Required |
| Security Auditor (auth/crypto/secrets diff) | Required |
| Glossary in PR body | Required |
| QA Engineer verification | Required (AC verification: every layer wired, runs/deploys) |

See `.claude/rules/workflow-gates.md`, `.claude/skills/spike/SKILL.md` (the throwaway technical sibling), and `.claude/skills/prototype/SKILL.md` (the throwaway UX sibling).

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
