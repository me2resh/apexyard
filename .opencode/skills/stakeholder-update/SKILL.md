---
name: stakeholder-update
description: Generate a stakeholder update (weekly, monthly, or launch) tailored to audience. Synthesises recent PRs, closed issues, AgDRs, and the roadmap into a narrative.
argument-hint: "weekly | monthly | launch"
allowed-tools: Bash, Read, Grep, Glob
---

# /stakeholder-update — Stakeholder Update Generator

Synthesises recent activity into a stakeholder-facing update. The skill is audience-aware: weekly is dense and tactical for the team, monthly is strategic for leadership, launch is celebratory and metrics-heavy for the broader org or external stakeholders.

## Usage

```
/stakeholder-update weekly
/stakeholder-update monthly
/stakeholder-update launch
/stakeholder-update weekly --project example-app
```

## Scope

Aggregated across every project in `apexyard.projects.yaml` (the registry at the root of your ops repo), unless `--project <name>` is passed to scope to one.

## Inputs

The skill pulls from:

| Source | What it gives |
|--------|---------------|
| `gh pr list --state merged --search "merged:>=<since>"` | What shipped |
| `gh issue list --state closed --search "closed:>=<since>"` | What got resolved |
| `git log --since=<since> --oneline` | Commit volume / themes |
| `docs/agdr/AgDR-*.md` (in this period, inside each project) | Decisions made |
| `projects/<name>/roadmap.md` | Strategic direction |
| `gh pr list --state open` | What's in flight |
| `projects/ideas-backlog.md` | Ideas captured |

`<since>` is computed from the update type:

| Type | Window |
|------|--------|
| weekly | 7 days |
| monthly | 30 days |
| launch | last release tag → today (or 90 days if no tag) |

## Audience tailoring

### Weekly (tactical, for the team)

- Dense
- Bullet-heavy
- Includes PR numbers and issue links
- Highlights blockers and risks
- ~300–500 words
- Tone: "here's what happened, here's what's next, here's what's stuck"

### Monthly (strategic, for leadership)

- Narrative
- Roadmap-anchored
- Includes velocity and quality metrics
- Highlights strategic decisions (AgDRs)
- ~500–800 words
- Tone: "we're tracking against the plan; here's what changed and what it means"

### Launch (celebratory, for external/wider audience)

- Headline-driven
- Outcome-focused (not commit-focused)
- Includes user-visible changes only
- Quotes / screenshots placeholders
- Metrics that matter to non-engineers
- ~400–600 words
- Tone: "here's what's now possible, here's what it means for users"

## Templates

### Weekly

```markdown
# Weekly Update — {project} — Week of {YYYY-MM-DD}

**Author**: @{git user} · **Period**: last 7 days

## Shipped
- {#PR} — {title} ({PR url})
- ...

## In Flight
- {#PR or #Issue} — {title} — {status}
- ...

## Decisions
- AgDR-{NNNN}: {title}
- ...

## Blockers
- {item} — {what's needed to unblock}
- ...

## Next Week
- {top 3 items from "Now" milestone}
- ...

## Metrics
- PRs merged: {N}
- Issues closed: {N}
- Open PRs: {N}
- Avg. PR review time: {…}
```

### Monthly

```markdown
# Monthly Update — {project} — {Month YYYY}

**Author**: @{git user} · **Period**: {start} to {end}

## Highlights
{2–3 sentence narrative summary of the month}

## Roadmap Progress
| Item | Status | Notes |
|------|--------|-------|
| ... | ... | ... |

## Shipped This Month
{Themed list, not commit-by-commit. Group by area.}

### {Area 1}
- {What changed and why it matters}

### {Area 2}
- ...

## Strategic Decisions
{AgDRs from this month, with one-line context for each}

## Quality & Health
- Test coverage: {…}
- CI green rate: {…}
- Open critical issues: {…}
- Open security findings: {…}

## Looking Ahead — Next Month
{Top 3–5 outcomes we're targeting}

## Risks
{1–3 risks worth surfacing to leadership}
```

### Launch

```markdown
# {Project / Feature} — Launch Update

**Date**: {YYYY-MM-DD} · **Owner**: @{git user}

## What launched
{One-paragraph headline. What did users get?}

## Why it matters
{2–3 bullets on user value}

## What's now possible
- {capability 1}
- {capability 2}
- {capability 3}

## By the numbers
- {leading indicator}
- {feature scope: lines / files / endpoints / pages — only if relevant}
- {launch blast radius: % of users, regions, etc.}

## Behind the scenes
{One-paragraph credit reel: who built it, what was hard}

## What's next
{2–3 follow-up items already on the roadmap}

## Try it
{Link / steps to actually use the thing}
```

## Process

1. Parse the update type from `$ARGUMENTS` (default: `weekly`)
2. Compute `<since>` based on type
3. Read the registry; resolve `--project` if passed, otherwise iterate all projects
4. Pull all inputs in parallel
5. Synthesise the update using the matching template
6. Print to stdout, **and** offer to write it to `projects/<name>/updates/{type}-{YYYY-MM-DD}.md`
7. Offer to post to the team's communication channel (Slack/Discord) — only as a follow-up suggestion, never automatic

## Portfolio rollup

Without `--project`, generate one section per project, prefixed with the project name and bounded by separators. Add a portfolio summary at the top:

```
PORTFOLIO ROLLUP — Week of 2026-04-06

3 projects · 12 PRs merged · 18 issues closed · 4 AgDRs

═══════════════════════════════════════
example-app — Weekly
═══════════════════════════════════════
{full weekly update}

═══════════════════════════════════════
billing-api — Weekly
═══════════════════════════════════════
{full weekly update}

═══════════════════════════════════════
marketing-site — Weekly
═══════════════════════════════════════
{full weekly update}
```

## Rules

1. **Audience-aware** — never use weekly format for a launch update
2. **Always include the period** — start and end dates explicit
3. **Never invent metrics** — if a metric can't be computed, omit it
4. **Use real PR/issue numbers** — every claim links to evidence
5. **AgDRs are first-class** — decisions belong in updates, not just code
6. **Don't auto-publish** — write the file, suggest the channel, but never post on the user's behalf
7. **Scope-aware** — one section per project, portfolio rollup when no `--project` flag
8. **Tone matches type** — terse (weekly), narrative (monthly), celebratory (launch)

## Related skills

- `/status` — what's currently in flight
- `/projects` — portfolio table
- `/roadmap` — what's planned
- `/decide` — produces AgDRs that this skill cites
