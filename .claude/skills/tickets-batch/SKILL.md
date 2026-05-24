---
name: tickets-batch
description: File 5–20 structured tickets in one flow — shared-context Qs once, 3-Q micro-interview per ticket, then per-ticket `gh issue create`.
argument-hint: "<optional bulk description>"
allowed-tools: Bash, Read, Write
---

# /tickets-batch — Bulk-File Structured Tickets

The fast happy path for filing 5–20 tickets in one intent (project kickoff, roadmap decomposition, handover integration plan). Use this **instead of** raw `gh issue create` (non-conformant) or running `/feature` / `/task` / `/bug` N times serially (~10 questions × N tickets).

This skill is the *fast* happy path. Each ticket it produces conforms to the project's `.ticket.required_sections` schema **by construction** — never by post-hoc validation. The matching `validate-issue-structure.sh` hook is a backstop, not the primary fix.

Flow shape:

```
/tickets-batch
  → 1 shared-context Q batch (priority, epic, area-labels, repo)
  → N micro-interviews (≤ 3 Qs each: type, one-line purpose, optional clarification)
  → 1 confirmation
  → N `gh issue create` calls (one per ticket — never a single batch dump)
```

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
/tickets-batch
/tickets-batch File 12 tickets for the auth refactor
/tickets-batch ./backlog-batches/handover-integration.md
```

The argument is free-form — a description, a markdown file path, or empty. Step 2 below normalises whatever you pass into a list of titles.

## Process

### 1. Resolve the target repo

Read `.claude/session/current-ticket` to determine which repo we're working in. If absent:

- Scan `apexyard.projects.yaml` for managed projects.
- If only one project, use it.
- If multiple, ask: `Which project is this batch for?`
- If no projects are registered, ask for the repo in `owner/repo` format.

Confirm the resolved repo with the user before continuing — a wrong repo means N misfiled tickets, hard to undo.

### 2. Gather the batch

Accept ANY of these input shapes:

**a) A list pasted in one message** — numbered or bulleted, one title per line:

```
1. Wire OIDC discovery endpoint
2. Add session refresh to token middleware
3. Migrate user table to new auth schema
- Sweep deprecated /v1/login routes
- Add audit log for failed login attempts
```

**b) A path to a markdown file** containing the same — detect when `$ARGUMENTS` is a single token ending in `.md` or starts with `./` / `/` and points at an existing file.

**c) Empty / a free-form description** — ask:

```
Paste the list of titles, one per line, or give me a file path to read from.
```

Strip list markers (`1.`, `-`, `*`, `•`, leading whitespace). Drop empty lines and lines starting with `#` (treated as comments / headings). The result is an ordered list of N titles.

**Cap**: if N > 20, stop and say:

```
That's {N} tickets — over the per-batch cap of 20. Split into batches of ≤ 20
and re-run /tickets-batch for each. (The cap exists to keep the confirmation
step reviewable; bumping it later is a config change, not a skill rewrite.)
```

If N < 2, suggest `/feature` / `/task` / `/bug` instead — this skill is overkill for a single ticket.

### 3. Shared-context questions — ASK ONCE for the whole batch

Ask conversationally, one question at a time, but **only once for the entire batch** — not per ticket:

**a) Default priority**

Read the priority scheme from `.claude/project-config.json` → `.ticket.label_priority_scheme` (fallback `P0,P1,P2,P3`). Present the values:

```
Default priority for this batch?
1. P0 — must-have for current milestone
2. P1 — ship soon
3. P2 — future
4. P3 — backlog
(Per-ticket overrides aren't asked — bulk-file flow trades per-ticket priority for speed.
Re-prioritise after filing if needed.)
```

**b) Optional epic / parent ticket**

```
Optional epic or parent issue to reference in every ticket body?
(e.g. #42, owner/repo#42, or Enter to skip)
```

If provided, every filed ticket body gets a `Refs <epic>` line at the bottom. If skipped, no parent reference is added.

**c) Optional area labels**

```
Area labels to apply to all tickets? (comma-separated, e.g. area-backend, area-auth)
(Or Enter to skip. Type-specific labels — enhancement, bug, etc. — are auto-applied per ticket.)
```

Validate that each label is a single token (no spaces). If a label looks risky (e.g. contains `priority` — would conflict with the priority label), warn and re-ask.

**d) Repo confirmation**

Echo the resolved repo and the count, and confirm before starting the per-ticket interviews:

```
Filing {N} tickets to {owner/repo}, default priority {P1}, area labels: {labels or "none"},
parent: {epic or "none"}.

Continue? (yes / change / cancel)
```

### 4. Per-ticket micro-interview

For each title in order, run a **maximum-3-question** micro-interview. Show progress: `[Ticket 3 of 12]`.

**Q1 — Type** (always asked):

Read the whitelist from `.claude/project-config.json` → `.ticket.prefix_whitelist` (fallback `Feature, Bug, Chore, Refactor, Testing, CI, Docs`). Present numbered options:

```
[Ticket 3 of 12] "Migrate user table to new auth schema"
Type?
1. Feature — user-facing capability
2. Bug — broken behaviour
3. Chore — tech debt / housekeeping
4. Refactor — restructure without behaviour change
5. Testing — test coverage / fixtures
6. CI — pipelines / tooling
7. Docs — documentation
```

Accept the number or the type name (case-insensitive).

**Q2 — One-line purpose** (always asked):

```
One sentence on what this ticket does and why.
(Used to infer the body — User Story / Driver / Given-When-Then.)
```

Loop until non-empty. From the type + purpose, infer a draft body that **conforms by construction** to `.ticket.required_sections[<type>]`:

| Type | Required sections (from schema) | Inferred body shape |
|------|---------------------------------|---------------------|
| Feature | User Story, Acceptance Criteria | Restructure purpose into "As a [persona], I want [goal] so that [benefit]." If persona is unclear, default to "user". Acceptance Criteria starts with one checkbox derived from the purpose, plus a `- [ ] TBD` placeholder. |
| Chore | Driver, Scope, Acceptance Criteria | Driver = the "why" half of the purpose. Scope = the "what" half (or `TBD` if not separable). Acceptance Criteria = one checkbox + `- [ ] TBD`. |
| Refactor | Driver, Scope, Acceptance Criteria | Same as Chore. |
| Testing | Driver, Scope, Acceptance Criteria | Same as Chore. |
| CI | Driver, Scope, Acceptance Criteria | Same as Chore. |
| Docs | Driver, Acceptance Criteria | Driver = the purpose. Acceptance Criteria = one checkbox + `- [ ] TBD`. |
| Bug | Given / When / Then, Repro | Given/When/Then inferred from the purpose: Given = current state, When = trigger, Then = broken behaviour. If can't infer, set placeholder lines. Repro = `- [ ] TBD: add repro steps`. |

Every section must be **non-empty** — empty sections fail `validate-issue-structure.sh`. Always emit a placeholder (`TBD: <hint>`) rather than an empty header.

**Q3 — Optional clarification** (asked ONLY if inference is low-confidence):

Inference is low-confidence when:

- Feature: the purpose has no clear persona AND no clear "so that" benefit
- Bug: the purpose has no clear trigger ("when X happens") AND no clear broken behaviour
- Chore / Refactor / Testing / CI: the purpose has a why OR a what but not both

In those cases, ask **one** targeted question:

| Missing | Question |
|---------|----------|
| Feature persona/benefit | `Who's it for and what do they get out of it?` |
| Bug trigger | `What action triggers the bug?` |
| Chore why | `Why is this needed — what breaks or degrades if we don't do it?` |
| Chore what | `What specifically changes — files, services, behaviour?` |

If inference is confident, **skip Q3** and move on.

After Q1–Q3, show the inferred body inline (compact form, 4–6 lines) and continue to the next ticket without asking for confirmation per ticket — full-batch confirmation happens at step 5.

### 5. Show batch summary and confirm

Display all N tickets in a compact table:

```
Batch summary — {N} tickets to {owner/repo}:

| #  | Type     | Title                                              | Priority | Labels                  |
|----|----------|----------------------------------------------------|----------|-------------------------|
| 1  | Feature  | Wire OIDC discovery endpoint                       | P1       | enhancement, area-auth  |
| 2  | Feature  | Add session refresh to token middleware            | P1       | enhancement, area-auth  |
| 3  | Chore    | Migrate user table to new auth schema              | P1       | area-auth               |
| ...
| 12 | Testing  | Add OIDC integration tests                         | P1       | area-auth               |

Parent: #42

Confirm? (yes = file all / edit N = re-interview ticket N / cancel = abort)
```

Handle the response:

- `yes` → proceed to step 6
- `edit N` (e.g. `edit 3`) → jump back to step 4 for that ticket only, then re-show the summary
- `cancel` / `no` → abort, no tickets filed, no state written

**Do not file any ticket before this confirmation.** Partial commits-before-confirm are forbidden — a misclick at the summary should leave the tracker untouched.

### 6. File the batch

For each ticket in order, run a **specific `gh issue create`** — one call per ticket, NEVER a single bulk JSON dump. The validator runs per-issue, so per-issue calls are the only conformant shape.

Build the title as `[<Type>] <title>`. Build the body from the inferred sections, ending with the optional `Refs <epic>` line if a parent was set.

```bash
gh issue create --repo {owner/repo} \
  --title "[{Type}] {title}" \
  --label "{type-label},{priority},{area-labels}" \
  --body "{formatted body}"
```

Type-label mapping:

| Type | Auto-applied label |
|------|---------------------|
| Feature | `enhancement` |
| Bug | `bug` |
| Chore / Refactor / Testing / CI / Docs | (none — type is in title prefix; labels stay area + priority) |

Show progress per call:

```
[1/12] Filing "Wire OIDC discovery endpoint"… → owner/repo#451 ✓
[2/12] Filing "Add session refresh to token middleware"… → owner/repo#452 ✓
```

### 7. Failure handling

On the first `gh issue create` non-zero exit, **stop the batch immediately**. Do not silently skip. Show:

```
[5/12] Filing "Migrate user table to new auth schema"… ✗

Error from gh / validator:
{stderr — usually the validator's "missing section: Driver" line}

Filed so far: 4 tickets ({owner/repo}#451, #452, #453, #454).
Remaining: 8 tickets (not filed).

What now?
1. Retry — re-run the same gh call (use this if the failure was transient)
2. Skip — drop this ticket, continue with the next 7
3. Edit — re-interview this ticket and retry
4. Abort — stop here; the 4 already-filed tickets stay (no rollback)
```

Do **not** roll back already-filed tickets on abort. Tell the user exactly which ones did file — they can close the unwanted ones manually if they choose, but silent rollback would be worse than partial completion.

### 8. Return the summary

One line per created ticket:

```
Filed {N}/{total} tickets to {owner/repo}:

#451 — Feature — Wire OIDC discovery endpoint — https://github.com/{owner}/{repo}/issues/451
#452 — Feature — Add session refresh to token middleware — https://github.com/{owner}/{repo}/issues/452
#453 — Chore   — Migrate user table to new auth schema — https://github.com/{owner}/{repo}/issues/453
...

Skipped / failed: 0
Next: prioritise with the team, then `/start-ticket <N>` to begin work.
```

If any tickets were skipped or failed, list them under a separate `Skipped / failed:` section with the failure reason for each.

## Body templates (per type)

These are the **exact** shapes the inferred bodies must take. Each section header must be non-empty (placeholders allowed) so `validate-issue-structure.sh` passes.

### Feature

```markdown
## User Story
As a {persona}, I want {goal} so that {benefit}.

## Acceptance Criteria
- [ ] {criterion derived from the purpose}
- [ ] TBD — refine before starting work

{Refs <epic> if set}
```

### Chore / Refactor / Testing / CI

```markdown
## Driver
{why this is needed — derived from the purpose}

## Scope
{what changes — derived from the purpose, or "TBD: define before starting work"}

## Acceptance Criteria
- [ ] {criterion derived from the purpose}
- [ ] TBD — refine before starting work

{Refs <epic> if set}
```

### Docs

```markdown
## Driver
{why these docs are needed — derived from the purpose}

## Acceptance Criteria
- [ ] {criterion derived from the purpose}
- [ ] TBD — refine before starting work

{Refs <epic> if set}
```

### Bug

```markdown
## Given / When / Then
**Given** {precondition derived from purpose, or "TBD"}
**When** {trigger derived from purpose, or "TBD"}
**Then** {broken behaviour derived from purpose, or "TBD"}

## Repro
- [ ] TBD: add concrete repro steps

{Refs <epic> if set}
```

## Rules

1. **ASK shared-context questions ONCE** at the start (priority, epic, area-labels, repo). NEVER re-ask them per ticket.
2. **Per-ticket interview is at most THREE questions**: type, one-line purpose, optional clarification. If the type + purpose yield a confident inference, skip the third question.
3. **Output conforms to `.ticket.required_sections` by construction.** Never produce a body that the `validate-issue-structure.sh` hook would reject. Every required section is present and non-empty (placeholders allowed); section headers match the schema spelling exactly.
4. **One `gh issue create` per ticket.** NEVER a single batch-mode JSON dump — the validator runs per-issue and a bulk shape silently bypasses it.
5. **Confirm the full batch BEFORE filing any ticket.** No partial commits-before-confirm. A `cancel` at the summary leaves the tracker untouched.
6. **On failure mid-batch: stop, surface the validator error, ask the user.** Don't silently skip. Don't roll back. Tell them exactly which tickets did file.
7. **Cap at 20 tickets per invocation.** Above that, ask the user to split into batches.
8. **`argument-hint: "<optional bulk description>"`** — accept a free-form description, a markdown file path, or empty input. Normalise to a list of titles in step 2.
9. **Read schema from project-config.** Use `.ticket.prefix_whitelist`, `.ticket.label_priority_scheme`, and `.ticket.required_sections` from `.claude/project-config.json` (with defaults from `.claude/project-config.defaults.json`). Don't hard-code the schema in the skill — config drives.
10. **Leak protection still applies.** When the target repo is the public framework repo (e.g. `me2resh/apexyard`), never let a ticket title or body reference a registered private project name. The `block-private-refs-in-public-repos.sh` hook will reject such calls; the skill's job is to not produce them in the first place.
11. **No silent edits to existing tickets.** This skill creates only. To modify an existing ticket, use `gh issue edit` directly or open a follow-up.
12. **Defaults are sane, not magical.** If the inference produces a placeholder (`TBD: …`), say so in the summary table — don't pretend the body is complete. The user can `edit N` to refine before filing.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
