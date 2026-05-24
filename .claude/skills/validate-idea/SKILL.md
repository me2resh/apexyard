---
name: validate-idea
description: Lightweight 5-question pre-spec gate between /idea and /write-spec — catches "this isn't worth speccing" in 10 minutes.
argument-hint: "<IDEA-NNN | project-name | free-form description>"
allowed-tools: Bash, Read, Write
---

# /validate-idea — Pre-spec validation gate

A 10-minute, 5-question check before committing the time of `/write-spec`. Most ideas should die before the PRD round; this skill makes that decision explicit. Invokable standalone, and offered as an optional follow-up step inside `/idea` (after capture) and `/handover` (when the project looks dormant).

**What this is not.** Not Wardley mapping. Not event storming. Not business-model canvas. No scoring rubric. Five plain questions, one per turn, then a verdict.

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the ideas backlog via `portfolio_ideas_backlog` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
```

Defaults match today's single-fork layout (`./apexyard.projects.yaml`, `./projects`, `./projects/ideas-backlog.md`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir, ideas_backlog}` keys in `.claude/project-config.json`. Don't hardcode literal `apexyard.projects.yaml` or `projects/` paths in bash blocks — the helper resolves whichever mode the adopter is in. See `docs/multi-project.md`.

## Activated role

When `/validate-idea` runs, activate the **[Product Manager](../../../roles/product/product-manager.md)** role for the validation read-out, with optional handoff to **[Head of Product](../../../roles/product/head-of-product.md)** if the verdict is `green` and a roadmap-impact call is needed. The role's "is this worth doing?" lens is exactly the right perspective.

See `.claude/rules/role-triggers.md` for the activation protocol.

## Usage

```
/validate-idea IDEA-042              # validate a backlog entry by ID
/validate-idea curios-dog            # validate a registered project (handover follow-up)
/validate-idea AI-powered linter     # free-form description (no IDEA-NNN yet)
```

## Process

### 1. Resolve the input

- **`IDEA-NNN` form** — read `projects/ideas-backlog.md`; pull the row's title + one-line description as starting context. Output path: `projects/<project>/validation/<IDEA-NNN>-validation.md` (or `projects/_inbox/validation/<IDEA-NNN>-validation.md` if the IDEA hasn't been assigned to a project yet).
- **Project-name form** — read `apexyard.projects.yaml`; pull the project's README + handover-assessment if available, as starting context. Output path: `projects/<project>/validation/handover-validation.md`.
- **Free-form description** — slugify the title; output path: `projects/_inbox/validation/<slug>.md`.

If the input is ambiguous or absent, ask:

```
What are you validating? An IDEA-NNN, a project name, or a free-form pitch?
```

### 2. Show the starting context

Print whatever you pulled from step 1 (3-5 lines max), so the user can read what the skill *thinks* the idea is before answering questions. If the user disagrees, they can correct in their first answer.

### 3. Ask the five questions — ONE AT A TIME

Never batch. Wait for the answer before asking the next.

#### Q1 — Target user

```
Who specifically is this for? Be concrete — a role, a context, a moment of need.
"Everyone" is a red flag; "freelance designers who manage three or more
client invoices a month" is the right level.
```

If the answer is "everyone" / "anyone" / vague: probe once with `Pick the narrowest plausible group — even if you'll expand later. Who would benefit MOST from this in the first 30 days?`

#### Q2 — Current alternative

```
What do they do today instead?
```

Possible answers: a competitor product (specific name), a manual workaround (e.g. "a spreadsheet"), or "nothing — it's just an unmet need." If "nothing", probe: `If there's no alternative, the gap is either real-but-low-priority or fictional. Which? What evidence?`

#### Q3 — Smallest version that proves the value

```
What's the smallest thing you could build that would prove this is valuable?
1-2 days of work, max. Not "the MVP" — the SMALLEST testable slice.
```

If the answer is large (≥ 1 week of work): probe `Cut it in half. What's the half that, if it works, tells you the rest is worth building?`

#### Q4 — Kill criteria

```
What would prove this is wrong? What would you observe — concretely —
that would tell you to park this?
```

This question is the one most ideas can't answer cleanly. Inability to articulate kill criteria is itself signal — note it in the output.

#### Q5 — Build, buy, or rent

```
Is this:
  - BUILD (genuinely differentiating — your moat is the implementation)
  - BUY / OSS (commodity — someone has already shipped this; just adopt)
  - RENT (utility — pay a SaaS, don't build infrastructure for it)
```

If the answer is "build" but Q2's alternative is a working competitor product, probe: `If <competitor> already does this, what's your specific angle they don't have? If "I'd do it better" — that's not a moat; surface a real differentiator or move to BUY.`

### 4. Synthesise the verdict

Read all five answers together. Score in the **PM's** head (no rubric — this is a judgement call):

- **GREEN** — Q1 is concrete, Q2 has a clear alternative being beaten, Q3 fits in 1-2 days, Q4 is articulable, Q5 is BUILD with a real differentiator. Proceed to `/write-spec`.
- **YELLOW** — One or two answers are weak; the idea has a kernel but needs reshaping. Park for revision; revisit in a week with sharper answers.
- **RED** — Two or more answers are weak, OR Q5 is "build" with no differentiation, OR Q4 has no kill criteria. Park as `WONTDO`.

The verdict is a one-line statement at the bottom of the output, in bold, with a one-sentence reason.

### 5. Write the validation document

Output template (~50 lines):

```markdown
# {Title} — Validation

**Date**: YYYY-MM-DD
**Source**: {IDEA-NNN | project name | free-form}
**Verdict**: **{GREEN | YELLOW | RED}** — {one-sentence reason}

## Starting context

{3-5 lines from step 2}

## Q1. Target user

{user's answer + any probe response}

## Q2. Current alternative

{user's answer}

## Q3. Smallest version

{user's answer}

## Q4. Kill criteria

{user's answer; note explicitly if it was hard to articulate}

## Q5. Build / buy / rent

{user's answer + any probe}

## Read-out

{2-4 sentences synthesising the answers — what stood out, what's strong,
what's weak}

## Next step

{ONE of:
  - GREEN → "Proceed to `/write-spec {title}`."
  - YELLOW → "Park for {N} days. Revisit when {sharpening criterion} is in place."
  - RED → "Archive. Updating `projects/ideas-backlog.md` row to status WONTDO."
}
```

### 6. Side effects on the verdict

- **GREEN** — leave the IDEA-NNN backlog row at `NEW` (or whatever it was). The skill does NOT advance status; that's `/write-spec`'s job.
- **YELLOW** — leave the row unchanged; add a comment in the validation doc noting the revisit date.
- **RED** — if input was an IDEA-NNN, update the row in `projects/ideas-backlog.md`: change `Status` from current to `WONTDO`. Append a one-line reason to the row's notes.

### 7. Confirm

```
Validation written: projects/<...>/validation/<...>-validation.md
Verdict: {GREEN | YELLOW | RED}
{Side effect, if any: "ideas-backlog.md updated to WONTDO." | nothing}
```

## Rules

1. **One question at a time.** Never batch. The whole point is making the user *think* between answers.
2. **No scoring rubric.** Verdict is a PM judgement call, not a numeric average.
3. **Probes are at most one per question.** If the user's answer is still weak after one probe, capture it as-is and let it surface in the verdict.
4. **No competitive research.** The skill doesn't crawl the web for alternatives — Q2's "what do they do today?" is the user's own observation.
5. **Output is one page.** Synthesis section ≤ 4 sentences. Read-out should fit on one screen.
6. **`RED` updates the backlog automatically** — `WONTDO` is a recoverable state (the row stays); no destruction.
7. **`GREEN` does NOT auto-trigger `/write-spec`.** The user makes that call. Decoupling validation from spec-authoring keeps each step's intent explicit.

## Integration with sibling skills

### `/idea`

After the IDEA-NNN is captured (and the optional GitHub Issue is offered), `/idea` adds a third optional step:

```
Validate now? Run /validate-idea {IDEA-NNN} — y/n (default n)
```

Default-no respects `/idea`'s lightweight-capture intent. Most users batch-validate later.

### `/handover`

At the end of the integration-plan emit, IF the project is dormant by the heuristic (last commit > 90 days ago AND zero open PRs AND no recent issue activity), `/handover` adds:

```
This project looks dormant — run /validate-idea {project-name} to confirm
it's still worth investing in? y/n (default n)
```

Healthy active projects don't see the prompt. Dormant ones do.

## Anti-pattern

```
User: /validate-idea AI-powered grocery picker
Agent: [batches all 5 questions in one message]
       1. Who is this for?
       2. What's the alternative?
       3. Smallest version?
       4. Kill criteria?
       5. Build, buy, or rent?
```

Wrong. Batching defeats the validation purpose — the user gives surface-level answers without thinking. Ask one, wait, then the next.

## Related

- `/idea` — captures the idea pre-validation
- `/write-spec` — authors the PRD post-validation (only on GREEN)
- `/decide` — captures the technical decision once the spec is in flight
- The Mom Test (Rob Fitzpatrick) — companion reading; covers Q1 and Q2 in much more depth for live customer interviews

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
