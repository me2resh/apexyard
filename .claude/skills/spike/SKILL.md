---
name: spike
description: Create a hypothesis-driven, time-boxed, throw-away spike ticket — covers POC, prototype, experiment, and exploration work. Drops the user-story / acceptance-criteria fields; adds Hypothesis, Budget, Kill Criteria, and Disposition. Spike PRs are exempt from the AgDR + 80% coverage gates; code review (Rex) and the security auditor still apply.
argument-hint: "<short title of the spike>"
allowed-tools: Bash, Read, Write
---

# /spike — Create a Spike Ticket

Creates a structured GitHub Issue for a **spike** — a 1-3 day hypothesis-driven exploration whose goal is to answer a technical question with minimum investment, with the explicit understanding that the code will be discarded or substantially rewritten once the answer is clear.

> **When to use a spike vs a feature.** If you can answer the question through reasoning alone, file a `/feature`. If you genuinely don't know whether an approach will work — does this library scale, does this UX make sense, will this integration handle our load — file a `/spike` first. The spike's output is the answer; once it's in, file a fresh `[Feature]` ticket with production-shaped delivery (or a memo if the answer was no). See `workflows/sdlc.md` § Phase 1 for the gating heuristic.

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
/spike Will library X handle 10k events/sec
/spike Does Postgres LISTEN/NOTIFY scale to N consumers
/spike Can we replace Auth0 with Cognito
```

## Process

### 1. Resolve the target repo

Read `.claude/session/current-ticket` to determine which repo we're working in. If no active ticket, check `apexyard.projects.yaml` for managed projects. If only one project, use it. If multiple, ask:

```
Which project is this spike for?
```

If no projects are registered, ask for the repo in `owner/repo` format.

### 2. Verify the prefix is on the whitelist

Read `.ticket.prefix_whitelist` from `.claude/project-config.*.json`. If `Spike` (case-insensitive) is not in the list, warn and stop:

```
This fork's ticket schema doesn't include 'Spike' as a valid prefix.
Either add it to .claude/project-config.json → .ticket.prefix_whitelist, or
file the ticket using whichever prefix the fork uses for exploration work.
```

(The shipped default in `.claude/project-config.defaults.json` includes `Spike`. This check exists for forks that have customised the whitelist — see apexyard#109.)

### 3. Parse or ask for the title

Take the title from `$ARGUMENTS`. If empty, ask:

```
What's the spike? Give me a short title.
```

### 4. Gather details (one question at a time)

Ask conversationally — do NOT batch all questions. Wait for each answer before asking the next. The four fields below are all required; the fifth is optional.

**a) Hypothesis (required)**

```
What's the single specific question this spike answers?
Format: "We believe {X}. We will know we're right when {Y}."
(One sentence. If you can't write it that way, the spike isn't ready —
push back and ask the user to refine.)
```

If the user gives a casual hypothesis, restructure it into the required format and confirm.

**b) Budget (required)**

```
What's the hard cap on time/effort? Examples:
  - 2 days of one engineer
  - 1 sprint
  - Until end of week

At the budget cap, the spike ENDS regardless of outcome — that's the
commitment. What's yours?
```

Reject vague answers ("a while", "as long as it takes") — push for an explicit time/effort cap.

**c) Kill Criteria (required)**

```
Under what specific conditions does the spike STOP early?
(Either because the answer is in, or because pursuing further is wasted.)
```

Encourage at least two kill criteria — one "answered: yes" and one "answered: no / unworkable". Don't accept "we'll figure it out".

**d) Disposition (required — PROMOTE or DISCARD)**

```
What happens when the spike closes — PROMOTE or DISCARD?

  PROMOTE — if the hypothesis is confirmed, file a fresh [Feature] ticket
            with production-shaped delivery, port the relevant findings.
  DISCARD — if the hypothesis is rejected (or the answer is "we shouldn't
            do this"), delete the spike branch and file a memo with what
            we learned.

"Decide later" is NOT allowed — that's how spike code rots into half-
shipped production. Pick one.
```

If the user says "decide later" or "depends", explain the rule and ask again. The author must commit to one path in advance.

**e) Approach (optional)**

```
Any sketch of the exploration plan? (or press Enter to skip)
NOT a tech design, NOT a PRD — a few bullets: smallest test, tools needed,
boundary you'd cross to fail-fast.
```

### 5. Show the formatted ticket for confirmation

Resolve the spike body template via the portfolio helper so adopter overrides win when present:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
template=$(portfolio_resolve_template spike.md)   # → custom-templates/spike.md if present, else templates/spike.md
```

Single-fork adopters (no `portfolio` block) and adopters with no override fall straight through to `templates/spike.md`. Adopters who want a customised spike-body shape drop their version at `<private_repo>/custom-templates/spike.md`. See `templates/README.md` for the path-mirroring convention.

Display the full ticket using the resolved template's section headings (the default `templates/spike.md` shape is reproduced below):

```
Here's the ticket I'll create:

---
**[Spike] {title}**

## Hypothesis
{hypothesis}

## Budget
{budget}

## Kill Criteria
- {criterion 1}
- {criterion 2}
- ...

## Disposition
{PROMOTE | DISCARD}
{one-sentence rationale}

## Approach
{approach or "—"}
---

Labels: spike
Repo: {owner/repo}

Suggested branch when you start work:
  spike/<TICKET-ID>-{slug}

Create this ticket? (yes / edit / cancel)
```

### 6. Handle response

- **yes** / **looks good** / **go** → create the issue
- **edit** / **change X** → ask what to change, update, re-show
- **cancel** / **no** → abort

### 7. Create the GitHub Issue

```bash
gh issue create --repo {owner/repo} \
  --title "[Spike] {title}" \
  --label "spike" \
  --body "{formatted body}"
```

The `spike` label is the trigger that downstream hooks (AgDR-required hooks, coverage gates) read to apply the workflow exemptions. If the label doesn't exist on the target repo, the skill will create it via `gh label create spike --color "FBCA04" --description "Throw-away exploration; exempt from AgDR + coverage gates"` (idempotent — `gh label create` errors on duplicate, the skill swallows that).

### 8. Return the URL + branch suggestion

```
Created: {owner/repo}#{number} — {title}
{url}

When you start work:
  /start-ticket {owner/repo}#{number}
  git checkout -b spike/GH-{number}-{slug}
```

### 9. Remind the operator about the disposition gate

```
When the spike closes, run /spike-close to record the disposition:
  /spike-close --promote   # hypothesis confirmed → file a [Feature]
  /spike-close --discard   # hypothesis rejected → write a memo

Closing the spike without running this gate is allowed (closure is the
operator's call) but skips the memo / promotion artefact and leaves no
record of what was learned.
```

## Rules

1. **One question at a time.** Never batch questions. Wait for each answer.
2. **Always confirm before creating.** Show the full ticket and get explicit "yes".
3. **All four required fields are mandatory.** Hypothesis, Budget, Kill Criteria, Disposition — none can be skipped or deferred.
4. **Disposition is PROMOTE or DISCARD only.** "Decide later" is not allowed; reject it and re-ask.
5. **Labels.** `spike` always. Priority labels (P0/P1/etc.) are NOT applied — spikes are time-boxed by Budget, not prioritised by P-class. The accepted prefix list reads from `.claude/project-config.*.json` → `.ticket.prefix_whitelist`; `[Spike]` must be in that list.
6. **Branch suggestion.** Always `spike/<TICKET-ID>-<slug>`. The branch name is what AgDR-exemption hooks check (alongside the active-ticket marker).
7. **No PRD, no tech design.** Spikes describe a hypothesis, not a feature. Don't ask for user stories, ACs, or design notes — those belong on the follow-up `[Feature]` ticket if the disposition is PROMOTE.

## Workflow exemptions for spike work

A spike PR is exempt from the production SDLC subset listed below; everything else still applies. The exemptions are mechanical (hooks detect `[Spike]` prefix or `spike` label and skip), not advisory.

| Gate | Production work | Spike work |
|------|----------------|------------|
| Pre-Build (parent epic, story tickets, ACs, design review) | Required | Skipped — the spike ticket IS the unit |
| AgDR for technical decisions (`require-agdr-for-arch-pr.sh`, `require-agdr-for-arch-changes.sh`) | Required | Skipped — ship a memo on `/spike-close --discard` instead |
| Test coverage > 80% | Required | Skipped — coverage is irrelevant for throw-away code |
| Code Reviewer agent (Rex) | Required on every PR | Required — even throw-away code gets a sanity check |
| Security Auditor (auth/crypto/secrets diff) | Required | Required — security gates fire regardless of intent |
| Glossary in PR body | Required | Required — spike PRs explain WHAT WAS LEARNED, which is the artefact |
| QA Engineer verification | Required (AC verification) | Required (Hypothesis verification: did we answer the question?) |
| Disposition decision before close | N/A | Required — operator must declare PROMOTE or DISCARD via `/spike-close` |

See `.claude/rules/workflow-gates.md` § Spike work for the rule statement, and AgDR-NNNN-spike-skill-schema-and-exemptions.md for the rationale.
