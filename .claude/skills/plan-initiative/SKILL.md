---
name: plan-initiative
description: Interview-driven initiative → milestones → tasks: per-milestone interview, a topo-sorted sequence, and optional filing of each milestone as a ticket with blocks/blocked-by cross-refs.
argument-hint: "<slug>"
---

# /plan-initiative — Initiative → Milestones → Tasks (dependency-aware)

The orchestrator surface above `/write-spec` and `/feature`. Quarter-shape planning for the strategic unit above features — usually 1-3 per quarter, multi-feature, multi-week — that decomposes deterministically into the existing ticket primitives the framework already governs.

Slot relative to existing skills:

```
/idea            (capture a raw idea)
/validate-idea   (5-question pre-spec gate)
/plan-initiative (initiative → milestones → tasks, dependency-aware)  ← this skill
/write-spec      (PRD for one feature)
/feature / /task / /bug / /spike (one ticket at a time)
```

Design rationale + the load-bearing decisions (Socratic interview over LLM auto-decompose, single template over separate initiative + milestone, two-pass filing for cross-refs, filed-marker idempotence) live in [AgDR-0051](../../../docs/agdr/AgDR-0051-plan-initiative-skill.md).

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the template via `portfolio_resolve_template initiative.md` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
template=$(portfolio_resolve_template initiative.md)   # → custom-templates/initiative.md if present, else templates/initiative.md
projects_dir=$(portfolio_projects_dir)
```

Defaults match today's single-fork layout (`./apexyard.projects.yaml`, `./projects`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir, ideas_backlog}` keys in `.claude/project-config.json`. Don't hardcode literal `projects/` paths — the helper resolves whichever mode the adopter is in. See `docs/multi-project.md`.

**Write targets** (see me2resh/apexyard#373 + #443): paths documented as `projects/<name>/X` in this skill are canonical adopter-facing forms — implement them in bash as `"${projects_dir}/<name>/X"`. Never construct from `"${PWD}/projects/..."`, `"$(git rev-parse --show-toplevel)/projects/..."`, or a literal `./projects/...` — those break in split-portfolio v2 mode where `projects_dir` resolves to a sibling repo.

**REQUIRED per-block preamble** (see #443): Claude executes each ```bash``` block as a separate shell invocation. The `projects_dir` assignment from the Path resolution section above does NOT carry into later blocks. Every bash block that writes to a `projects/<name>/X` path MUST start with this three-line preamble so it's self-contained:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
projects_dir=$(portfolio_projects_dir)
# ... now write to "${projects_dir}/<name>/X"
```

The Path resolution section's example sources the helper *once* for documentation purposes; it does not absolve later blocks from sourcing it themselves. Treat each ```bash``` fence as a fresh process.

## Usage

```
/plan-initiative q3-auth-rewrite
/plan-initiative billing-revamp-2026
/plan-initiative framework-handbook-domain-coverage
```

The slug is the only argument — used as the filename (`<slug>.md`) and the conversational referent during the interview. Slug must be kebab-case; if the operator passes a non-kebab argument, kebab-ify it and confirm before proceeding.

If no slug is passed, ask:

```
What's the initiative slug? (kebab-case, used as the filename and referent — e.g. q3-auth-rewrite)
```

## Output location

Decided during the **scope interview** (step 3 below), not from a flag:

- **Per-project**: `projects/<project-name>/initiatives/<slug>.md` — the initiative belongs to one registered managed project (auth rewrite for `marketing-site`, billing revamp for `legacy-billing-api`).
- **Framework-wide**: `projects/initiatives/<slug>.md` — the initiative spans projects, or is a framework / ops-fork-only initiative (e.g. "add domain handbook coverage to apexyard itself").

Both directories are created on first write if missing.

## Process

### 1. Resolve the slug + check for an existing initiative doc

Kebab-ify the argument (lowercase, hyphen-separated, alphanumeric only, max 60 chars). Confirm if the operator passed a non-kebab form.

Look for an existing initiative doc in BOTH possible locations:

```bash
existing=""
for candidate in "$projects_dir"/*/initiatives/"$slug.md" "$projects_dir"/initiatives/"$slug.md"; do
  [ -f "$candidate" ] && existing="$candidate" && break
done
```

If found, branch to the **re-run path** (step 1a). If not, continue to step 2 (first-run path).

#### 1a. Re-run path — read prior state

Read the existing doc. Parse:

- The initiative-level fields (Goal, Quarter, Success criterion, Scope) — display + confirm "still accurate?" with a y/n; only re-interview if `n`.
- The milestone blocks (`### Milestone N — Name`). For each, capture:
  - Status (unfiled / filed / cancelled / done)
  - Filing line (`Filed as [#N](url)` → marker present; `unfiled` → marker absent)
  - All key/value fields (success criterion, blocks, blocked by, kill criterion, value, risk, confidence)
- The DAG (Mermaid block at the top) — re-derived from the milestone blocks; the rendered DAG itself isn't load-bearing data.
- The re-run history table.

Print a one-line summary:

```
Re-run on q3-auth-rewrite — 5 milestones found (3 filed as #123, #124, #125; 2 unfiled).
What's changed since last run? (e.g. 'add milestone X', 'M2 unblocks new M6', 'M3 cancelled', or 'review the unfiled ones')
```

Branch on the response — add new milestones via step 4, mark cancellations, or jump straight to step 8 (filing) on "review the unfiled ones".

**Idempotence rule** (load-bearing): preserve `Filed as [#N](url)` markers across re-runs. Step 7's regeneration MUST NOT blow away the operator's filing history. Match prior milestones to regenerated ones by name (case-insensitive, normalised whitespace) — if the name matches, preserve the prior marker. See AgDR-0051 § Axis 4.

### 2. Initiative-level interview (first run only)

Ask conversationally, one question at a time:

**a) Goal — one sentence, outcome-shaped**

```
What's the goal of this initiative? Give me ONE sentence — the strategic
OUTCOME (not the features, not the milestones). Examples:
  - "Replace the OIDC-shimmed auth layer with first-party JWT before the SSO migration."
  - "Cut billing-API p95 latency from 8s to <1s for the top 5 endpoints."
  - "Cover every active project under apexyard governance with domain-aware handbooks."
```

If the operator gives a multi-sentence answer, restructure to a single sentence and confirm.

**b) Quarter / timeframe**

```
Rough timeframe? (e.g. Q3 2026, 8 weeks from today, by end of June, etc.)
```

Free-form. Don't enforce date parsing — the operator's words are the artefact.

**c) Success criterion**

```
What measurable / observable signal makes this initiative "done"?
Avoid output measures ("ship 10 features"). Prefer outcome measures
("10 customers using the new auth flow with no support tickets in 14 days").
```

**d) Scope**

```
Is this initiative scoped to:
  1. A specific registered project (e.g. marketing-site, legacy-billing-api)
  2. Framework-wide / cross-project (apexyard itself, or spanning multiple projects)
```

If `1`: read `apexyard.projects.yaml` via the registry helper, list registered projects, ask which one. Set `output_path="$projects_dir/$project_name/initiatives/$slug.md"`.

If `2`: set `output_path="$projects_dir/initiatives/$slug.md"`.

Echo the resolved output path and confirm before continuing.

### 3. Per-milestone Socratic interview (loop)

This is the load-bearing step. The interview shape is deliberately Socratic, not LLM auto-decompose (see AgDR-0051 § Axis 1). Operators commit deeper to plans they articulate; the cost in interview time IS the value.

Repeat this loop until the operator answers `done` to the "next milestone?" prompt:

```
Next milestone (or 'done' to finish naming):
```

For each named milestone, ask the **mandatory** questions, then offer the **optional Socratic** questions with `TBD` as an accepted answer for each.

#### Mandatory questions

**M.1 — Success criterion**

```
What makes "{Milestone name}" done? One sentence — measurable / observable.
```

**M.2 — Blocks** (what completing this UNBLOCKS)

```
What does completing "{Milestone name}" unblock? Names of OTHER milestones
this enables, comma-separated. (Type 'none' if this milestone unblocks nothing.)
```

Accept the milestone names the operator has already typed earlier in the interview. If they reference a milestone that doesn't exist yet, prompt: "you mentioned 'X' but I don't have a milestone by that name — should I add it as a placeholder to name later?"

**M.3 — Blocked by** (what must complete BEFORE this)

```
What must be done BEFORE "{Milestone name}" can start? Names of OTHER milestones
this depends on, comma-separated. (Type 'none' if this milestone has no upstream deps.)
```

#### Optional Socratic questions (each accepts `TBD` to defer)

**S.1 — Kill criterion**

```
What would make you CANCEL "{Milestone name}"? — i.e. a sign that finishing
this is no longer worth the effort. (Answer or 'TBD' to defer.)
```

**S.2 — Value** (downstream impact of completion)

```
Value of completing "{Milestone name}"? Low / Medium / High / TBD.
(High = directly moves the initiative's success criterion. Low = enables
future work but doesn't ship outcome.)
```

**S.3 — Risk** (likelihood of slippage or rework)

```
Risk on "{Milestone name}"? Low / Medium / High / TBD.
(High = unfamiliar tech, novel design, or unclear acceptance shape.
Low = well-understood work, similar to past completed milestones.)
```

**S.4 — Confidence in time estimate**

```
Confidence in your time estimate for "{Milestone name}"? Low / Medium / High / TBD.
(Operator-stated estimate isn't captured — only the confidence in it. Estimation
is downstream of /plan-initiative; this question forces the operator to articulate
where they're guessing.)
```

#### Context paragraph

After all 7 questions (3 mandatory + 4 optional), ask for 2-3 sentences of context:

```
Two or three sentences of context on "{Milestone name}" — what's the work,
who's involved, what artefacts get produced. This becomes the body of the
filed Feature ticket if you choose to file it later.
```

Don't loop on this — accept whatever the operator types.

### 4. Cycle detection on the DAG

After the interview loop completes, build the DAG from the milestone blocks' `Blocks` / `Blocked by` answers. Detect cycles via Kahn's-algorithm-style topological sort:

```bash
# Pseudocode
build_graph(milestones)        # nodes = milestone names; edges = "X blocks Y"
in_degree = compute_in_degree(graph)
queue = [m for m in milestones if in_degree[m] == 0]
sorted_order = []
while queue:
    n = queue.pop()
    sorted_order.append(n)
    for m in graph[n]:
        in_degree[m] -= 1
        if in_degree[m] == 0:
            queue.append(m)
if len(sorted_order) < len(milestones):
    cycle_nodes = [m for m in milestones if in_degree[m] > 0]
    # FAIL — print cycle, ask operator to resolve
```

On cycle:

```
⚠ Dependency cycle detected:

  Milestone "M2" → "M3" → "M2"

These milestones can't all be sequenced. Resolve by either:
  1. Removing one of the dependencies (which one?)
  2. Merging the cycle into one milestone
  3. Splitting one milestone so the dependency direction reverses

What would you like to change?
```

Loop on the operator's resolution until the DAG is acyclic. v1 does NOT auto-break cycles — operator-driven resolution is the contract.

### 5. Topological sort + sequence with tie-breaks

With an acyclic DAG, produce the topo-sorted order. For ties (multiple milestones with equal in-degree at a topo layer), break by:

1. **Value × risk-inverse** — high-value, low-risk milestones first. Numeric mapping: `Low=1, Medium=2, High=3, TBD=2` (TBD defaults to medium so it doesn't dominate). Score = `value_num - (risk_num - 2)` (so risk-low boosts the score; risk-high lowers it).
2. **Insertion order from the interview** — secondary tie-break. The operator's order-of-mention is meaningful signal.

Render the sequence as a numbered list with one-line rationale per entry:

```
Recommended sequence (topo-sorted, ties broken by value × risk-inverse):

1. Foundation: schema migration — no inbound deps; value H, risk L
2. Token endpoint — depends on Milestone 1; value H, risk M
3. Refresh middleware — depends on Milestone 2; value M, risk L
4. Deprecate v1 routes — depends on Milestones 2, 3; value M, risk M
5. Decommission shim — depends on Milestone 4; value H, risk L

Sequence rationale: Milestone 1 is the unblocker; M2 + M3 are independent
within their layer but M2 sequences first because risk is bounded and value
is higher. M4 + M5 form the cleanup tail.
```

### 6. Render the doc

Resolve the template + substitute the gathered fields:

```bash
template_path=$(portfolio_resolve_template initiative.md)
# Fall back to inline shape if portfolio_resolve_template returns empty.
```

Substitute the interview answers into the template. Render the Mermaid DAG with one node per milestone + one edge per `Blocks` relationship; apply the `filed` / `unfiled` / `cancelled` classDefs based on milestone status.

Write the file via `Write` (NOT `cat > $path` — the framework prefers the dedicated tool for tracked edits). The output path is the one resolved in step 2(d) or the existing path from step 1.

Append to the **Re-run history** table — one row per invocation:

| Date | Delta |
|------|-------|
| YYYY-MM-DD | Initial creation — N milestones, scope=`{per-project / framework-wide}` |
| YYYY-MM-DD | Added milestone "X"; filed M1, M2 as #123, #124 |

### 7. Show the rendered doc + confirm

Print the resolved output path and the rendered doc inline. Ask:

```
Initiative doc written to projects/<name>/initiatives/q3-auth-rewrite.md.

Next: would you like to file the unfiled milestones as tracker tickets?
(per-item y/n, mirrors /handover step 7.5 — see option list below)
```

### 8. Offer to file milestones as tracker tickets (two-pass)

Mirrors `/handover` step 7.5 UX. Partition milestones into **already-filed** (carry `Filed as [#N](url)` marker — silently skipped) and **unfiled** (offered for filing).

#### Skip conditions

- **Zero unfiled milestones** → skip silently with `All milestones in this initiative are already filed — nothing to offer.`
- **Operator answered `done` to the interview but the milestone list is empty** (no milestones named) → skip silently.

#### Surface the unfiled entries

```
Found 5 unfiled milestones (2 were filed in a prior run — skipping). File any as tracker tickets?

  1. Foundation: schema migration  (value H, risk L)
  2. Token endpoint                 (value H, risk M, depends on Milestone 1)
  3. Refresh middleware             (value M, risk L, depends on Milestone 2)
  4. Deprecate v1 routes            (value M, risk M, depends on Milestones 2, 3)
  5. Decommission shim              (value H, risk L, depends on Milestone 4)

Per-item y/n (or 'all', 'none', a comma-list like '1,3,5'):
```

The leading `(N were filed in a prior run — skipping)` parenthetical only appears when at least one prior-filed milestone was skipped; on first-run flows, omit it.

Accept:

- `all` or `y` → file every unfiled milestone
- `none` or `n` or empty → skip all
- Comma-separated indices (e.g. `1,3,5`) → file just those
- Per-item y/n if the operator wants to walk through them one at a time

#### Pass 1 — file each accepted milestone

Write the active-issue-skill marker so `require-skill-for-issue-create.sh` lets the `gh issue create` calls through (per AgDR-0030):

```bash
ops_root="$(r=$PWD;while [ ! -f \"$r/onboarding.yaml\" ] && [ \"$r\" != / ];do r=${r%/*};done;echo $r)"
mkdir -p "$ops_root/.claude/session"
echo "plan-initiative" > "$ops_root/.claude/session/active-issue-skill"
```

For each accepted milestone (in topo-sorted order, so blocking milestones are filed before blocked ones), build the Feature-shape body conforming to `validate-issue-structure.sh`'s required sections:

```markdown
## User Story
As an operator working on the {initiative-name} initiative, I want {milestone-name} so that {success criterion}.

## Acceptance Criteria
- [ ] {success criterion as a checkbox}
- [ ] Confidence verified — {confidence value or 'TBD'}

## Context

{context paragraph from the interview}

**Value**: {Low/Medium/High/TBD}
**Risk**: {Low/Medium/High/TBD}
**Kill criterion**: {kill criterion or 'TBD'}

_Source: /plan-initiative on YYYY-MM-DD — see `projects/<name>/initiatives/<slug>.md` in the ops fork (or in the private portfolio sibling repo for split-portfolio v2 adopters) for the full initiative + dependency graph._
```

Same source-link shape as `/handover` step 7.5 — plain prose path, no markdown link. The initiative doc lives in the ops fork (or private sibling), not in the target repo's URL space; a relative markdown link would be dead-on-render. See AgDR-0051 § Axis 3.

File each via `gh issue create`:

```bash
gh issue create --repo "$repo" \
  --title "[Feature] {milestone-name}" \
  --label "enhancement,${priority:-P2}" \
  --body "$body"
```

Capture the returned issue number from `gh issue create`'s output (the URL contains it, or use `--json url -q '.url'`). Record `milestone_name → issue_number` in an in-memory map for pass 2.

On non-zero exit, stop pass 1 immediately. Use the same failure-handling shape as `/tickets-batch` § "Failure handling" (4 options: Retry, Skip, Edit, Abort; don't roll back filed tickets on abort).

#### Pass 2 — add cross-references to each filed ticket

Iterate over the just-filed set. For each filed milestone:

1. Compute its inbound + outbound DAG edges restricted to the also-filed set.
2. Build the cross-ref lines:
   - **Blocks**: comma list of `#N` references for downstream milestones that ARE filed
   - **Blocked by**: comma list of `#N` references for upstream milestones that ARE filed
3. Fetch the current body to handle the teammate-edit race (per AgDR-0051 § Risks):

```bash
current_body=$(gh issue view "$issue_number" --repo "$repo" --json body -q '.body')
```

4. Splice the cross-ref lines into the body — insert immediately after the `## User Story` section (before `## Acceptance Criteria`):

```markdown
## User Story
... (preserved verbatim) ...

**Blocks**: #X, #Y
**Blocked by**: #Z

## Acceptance Criteria
...
```

If a milestone has no cross-refs (no blocks AND no blocked-by within the filed set), skip pass 2 for that one.

5. Write back:

```bash
gh issue edit "$issue_number" --repo "$repo" --body "$new_body"
```

On any pass-2 failure: surface the error, name the affected milestone, continue with the rest. Don't abort pass 2 mid-way — partial cross-refs are more useful than zero cross-refs.

#### Remove the active-issue-skill marker on completion

```bash
rm -f "$ops_root/.claude/session/active-issue-skill"
```

Always remove on every exit path (success, abort, error). The `clear-issue-skill-marker.sh` SessionStart hook sweeps stale markers if the skill is interrupted, but a clean exit should never leave one behind.

### 9. Update the initiative doc post-filing

After pass 2 completes, rewrite the affected milestone blocks in the initiative doc:

- Replace each filed milestone's `**Filing**: unfiled` line with `**Filing**: Filed as [#N](https://github.com/owner/repo/issues/N)`
- Replace `**Status**: unfiled` with `**Status**: filed`

So a future reader of `<slug>.md` (or a future `/plan-initiative <slug>` re-run) sees which milestones became tickets and which are still TODO. This is the load-bearing input to step 1a's filed-marker preservation.

Append a row to the **Re-run history** table:

| Date | Delta |
|------|-------|
| YYYY-MM-DD | Filed milestones M1, M2, M3 as #123, #124, #125 |

### 10. Return the summary

```
✓ /plan-initiative q3-auth-rewrite complete.

Output: projects/<name>/initiatives/q3-auth-rewrite.md
Milestones: 5 total (3 just filed: #123, #124, #125 — 2 still unfiled in the doc)

Next:
  - Refine the unfiled milestones inline in the doc, then re-run /plan-initiative q3-auth-rewrite
  - Or jump to filing-time work: /start-ticket 123 and begin Milestone 1 (the topo-sort head)
```

## Rules

1. **Slug is the only argument.** Kebab-case; max 60 chars. If the operator passes a non-kebab form, kebab-ify and confirm before proceeding.
2. **Initiative-level questions are asked ONCE per first-run.** Re-runs re-confirm with a y/n; only re-interview on `n`.
3. **Per-milestone interview is Socratic, not LLM-decompose.** Mandatory questions (name, success criterion, blocks, blocked-by) MUST be answered. Optional questions (kill criterion, value, risk, confidence) ACCEPT `TBD` as a defer-to-later answer; the skill records the deferral but never loops on it.
4. **One milestone at a time.** Don't batch-ask all milestones upfront. The loop's `next milestone (or 'done')` shape is the forcing function — operators stop naming milestones when they run out of judgment, not when they hit a fixed N.
5. **DAG cycles are operator-resolved, not auto-broken.** The skill detects, prints the cycle, and asks for a resolution. v1 doesn't try to be clever.
6. **Topo-sort with value × risk-inverse tie-breaks.** Numeric mapping: Low=1, Medium=2, High=3, TBD=2. Score = `value_num - (risk_num - 2)`. Insertion order is the secondary tie-break.
7. **Mermaid DAG is the rendered representation.** Renders inline on GitHub, no build step. Same convention as `/c4`, `/dfd`, `/feature-diagram`.
8. **Idempotence via filed-marker presence.** Re-runs partition milestones into "already filed" (silently skipped at filing step) vs "unfiled" (offered). Step 6's regeneration MUST preserve prior `Filed as [#N](url)` markers — match milestones across runs by name (case-insensitive, normalised whitespace). NOT byte-equivalence on the section (which would break under the post-filing rewrite). Same rule as `/handover` Rule 18.
9. **Two-pass filing handles cross-refs.** Pass 1 files all accepted milestones (no cross-refs yet — issue numbers not yet known). Pass 2 iterates over the filed set, computes per-milestone cross-refs restricted to the also-filed subset, and rewrites each ticket's body via `gh issue edit`. Pass-2 failures don't abort — partial cross-refs are more useful than zero.
10. **Source-link every filed ticket back to the initiative doc.** Each filed Feature ticket carries a `_Source: /plan-initiative on YYYY-MM-DD — see projects/<name>/initiatives/<slug>.md in the ops fork (...)_` footer in the body. Plain prose path, no markdown link — the initiative doc isn't in the target repo's URL space. Same shape as `/handover` step 7.5's source-link convention.
11. **Active-issue-skill marker handling.** Write `plan-initiative` to `<ops_root>/.claude/session/active-issue-skill` before the first `gh issue create` in pass 1; remove on EVERY exit path (success, abort, error). Per AgDR-0030.
12. **No bootstrap exemption needed.** The skill writes `*.md` (exempt from `require-active-ticket.sh`) and dispatches `gh` calls (gated separately by `require-skill-for-issue-create.sh`, satisfied by the active-issue-skill marker in step 8 pass 1). Don't add `plan-initiative` to `ticket.bootstrap_skills`.
13. **Re-run history is append-only.** Each invocation adds one row to the table at the bottom of the doc. Don't truncate; long histories are evidence the initiative is being actively re-planned.
14. **Out-of-scope items belong in the Anti-scope section.** When the operator names something during the interview as "we considered this but no", capture it in the doc's `## Anti-scope` block. Mirrors `templates/architecture/vision.md` § Anti-scope.
15. **No auto-decomposition.** v1 deliberately does NOT take the initiative goal and emit N milestones from an LLM call. The Socratic interview shape is the contract; auto-decompose is a different product (and a worse one). See AgDR-0051 § Axis 1.

## Notes

- **Cross-initiative dependencies are out of scope for v1.** If Initiative A blocks Initiative B, capture that in prose in A's `## Anti-scope` or B's `## Goal` paragraph. v2 may add cross-initiative DAG semantics; v1 is one initiative at a time.
- **Time/effort estimation is downstream.** The skill captures `confidence` in the operator's estimate, not the estimate itself. Estimation belongs in each milestone's filed Feature ticket via `/start-ticket` + the team's normal estimation flow.
- **Resource allocation / role assignment is out of scope.** The framework's role-trigger machinery (per `.claude/rules/role-triggers.md`) handles who-picks-up-what once tickets are filed. `/plan-initiative` stops at the filing step.
- **Mermaid renders, doesn't lint.** The skill outputs Mermaid `flowchart LR` blocks; doesn't run any Mermaid linter. If the operator wants to view the DAG outside GitHub's renderer, they pipe the block through `mmdc` themselves.
- **PDF export via `/pdf`.** The initiative doc is markdown; for stakeholder-share work, `/pdf projects/<name>/initiatives/<slug>.md` converts to PDF via the framework's standard converter dispatch.

## Related

- [AgDR-0051](../../../docs/agdr/AgDR-0051-plan-initiative-skill.md) — design rationale for this skill (Socratic vs LLM-decompose, single template, two-pass filing, filed-marker idempotence)
- [`.claude/skills/handover/SKILL.md`](../handover/SKILL.md) § 7.5 — the per-item filing UX this skill mirrors (introduced #376)
- [`templates/initiative.md`](../../../templates/initiative.md) — the master initiative-doc template
- [`.claude/skills/write-spec/SKILL.md`](../write-spec/SKILL.md) — the per-feature PRD skill that each milestone naturally flows into after filing
- [`.claude/skills/validate-idea/SKILL.md`](../validate-idea/SKILL.md) — the pre-spec gate that sometimes runs BEFORE `/plan-initiative` (when the initiative starts as a raw idea)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
