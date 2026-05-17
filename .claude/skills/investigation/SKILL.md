---
name: investigation
description: Create a structured investigation ticket + live-doc for sustained root-cause work — incident retrospectives, bug archaeology, regression hunts, performance mysteries, competitive analyses. Distinct from /spike (forward-looking hypothesis with a budget), /bug (immediate-fix), and /debug (live debugging session). Investigations close when every Follow-up action lands, not on PR merge.
argument-hint: "[short-slug-or-incident-id]"
allowed-tools: Bash, Read, Write
---

# /investigation — Create an Investigation Ticket + Live-Doc

Creates a structured GitHub Issue + a sibling live-doc markdown file for an **investigation** — sustained root-cause work whose deliverable is a *written artefact* of what was observed, what we concluded, and what's next. Distinct from `/spike` (forward-looking hypothesis with a budget) and `/bug` (immediate-fix) — see the comparison block at the top of `templates/investigation.md`.

> **When to use an investigation vs a bug vs a spike.** A `/bug` is filed when you already know what's broken and need to coordinate the fix. A `/spike` is filed when you want to test a forward-looking hypothesis ("will this approach work?") inside a time budget. An `/investigation` is filed when the *question itself* is the unknown — "why did this happen?", "what's actually going on with the metric drift?", "how does competitor X handle this?". The investigation produces a written record; the bug fix that may follow is a downstream artefact.

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the ideas backlog via `portfolio_ideas_backlog` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
projects_dir=$(portfolio_projects_dir)
```

Defaults match today's single-fork layout (`./apexyard.projects.yaml`, `./projects`, `./projects/ideas-backlog.md`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir, ideas_backlog}` keys in `.claude/project-config.json`. Don't hardcode literal `apexyard.projects.yaml` or `projects/` paths in bash blocks — the helper resolves whichever mode the adopter is in. See `docs/multi-project.md`.

## Usage

```
/investigation                              # asks for the trigger interactively, derives slug
/investigation order-api-spike-may-12       # pre-fills the slug; asks for the trigger detail
/investigation PD-4471                      # incident ID as slug
```

## Process

### 0. Write the active-issue-skill marker (REQUIRED — me2resh/apexyard#268)

Before any `gh issue create` (or other tracker CLI), write this skill's name to the active-issue-skill marker so `require-skill-for-issue-create.sh` lets the command through. At skill entry:

```bash
ops_root="$(r=$PWD;while [ ! -f \"$r/onboarding.yaml\" ] && [ \"$r\" != / ];do r=${r%/*};done;echo $r)"
mkdir -p "$ops_root/.claude/session"
echo "investigation" > "$ops_root/.claude/session/active-issue-skill"
```

Remove the marker on **every** exit path (success, early-exit, user cancel, error):

```bash
rm -f "$ops_root/.claude/session/active-issue-skill"
```

The `clear-issue-skill-marker.sh` SessionStart hook sweeps stale markers from killed sessions, but a clean exit should never leave one behind. See AgDR-0030.

### 1. Resolve the target project

Read `.claude/session/current-ticket` to determine the active project context. Then:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
projects_dir=$(portfolio_projects_dir)
```

- If the active ticket is on a managed project's repo → use that project's name + repo.
- Else if exactly one project is registered → use it.
- Else if multiple projects are registered → ask:

  ```
  Which project is this investigation for?
  (Or 'framework' if it's about the apexyard framework itself.)
  ```

- If no projects are registered, ask for the repo in `owner/repo` format. The live-doc lands at `docs/investigations/<YYYY-MM-DD>-<slug>.md` in the ops fork root (the framework's own investigations live there).

### 2. Verify the prefix is on the whitelist

Read `.ticket.prefix_whitelist` from `.claude/project-config.*.json`. If `Investigation` (case-insensitive) is not in the list, warn and stop:

```
This fork's ticket schema doesn't include 'Investigation' as a valid prefix.
Either add it to .claude/project-config.json → .ticket.prefix_whitelist, or
file the ticket using whichever prefix the fork uses for root-cause work.
```

(The shipped default in `.claude/project-config.defaults.json` includes `Investigation`. This check exists for forks that have customised the whitelist — see apexyard#109.)

### 3. Parse or ask for the slug

Take the slug from `$ARGUMENTS` (kebab-cased). If empty, ask:

```
What's a short slug for this investigation? (3-5 words, kebab-case)
Example: "order-api-spike-may-12" or "PD-4471".
```

The slug becomes part of the live-doc filename: `<YYYY-MM-DD>-<slug>.md`. Today's date prefixes automatically (so the same slug can be reused for a follow-up investigation next month without colliding).

### 4. Gather details (one section at a time)

Ask conversationally — do NOT batch all questions. Wait for each answer before asking the next. Mirror the section structure of `templates/investigation.md` so the user sees their answers slot into the artefact directly.

**a) Trigger (required)**

```
What kicked this off? One paragraph.
Examples:
  - "Production incident PD-4471 at 14:03 UTC on 2026-05-12 — error rate
    on /api/orders spiked from 0.2% to 11% for 22 minutes."
  - "Customer report from #cs-tickets-3471 — exports >100k rows always fail."
  - "Reviewing why we picked Auth0 in 2024 vs Cognito today."

Include the link / incident ID / date if you have it.
```

**b) Hypothesis being tested (required)**

```
What did you think was happening BEFORE starting? List 2–4 hypotheses
you wanted to confirm or rule out. I'll format them as a checkbox tree.

Example:
  - Upstream dependency degradation
  - Internal queue backup
  - Recent deploy regressed something
```

Push back if the user offers only one hypothesis — investigations exist precisely because the answer isn't obvious; entertaining multiple causes upfront is the methodology. If the user genuinely has one hypothesis only, that's usually a sign they should file a `/bug` instead. Surface that gently:

```
Only one hypothesis? An investigation usually entertains 2–4 — that's
what distinguishes it from a /bug (where you already know what's broken).
Are you sure /bug isn't the right call here? If yes to investigation,
I'll proceed with the one hypothesis.
```

**c) Evidence sources you'll consult (required)**

```
Where will you gather evidence? List the sources.
Examples:
  - CloudWatch logs for /api/orders, 14:00–14:30 UTC
  - Payments provider status page
  - order_events table (SQL)
  - Last 4 deploys to OrderService
  - Staging replay of failed payloads

These become the "Method" section — the path a reader follows.
```

**d) Initial method sketch (optional)**

```
Any specific queries / commands / steps you've already planned?
(or press Enter to fill in as you go)
```

If the user provides specifics, they go into the Method section. If they skip, the Method section starts empty in the live-doc and the investigator fills it in as evidence comes in.

### 5. Show the formatted ticket + live-doc plan for confirmation

Resolve the investigation template via the portfolio helper so adopter overrides win when present:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
template=$(portfolio_resolve_template investigation.md)   # → custom-templates/investigation.md if present, else templates/investigation.md
```

Single-fork adopters (no `portfolio` block) and adopters with no override fall straight through to `templates/investigation.md`. Adopters who want a customised investigation shape (e.g. Five Whys instead of Hypothesis Tree) drop their version at `<private_repo>/custom-templates/investigation.md`. See `templates/README.md` for the path-mirroring convention.

Read the resolved template and substitute the gathered inputs into the four sections that have inputs (Trigger, Hypothesis being tested, Method sketch, plus the placeholder Findings / Conclusion / Follow-up actions sections to fill in as the investigation progresses).

Display the full ticket + the live-doc path:

```
Here's what I'll create:

GitHub Issue:
  Title:  [Investigation] {slug}
  Labels: investigation
  Repo:   {owner/repo}
  Body:   (template-rendered — Trigger + Hypothesis + Method sketch
           pre-filled; Findings / Conclusion / Follow-up actions empty
           for now)

Live-doc:
  Path:   {projects_dir}/{project}/investigations/{YYYY-MM-DD}-{slug}.md
          (or docs/investigations/{YYYY-MM-DD}-{slug}.md for framework
           investigations)

The live-doc IS the working surface — update it as evidence comes in.
The GitHub issue tracks visibility + close state (closes when every
Follow-up action lands or is explicitly dropped).

Create both? (yes / edit / cancel)
```

### 6. Handle response

- **yes** / **looks good** / **go** → create the issue + write the live-doc
- **edit X** / **change Y** → ask what to change, update, re-show
- **cancel** / **no** → abort

### 7. Write the live-doc

Compute the date prefix (UTC `YYYY-MM-DD`) and the target path:

```bash
date_prefix=$(date -u +%Y-%m-%d)
if [ "$project" = "framework" ]; then
  livedoc_dir="$(git rev-parse --show-toplevel)/docs/investigations"
else
  livedoc_dir="$projects_dir/$project/investigations"
fi
mkdir -p "$livedoc_dir"
livedoc_path="$livedoc_dir/${date_prefix}-${slug}.md"
```

Substitute the gathered values into the resolved template and write the file via the `Write` tool. The Metadata block at the bottom of the file references the GitHub issue number — leave it as `#{NNN}` until step 8, then patch it.

### 8. Create the GitHub Issue

```bash
gh issue create --repo {owner/repo} \
  --title "[Investigation] {slug}" \
  --label "investigation" \
  --body "{rendered template body, with the Metadata block pointing at the live-doc path}"
```

Capture the issue number from the URL `gh` returns; patch the live-doc's Metadata block to replace `#{NNN}` with the real number.

If the `investigation` label doesn't exist on the target repo, create it idempotently:

```bash
gh label create investigation \
  --color "5319E7" \
  --description "Sustained root-cause work — closes when Follow-up actions land, not on PR merge" \
  --repo {owner/repo} 2>/dev/null || true
```

### 9. Return paths + next steps

```
Created: {owner/repo}#{number} — [Investigation] {slug}
{url}

Live-doc: {livedoc_path}

Next steps:
  1. Open the live-doc and update Findings as evidence comes in.
  2. Each hypothesis in the tree gets evidence-for / evidence-against
     bullets underneath — prune as you rule things out.
  3. When you reach a conclusion, fill in the Conclusion section.
  4. List Follow-up actions, each linked to a tracker ticket
     (`/bug`, `/feature`, `/spike`, `/decide`) or marked `(no follow-up)`.
  5. Close the GitHub issue when every Follow-up action is resolved
     — NOT on PR merge.

Suggested follow-up skills depending on what the investigation surfaces:
  /bug    — file an immediate-fix bug
  /spike  — file a hypothesis-driven exploration
  /decide — record a technical decision that fell out
  /feature — propose a new feature the investigation revealed a need for
```

## Rules

1. **One section at a time.** Never batch questions. Wait for each answer before asking the next.
2. **Always confirm before creating.** Show the full plan (issue + live-doc path) and get explicit "yes".
3. **At least 2 hypotheses by default.** If only one, gently surface that `/bug` might be the right tool. Allow the user to override.
4. **Trigger + Hypothesis + Evidence sources are mandatory.** Method sketch is optional (fills in as you go).
5. **Live-doc is the working surface.** The GitHub issue tracks visibility + close state; the live-doc holds the evolving evidence + findings.
6. **Close semantics are different from every other ticket type.** Investigations close when every Follow-up action is resolved or explicitly dropped — NOT on PR merge. The `investigation` label is the signal that downstream automation (if any) should treat the ticket as long-running.
7. **Labels.** `investigation` always. Priority labels (P0 / P1 / etc.) are NOT applied by default — investigations are scoped by *the question*, not prioritised by P-class. If the investigation is incident-driven and the operator wants a P-label, they can add one manually.
8. **No close gate (no `/investigation-close` skill).** The Follow-up actions section IS the close gate. Operators close the issue when actions land. Different from `/spike-close` because investigations have an open-ended action list, not a binary disposition. See AgDR-0027 for the rationale.
9. **Template override.** Adopters who prefer Five Whys / Fishbone over the default Hypothesis Tree drop a replacement at `<private_repo>/custom-templates/investigation.md`. The skill resolves via `portfolio_resolve_template` — no skill changes needed.

## How investigations relate to other skills

| Skill | Purpose | When to chain into `/investigation` |
|-------|---------|-------------------------------------|
| `/bug` | Immediate-fix scenario, known broken behaviour | Rare — investigations usually file bugs as follow-up actions, not the other way around |
| `/spike` | Forward-looking hypothesis with a budget | An investigation may conclude "we need a spike to test the fix approach" — file via `/spike` as a follow-up action |
| `/debug` | Live debugging session (process helper) | A `/debug` session that surfaces a deeper "why did this happen" question naturally promotes to `/investigation` for the written artefact |
| `/decide` | Record a technical decision (AgDR) | An investigation often concludes with a decision — record it via `/decide` as a follow-up action; cite the investigation from the AgDR |
| `/feature` | Propose a new user-facing feature | An investigation that reveals a missing capability files a `/feature` as a follow-up action |
| `/migration` | Migration ticket + AgDR | If the investigation's remediation is a migration, file via `/migration` (which itself produces a ticket + AgDR pair) |

The bidirectional summary: investigations are usually **upstream** of other ticket types (they reveal what needs to happen); they're rarely downstream of them.
