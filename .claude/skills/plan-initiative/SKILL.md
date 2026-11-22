---
name: plan-initiative
description: Interview-driven initiative → milestones → tasks: per-milestone interview, a topo-sorted sequence, and optional filing of each milestone as a ticket with blocks/blocked-by cross-refs.
argument-hint: "<slug>"
---

# /plan-initiative: Initiative → Milestones → Tasks (dependency-aware)

Read `.claude/rules/writing-standard.md`. Use the **controlled technical writing profile** for the
initiative document and filed milestones. Open with the outcome and remove empty
conditional sections.

This skill coordinates planning above `/write-spec` and `/feature`. Initiatives usually span multiple features and weeks, with 1-3 per quarter. Each initiative decomposes into the existing ticket primitives that the framework governs.

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

Use `.claude/hooks/_lib-portfolio-paths.sh` to resolve paths. Read the registry through `portfolio_registry`, the per-project docs directory through `portfolio_projects_dir`, and the template through `portfolio_resolve_template initiative.md`. Source the helper at the start of each bash block that uses these paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
template=$(portfolio_resolve_template initiative.md)   # → custom-templates/initiative.md if present, else templates/initiative.md
projects_dir=$(portfolio_projects_dir)
```

Defaults match the single-fork layout (`./apexyard.projects.yaml`, `./projects`). Split-portfolio adopters override `portfolio.{registry, projects_dir, ideas_backlog}` in `.claude/project-config.json`. Do not hardcode literal `projects/` paths. The helper resolves the adopter's mode. See `docs/multi-project.md`.

**Write targets** (see me2resh/apexyard#373 + #443): `projects/<name>/X` paths are canonical adopter-facing forms. In bash, use `"${projects_dir}/<name>/X"`. Never construct paths from `"${PWD}/projects/..."`, `"$(git rev-parse --show-toplevel)/projects/..."`, or literal `./projects/...`. These paths fail in split-portfolio v2 mode, where `projects_dir` resolves to a sibling repo.

**REQUIRED per-block preamble** (see #443): Claude executes each ```bash``` block in a separate shell. The `projects_dir` assignment above does NOT carry into later blocks. Every bash block that writes to `projects/<name>/X` MUST start with this three-line preamble:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
projects_dir=$(portfolio_projects_dir)
# ... now write to "${projects_dir}/<name>/X"
```

The Path resolution example sources the helper once for documentation. Later blocks must source it again. Treat each ```bash``` fence as a fresh process.

## Usage

```
/plan-initiative q3-auth-rewrite
/plan-initiative billing-revamp-2026
/plan-initiative framework-handbook-domain-coverage
```

The slug is the only argument. It supplies the filename (`<slug>.md`) and identifies the initiative during the interview. The slug must use kebab-case. If the argument uses another form, convert it to kebab-case and confirm before continuing.

If the operator supplies no slug, ask:

```
What's the initiative slug? (kebab-case, used as the filename and referent: e.g. q3-auth-rewrite)
```

## Output location

Decided during the **scope interview** (step 3 below), not from a flag:

- **Per-project**: `projects/<project-name>/initiatives/<slug>.md`: the initiative belongs to one registered managed project (auth rewrite for `marketing-site`, billing revamp for `legacy-billing-api`).
- **Framework-wide**: `projects/initiatives/<slug>.md`: the initiative spans projects, or is a framework / ops-fork-only initiative (e.g. "add domain handbook coverage to apexyard itself").

Create either directory on first write if missing.

## Process

Use `AskUserQuestion` for every operator option menu in this skill. Follow `.claude/rules/reporting-style.md § Operator choices`.
Preserve multiple selections where the menu permits them. Split menus with more than four options into sequential wizard questions.
Keep single yes/no and ticket confirmation prompts as written.
The prose menus below are fallbacks only when the harness lacks `AskUserQuestion`.

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

#### 1a. Re-run path: read prior state

Read the existing doc. Parse:

- Display the initiative-level fields (Goal, Quarter, Success criterion, Scope). Confirm "still accurate?" with a y/n. Repeat the interview only if `n`.
- The milestone blocks (`### Milestone N — Name`). For each, capture:
  - Status (unfiled / filed / cancelled / done)
  - Filing line (`Filed as [#N](url)` → marker present, `unfiled` → marker absent)
  - All key/value fields (success criterion, blocks, blocked by, kill criterion, value, risk, confidence)
- Derive the DAG again from the milestone blocks. The Mermaid block at the top renders the DAG but does not supply authoritative data.
- The re-run history table.

Print a one-line summary:

```
Re-run on q3-auth-rewrite: 5 milestones found (3 filed as #123, #124, #125; 2 unfiled).
What's changed since last run? (e.g. 'add milestone X', 'M2 unblocks new M6', 'M3 cancelled', or 'review the unfiled ones')
```

Branch on the response. Add new milestones through step 4, mark cancellations, or proceed directly to step 8 (filing) on "review the unfiled ones".

**Idempotence rule** (required): preserve `Filed as [#N](url)` markers across re-runs. Step 7's regeneration MUST NOT delete the operator's filing history. Match prior and regenerated milestones by name (case-insensitive, normalised whitespace). Preserve the prior marker when the name matches. See AgDR-0051 § Axis 4.

### 2. Initiative-level interview (first run only)

Ask conversationally, one question at a time:

**a) Goal: one sentence, outcome-shaped**

```
What's the goal of this initiative? Give me ONE sentence: the strategic
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

Accept free-form text. Do not enforce date parsing. The operator's words are the artefact.

**c) Success criterion**

```
What measurable / observable signal makes this initiative "done"?
Avoid output measures ("ship 10 features"). Prefer outcome measures
("10 customers using the new auth flow with no support tickets in 14 days").
```

**d) Scope**

Use `AskUserQuestion` for the scope choice. Recommend the specific project when the operator names one.
Otherwise recommend framework-wide scope. Use the prompt below only without the tool.

```
Is this initiative scoped to:
  1. A specific registered project (e.g. marketing-site, legacy-billing-api)
  2. Framework-wide / cross-project (apexyard itself, or spanning multiple projects)
```

If `1`: read `apexyard.projects.yaml` via the registry helper, list registered projects, ask which one. Set `output_path="$projects_dir/$project_name/initiatives/$slug.md"`.

If `2`: set `output_path="$projects_dir/initiatives/$slug.md"`.

Echo the resolved output path and confirm before continuing.

### 3. Per-milestone Socratic interview (loop)

This required step uses a Socratic interview instead of LLM auto-decomposition (AgDR-0051 § Axis 1). Operators commit more to plans they articulate. The interview time supplies that value.
Repeat this loop until the operator answers `done` to the "next milestone?" prompt:

```
Next milestone (or 'done' to finish naming):
```

For each named milestone, ask the **mandatory** questions, then offer the **optional Socratic** questions with `TBD` as an accepted answer for each.

#### Mandatory questions

**M.1: Success criterion**

```
What makes "{Milestone name}" done? One sentence: measurable / observable.
```

**M.2: Blocks** (what completing this UNBLOCKS)

```
What does completing "{Milestone name}" unblock? Names of OTHER milestones
this enables, comma-separated. (Type 'none' if this milestone unblocks nothing.)
```

Accept milestone names that the operator typed earlier. If a referenced milestone does not exist, ask about a placeholder: "you mentioned 'X' but I do not have that milestone. Should I add it as a placeholder to name later?"

**M.3: Blocked by** (what must complete BEFORE this)

```
What must be done BEFORE "{Milestone name}" can start? Names of OTHER milestones
this depends on, comma-separated. (Type 'none' if this milestone has no upstream deps.)
```

#### Optional Socratic questions (each accepts `TBD` to defer)

**S.1: Kill criterion**

```
What would make you CANCEL "{Milestone name}"? Give a sign that finishing
this is no longer worth the effort. (Answer or 'TBD' to defer.)
```

**S.2: Value** (downstream impact of completion)

```
Value of completing "{Milestone name}"? Low / Medium / High / TBD.
(High = directly moves the initiative's success criterion. Low = enables
future work but doesn't ship outcome.)
```

**S.3: Risk** (likelihood of slippage or rework)

```
Risk on "{Milestone name}"? Low / Medium / High / TBD.
(High = unfamiliar tech, novel design, or unclear acceptance shape.
Low = well-understood work, similar to past completed milestones.)
```

**S.4: Confidence in time estimate**

```
Confidence in your time estimate for "{Milestone name}"? Low / Medium / High / TBD.
(Capture only confidence, not the operator-stated estimate. Estimation
is downstream of /plan-initiative; this question forces the operator to articulate
where they're guessing.)
```

#### Context paragraph

After all 7 questions (3 mandatory + 4 optional), ask for 2-3 sentences of context:

```
Two or three sentences of context on "{Milestone name}": what's the work,
who's involved, what artefacts get produced. This becomes the body of the
filed Feature ticket if you choose to file it later.
```

Do not repeat this question. Accept whatever the operator types.

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
    # FAIL: print cycle, ask operator to resolve
```

On cycle, use `AskUserQuestion` for the three resolution types. Use the prompt below only without the tool:

```
⚠ Dependency cycle detected:

  Milestone "M2" → "M3" → "M2"

These milestones can't all be sequenced. Resolve by either:
  1. Removing one of the dependencies (which one?)
  2. Merging the cycle into one milestone
  3. Splitting one milestone so the dependency direction reverses

What would you like to change?
```

Repeat the operator's resolution process until the DAG is acyclic. v1 must not break cycles automatically. The operator must resolve them.

### 5. Topological sort + sequence with tie-breaks

With an acyclic DAG, produce the topo-sorted order. For ties (multiple milestones with equal in-degree at a topo layer), break by:

1. **Value × risk-inverse**: prioritize high-value, low-risk milestones. Numeric mapping: `Low=1, Medium=2, High=3, TBD=2`. TBD defaults to medium to avoid dominating. Score = `value_num - (risk_num - 2)`. Low risk raises the score. High risk lowers it.
2. **Insertion order from the interview**: secondary tie-break. The operator's order-of-mention is meaningful signal.

Render the sequence as a numbered list with one-line rationale per entry:

```
Recommended sequence (topo-sorted, ties broken by value × risk-inverse):

1. Foundation: schema migration: no inbound deps; value H, risk L
2. Token endpoint: depends on Milestone 1; value H, risk M
3. Refresh middleware: depends on Milestone 2; value M, risk L
4. Deprecate v1 routes: depends on Milestones 2, 3; value M, risk M
5. Decommission shim: depends on Milestone 4; value H, risk L

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

Substitute the interview answers into the template. Render one Mermaid DAG node per milestone and one edge per `Blocks` relationship. Apply `filed` / `unfiled` / `cancelled` classDefs according to milestone status.

Write the file with `Write`. Do not use `cat > $path`. The framework prefers the dedicated tool for tracked edits. Use the output path from step 2(d), or the existing path from step 1.

Append to the **Re-run history** table: one row per invocation:

| Date | Delta |
|------|-------|
| YYYY-MM-DD | Initial creation: N milestones, scope=`{per-project / framework-wide}` |
| YYYY-MM-DD | Added milestone "X". Filed M1, M2 as #123, #124 |

### 6.5. Lint the rendered doc

Run `lint.sh` against the file you wrote. It wraps `_lib-mermaid-lint.sh` to extract the DAG's ` ```mermaid ` block and validate it with `mmdc` (mermaid-cli). This detects broken blocks before someone opens the document on GitHub. This block runs in a fresh process, as the per-block preamble rule requires. Explicitly assign `output_path` to the path from step 2(d) / step 1. An unset variable gives lint an empty path and exit code 2:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
projects_dir=$(portfolio_projects_dir)
SKILL_DIR="$(git rev-parse --show-toplevel)/.claude/skills/plan-initiative"
# Assign the literal path resolved in step 2(d) / step 1, for example:
#   scope 1 (project-scoped): output_path="$projects_dir/<project_name>/initiatives/<slug>.md"
#   scope 2 (framework-wide): output_path="$projects_dir/initiatives/<slug>.md"
output_path="<path resolved in step 2(d) or step 1>"
"$SKILL_DIR/lint.sh" "$output_path" || lint_rc=$?
```

Handle the exit code before reporting the doc as written:

- **Exit 0**: clean. Report `Mermaid lint: clean` alongside the output path.
- **Exit 1**: parse error. Print the lint output. Fix and re-lint the offending DAG block (a classDef or edge missed during substitution). Alternatively, ask whether to proceed with `--skip-lint`. Never report success with an unfixed failure.
- **Exit 2**: bad input, usually `output_path` unset or referencing a missing file. Fix the path assignment and re-lint. Do not report the document as written until this succeeds.
- **Exit 3**: `mmdc` / Node unavailable. Print `Mermaid not validated: mmdc not available.`. Report `Mermaid not validated: mmdc not available` with the output path. Do not claim a clean diagram.
- **`--skip-lint`** (operator-requested): report `Mermaid lint skipped`.

### 7. Show the rendered doc + confirm

Print the resolved output path and the rendered doc inline. Ask:

```
Initiative doc written to projects/<name>/initiatives/q3-auth-rewrite.md.

Next: would you like to file the unfiled milestones as tracker tickets?
(per-item y/n, mirrors /handover step 7.5: see option list below)
```

### 8. Offer to file milestones as tracker tickets (two-pass)

Follow the `/handover` step 7.5 UX. Partition milestones into **already-filed** (carry `Filed as [#N](url)` markers, silently skip) and **unfiled** (offer for filing).

#### Skip conditions

- **Zero unfiled milestones** → skip silently with `All milestones in this initiative are already filed. Nothing to offer.`
- **Operator answered `done` to the interview but the milestone list is empty** (no milestones named) → skip silently.

#### Surface the unfiled entries

```
Found 5 unfiled milestones (2 were filed in a prior run: skipping). File any as tracker tickets?

  1. Foundation: schema migration  (value H, risk L)
  2. Token endpoint                 (value H, risk M, depends on Milestone 1)
  3. Refresh middleware             (value M, risk L, depends on Milestone 2)
  4. Deprecate v1 routes            (value M, risk M, depends on Milestones 2, 3)
  5. Decommission shim              (value H, risk L, depends on Milestone 4)

Per-item y/n (or 'all', 'none', a comma-list like '1,3,5'):
```

Show the leading `(N were filed in a prior run: skipping)` parenthetical only after skipping at least one previously filed milestone. Omit it on first runs.

Accept:

- `all` or `y` → file every unfiled milestone
- `none` or `n` or empty → skip all
- Comma-separated indices (e.g. `1,3,5`) → file only those
- Per-item y/n if the operator wants to walk through them one at a time

#### Pass 1: file each accepted milestone

Write the active-issue-skill marker defensively (AgDR-0030). Since #709/#771, issue creation calls the `tracker_create` **function** through command substitution: `result="$(tracker_create …)"`. The `require-skill-for-issue-create.sh` matcher fires only at a command boundary. It does not match a call within `$(…)`. The marker no longer permits creation. Retain it for compatibility, robustness, and paths that call bare `gh issue create` at a command boundary.

```bash
# Ops root through the session pin (docs/skills/shared/ops-root.md).
ops_root=$(p="${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID:-}"; r=""; [ -z "${APEXYARD_OPS_DISABLE_PIN:-}" ] && [ -f "$p" ] && IFS= read -r r < "$p"; [ -f "$r/.claude/hooks/_lib-ops-root.sh" ] || { r="$PWD"; while [ -n "$r" ] && [ ! -f "$r/.claude/hooks/_lib-ops-root.sh" ]; do r=${r%/*}; done; }; [ -f "$r/.claude/hooks/_lib-ops-root.sh" ] && . "$r/.claude/hooks/_lib-ops-root.sh" && resolve_ops_root) && [ -n "$ops_root" ] || { echo "No ops root. See docs/skills/shared/ops-root.md." >&2; exit 1; }
mkdir -p "$ops_root/.claude/session"
marker_home="$ops_root"
. "$marker_home/.claude/hooks/_lib-session-markers.sh"
skill_marker=$(active_issue_skill_marker_path "$marker_home") || { echo "A session id is required. Restart through the harness adapter." >&2; exit 2; }
echo "plan-initiative" > "$skill_marker"
```

For each accepted milestone, build the Feature body with the sections that `validate-issue-structure.sh` requires. Use topological order to file blockers before their dependants:

```markdown
## User Story
As an operator working on the {initiative-name} initiative, I want {milestone-name} so that {success criterion}.

## Acceptance Criteria
- [ ] {success criterion as a checkbox}
- [ ] Confidence verified: {confidence value or 'TBD'}

## Context

{context paragraph from the interview}

**Value**: {Low/Medium/High/TBD}
**Risk**: {Low/Medium/High/TBD}
**Kill criterion**: {kill criterion or 'TBD'}

_Source: /plan-initiative on YYYY-MM-DD: see `projects/<name>/initiatives/<slug>.md` in the ops fork (or in the private portfolio sibling repo for split-portfolio v2 adopters) for the full initiative + dependency graph._
```

Use the same source-link form as `/handover` step 7.5: a plain prose path without a markdown link. The initiative document lives in the ops fork or private sibling. A relative markdown link would fail in the target repository's URL space. See AgDR-0051 § Axis 3.

File each through `tracker_create` (#670 / AgDR-0072, extended by #709). This uses **the project's** tracker: GitHub, GitLab, or a `custom` CLI. GitHub adopters still use `gh issue create`.

```bash
# Resolve + source the tracker lib ONCE, before the pass-1 loop, by walking up from cwd.
tracker_lib="$(r="$PWD"; while [ -n "$r" ] && [ "$r" != / ]; do \
  [ -f "$r/.claude/hooks/_lib-tracker.sh" ] && { echo "$r/.claude/hooks/_lib-tracker.sh"; break; }; \
  r="${r%/*}"; done)"
# shellcheck source=/dev/null
. "$tracker_lib"

# ── per milestone ────────────────────────────────────────────────────────────
body_file="$(mktemp)"
printf '%s\n' "$body" > "$body_file"
# tracker_create <owner/repo> <title> <body_file> [<labels_csv>] [<milestone>] → {"ref","url"}.
# The milestone is optional: omit it and the project's tracker.milestone default (if any) applies.
result="$(tracker_create "$repo" "[Feature] {milestone-name}" "$body_file" "enhancement,${priority:-P2}")"
rc=$?
rm -f "$body_file"
if [ "$rc" -ne 0 ] || [ -z "$result" ]; then
  : # stop pass 1: see failure handling below (rc=3 = tracker.kind=none: nothing filed)
fi
ref="$(printf '%s' "$result" | jq -r '.ref // empty')"
```

Capture the returned `ref` from `tracker_create`'s normalised `{ref,url}`. Do not parse the URL. Record `milestone_name → ref` in memory for pass 2. The map holds tracker references, including non-numeric keys such as `LIN-42`. Do not perform arithmetic on them.

On non-zero exit, stop pass 1 immediately. Follow `/task --batch` § "Failure handling" (`.claude/skills/_lib-modes/task-batch.md`). Offer Retry, Skip, Edit, or Abort. Do not reverse filed tickets on abort.

#### Pass 2: add cross-references to each filed ticket

Iterate over the just-filed set. For each filed milestone (`$issue_number` below
is the tracker `ref` recorded in pass 1's map):

> **Scope note (#709):** pass 2 reads issues with `gh issue view` and updates bodies with `gh issue edit`.
> These operations belong to the read/update axis, not creation.
> The #709 sweep changes only pass-1 creation. Body edits remain on `gh`.
> Separate work tracks read/update abstraction in #710 and the forge work.
> On non-GitHub projects, pass 1 files milestones successfully.
> Pass 2 does nothing until that follow-up work lands.

1. Compute its inbound + outbound DAG edges restricted to the also-filed set.
2. Build the cross-ref lines:
   - **Blocks**: comma list of `#N` references for filed downstream milestones
   - **Blocked by**: comma list of `#N` references for filed upstream milestones
3. Fetch the current body to handle the teammate-edit race (per AgDR-0051 § Risks):

```bash
current_body=$(gh issue view "$issue_number" --repo "$repo" --json body -q '.body')
```

4. Insert the cross-ref lines immediately after `## User Story`, before `## Acceptance Criteria`:

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

On a pass-2 failure, report the error and name the affected milestone. Continue with the rest. Do not abort pass 2. Partial cross-refs are more useful than none.

#### Remove the active-issue-skill marker on completion

```bash
marker_home="$ops_root"
. "$marker_home/.claude/hooks/_lib-session-markers.sh"
skill_marker=$(active_issue_skill_marker_path "$marker_home") || { echo "A session id is required. Restart through the harness adapter." >&2; exit 2; }
rm -f "$skill_marker"
```

Always remove the marker on success, abort, and error. The `clear-issue-skill-marker.sh` SessionStart hook removes stale markers after an interruption. A clean exit must never leave one.

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

Output: projects/<name>/initiatives/q3-auth-rewrite.md (Mermaid lint: clean)
Milestones: 5 total (3 just filed: #123, #124, #125: 2 still unfiled in the doc)

Next:
  - Refine the unfiled milestones inline in the doc, then re-run /plan-initiative q3-auth-rewrite
  - Or jump to filing-time work: /start-ticket 123 and begin Milestone 1 (the topo-sort head)
```

## Rules

1. **Slug is the only argument.** Use kebab-case with a maximum of 60 chars. If the operator passes a non-kebab form, kebab-ify and confirm before proceeding.
2. **Ask initiative-level questions ONCE on the first run.** Re-confirm with y/n on re-runs. Repeat the interview only on `n`.
3. **Use a Socratic per-milestone interview.** Require answers for name, success criterion, blocks, and blocked-by. Accept `TBD` for kill criterion, value, risk, and confidence. Record each deferral without repeating the question.
4. **One milestone at a time.** Do not ask about all milestones at once. Use the loop's `next milestone (or 'done')` prompt. Operators stop when they cannot name more milestones, rather than at a fixed count.
5. **The operator resolves DAG cycles.** Detect and print each cycle. Ask for a resolution. v1 must not break cycles automatically.
6. **Topo-sort with value × risk-inverse tie-breaks.** Numeric mapping: Low=1, Medium=2, High=3, TBD=2. Score = `value_num - (risk_num - 2)`. Insertion order is the secondary tie-break.
7. **Mermaid DAG is the rendered representation.** Renders inline on GitHub, no build step. Same convention as `/c4`, `/dfd`, `/feature-diagram`.
8. **Idempotence via filed-marker presence.** Re-runs silently skip "already filed" milestones during filing and offer "unfiled" milestones. Step 6 MUST preserve prior `Filed as [#N](url)` markers. Match names case-insensitively with normalised whitespace. Do not compare section bytes, which change after filing. This follows `/handover` Rule 18.
9. **Two-pass filing handles cross-refs.** Pass 1 files accepted milestones without cross-refs because issue numbers are unknown. Pass 2 computes cross-refs within the filed subset. It rewrites each body through `gh issue edit`. Continue after pass-2 failures because partial cross-refs are more useful than none.
10. **Source-link every filed ticket to the initiative doc.** Each Feature ticket carries the `_Source: /plan-initiative on YYYY-MM-DD : see projects/<name>/initiatives/<slug>.md in the ops fork (...)_` footer. Use a plain prose path without a markdown link. The initiative document is outside the target repository's URL space. Follow `/handover` step 7.5.
11. **Handle the active-issue-skill marker defensively.** Before the first pass-1 `tracker_create`, write `plan-initiative` to the path from `active_issue_skill_marker_path`. Remove it on success, abort, and error (AgDR-0030). Since #709/#771, command-substituted `tracker_create` calls do not trigger `require-skill-for-issue-create.sh`. The marker remains defensive for robustness and bare `gh issue create` calls at command boundaries.
12. **No bootstrap exemption is necessary.** The skill writes `*.md`, exempt from `require-active-ticket.sh`. Command-substituted `tracker_create` calls do not trigger `require-skill-for-issue-create.sh` since #709/#771. The step-8 marker remains defensive. Do not add `plan-initiative` to `ticket.bootstrap_skills`.
13. **Re-run history is append-only.** Add one row at the table's end per invocation. Do not truncate it. Long histories show active re-planning.
14. **Record rejected items in Anti-scope.** Capture interview items the operator considered and rejected in `## Anti-scope`. Follow `templates/architecture/vision.md` § Anti-scope.
15. **No auto-decomposition.** v1 deliberately does NOT take the initiative goal and emit N milestones from an LLM call. The contract requires the Socratic interview. Auto-decomposition would be a different, worse product. See AgDR-0051 § Axis 1.

## Notes

- **Cross-initiative dependencies are out of scope for v1.** If Initiative A blocks Initiative B, capture that in prose in A's `## Anti-scope` or B's `## Goal` paragraph. v2 may add cross-initiative DAG semantics. v1 handles one initiative at a time.
- **Time/effort estimation is downstream.** The skill captures `confidence` in the operator's estimate, not the estimate itself. Estimation belongs in each milestone's filed Feature ticket via `/start-ticket` + the team's normal estimation flow.
- **Resource allocation / role assignment is out of scope.** After filing, `.claude/rules/role-triggers.md` determines who handles tickets. `/plan-initiative` stops at filing.
- **Mermaid renders and lints.** The skill outputs Mermaid `flowchart LR` blocks and validates each one via step 6.5's `lint.sh` (the shared `_lib-mermaid-lint.sh`) before confirming the doc as written. Pass `--skip-lint` to bypass when `mmdc` is misbehaving.
- **PDF export via `/pdf`.** The initiative doc is markdown. For stakeholder-share work, `/pdf projects/<name>/initiatives/<slug>.md` converts to PDF via the framework's standard converter dispatch.

## Related

- [AgDR-0051](../../../docs/agdr/AgDR-0051-plan-initiative-skill.md): design rationale for this skill (Socratic vs LLM-decompose, single template, two-pass filing, filed-marker idempotence)
- [`.claude/skills/handover/SKILL.md`](../handover/SKILL.md) § 7.5: the per-item filing UX this skill mirrors (introduced #376)
- [`templates/initiative.md`](../../../templates/initiative.md): the master initiative-doc template
- [`.claude/skills/write-spec/SKILL.md`](../write-spec/SKILL.md): the per-feature PRD skill that each milestone naturally flows into after filing
- [`.claude/skills/validate-idea/SKILL.md`](../validate-idea/SKILL.md): the pre-spec gate that sometimes runs BEFORE `/plan-initiative` (when the initiative starts as a raw idea)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*
