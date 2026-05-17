---
name: tech-vision
description: Interactive section-by-section author for the architecture vision template. Interviews the operator on Scope, Principles, Target-state architecture, Current vs Target, Migration path, anti-scope ("things we explicitly chose NOT to build"), and Review cadence — then writes the assembled vision to `projects/<name>/architecture/vision.md` via the custom-templates resolver. Sibling to `/c4` (static topology) and `/dfd` (data flow) in the architecture-doc family.
argument-hint: "[project-slug | . | --framework]"
allowed-tools: Bash, Read, Grep, Glob, Write
---

# /tech-vision — Interactive Architecture Vision Author

Walks the operator through the existing `templates/architecture/vision.md` (shipped in #224) **section by section** — instead of leaving the operator staring at an empty template — so the load-bearing sections (Anti-scope, Current-vs-Target, Migration path) actually get filled in honestly rather than left as aspirational stubs.

The output is a fully populated `vision.md` ready to commit. Markdown-only — the single graphical element (target-state C4 L1) renders inline via Mermaid on GitHub. No HTML, no SVG, no build step.

> **Why `/tech-vision` and not `/vision`?** In a multi-stakeholder portfolio the word "vision" collides with product / company vision documents that Heads of Product and CEOs author in a different shape. The `tech-` prefix disambiguates this skill as the **technical / architecture** vision author. The output filename (`vision.md`) and template path (`templates/architecture/vision.md`) stay unchanged — only the slash-command carries the prefix.

Design rationale + sub-decisions: [`AgDR-0028`](../../../docs/agdr/AgDR-0028-tech-vision-skill-design.md).

| Skill | Role |
|-------|------|
| `/tech-vision` (this skill) | Authors the **target-state + migration path** — north-star architecture, prose + bulleted horizons |
| `/c4` | Static topology — current-state system + container diagrams |
| `/dfd` | Data flow — trust boundaries + data classifications (input to `/threat-model`) |
| `/sequence` (template) | Request-flow walkthroughs (auth handshake, payment flow) |

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the template path via `portfolio_resolve_template` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
projects_dir=$(portfolio_projects_dir)
template=$(portfolio_resolve_template architecture/vision.md)
```

Defaults match today's single-fork layout (`./projects`, `./templates/architecture/vision.md`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir}` keys in `.claude/project-config.json` and may drop a custom template at `<private_repo>/custom-templates/architecture/vision.md` — the helper resolves whichever mode they're in. See `docs/multi-project.md` and `templates/README.md` (custom-templates layer).

## Usage

```
/tech-vision                       # interactive — asks which project (or framework-wide)
/tech-vision billing-api           # registered project — writes to projects/billing-api/architecture/vision.md
/tech-vision .                     # treat cwd as the project root
/tech-vision --framework           # framework-wide vision — writes to docs/architecture/vision.md
```

Re-running on an existing `vision.md` OFFERS (default-no) to overwrite — same UX as `/c4`, `/extract-features`, `/dfd`. Accept-no preserves the existing file; accept-yes seeds each section's prompt with the existing content as the default, so the operator can refresh a single section without rewriting the whole vision.

## Output location

Where the file lands depends on **where the skill is invoked from** and **what argument is passed** — same split as `/c4`:

| Invoked from | Arg | Output |
|---|---|---|
| Ops fork root | `<name>` (registered project) | `projects/<name>/architecture/vision.md` |
| Ops fork root | `--framework` | `docs/architecture/vision.md` |
| `workspace/<name>/` (project clone) | none | `projects/<name>/architecture/vision.md` (resolved via the ops fork — vision is the ops-fork view of where the project's architecture is going) |
| Anywhere | `.` | Treat cwd as the project; write to `docs/architecture/vision.md` inside the cwd |

The split mirrors the existing convention from `docs/multi-project.md` § "Architecture diagrams".

## Process

### 1. Resolve the target + load the template

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"

template=$(portfolio_resolve_template architecture/vision.md)
if [ -z "$template" ] || [ ! -f "$template" ]; then
  echo "BLOCKED: cannot resolve architecture/vision.md template" >&2
  exit 1
fi

# Resolve the project + output path per the table above:
# - If --framework: out=<ops_root>/docs/architecture/vision.md
# - Else if arg is .: out=<cwd>/docs/architecture/vision.md
# - Else if arg is a registered project name: out=<projects_dir>/<name>/architecture/vision.md
# - Else if no arg + cwd inside workspace/<name>/: derive <name>, same as above
# - Else (no arg + cwd is ops fork root): ask the user
```

If the resolved output file already exists:

```
projects/<name>/architecture/vision.md already exists (last written {date}).

  (k) keep existing — exit without changes
  (o) overwrite — start a fresh interview
  (r) refresh — start the interview with existing content as defaults (recommended for quarterly review)

> 
```

On `k`: exit. On `o`: ignore existing content, proceed to step 2 with empty defaults. On `r`: parse existing file's sections, use each section's content as the default during the interview.

### 2. Read the template structure

Parse the resolved template (`portfolio_resolve_template architecture/vision.md`) to discover its sections. The framework default has seven, in order:

| # | Section | Interview shape |
|---|---------|-----------------|
| 1 | Scope | Single one-sentence answer |
| 2 | Principles | Repeated prompt: "principle N (or `done`)" — 5–10 items, skill suggests stopping at 5 unless operator has strong reason for more |
| 3 | Target-state architecture | Multi-line: paste Mermaid C4 L1, OR accept template's placeholder, OR ask operator to run `/c4 <project> --level=1` first and paste the output |
| 4 | Current state vs target state | Repeated row prompt: dimension / today / target / gap — 4–8 rows, skill suggests dimensions (Data layer, Auth, Deployment, Observability, Async messaging, Frontend, Secrets management) from the template's worked example as starters |
| 5 | Migration path | Repeated row prompt: quarter / milestone / owner / "done when" — 3–5 milestones |
| 6 | Things we explicitly chose NOT to build (anti-scope) | Repeated prompt: anti-scope item + rationale + "reconsider when" trigger — at least 2 required, skill emphasises this is the load-bearing section |
| 7 | Review cadence | Default `quarterly`, operator can override (single answer) |

If the operator has overridden the template at `<private_repo>/custom-templates/architecture/vision.md`, the skill reads that file's sections instead. The interview follows whatever sections the resolved template defines — the section list is not hardcoded.

**Discovery**: walk the template's `^##` headings in order; each heading is one interview section. Use the heading text verbatim in the prompts.

### 3. Run the interview — section by section, per-section confirm

For each section:

1. **Show the section heading** and a one-line context (extracted from the template's section intro paragraph, trimmed to one line).
2. **Prompt for the section's content**. The prompt shape depends on whether the section is single-answer, multi-line, or repeated-row (per the table above). For sections with worked examples in the template, surface 1–2 examples as starting suggestions — never as the answer.
3. **Show the assembled section** as it will appear in the final file.
4. **Confirm**:

   ```
   Section "Principles" — looks good?
     (y) accept and continue to next section
     (e) edit — restart this section
     (s) skip — leave section as template default (NOT recommended for Anti-scope or Migration path)
     (q) quit — don't write anything
   > 
   ```

If the operator picks `s` on **Anti-scope or Migration path**, re-prompt with a stronger warning:

```
Anti-scope is the load-bearing section that prevents the vision from rotting
into aspirational filler. Skipping it produces a half-filled-in stub of the
exact kind /tech-vision exists to prevent.

Really skip? [y/N]
```

Default `N`. Other sections can be skipped without warning (Scope, Principles, Review cadence have sane template defaults).

### 4. Show the assembled doc + final confirm

After all sections, show the fully assembled vision as it will be written. Final prompt:

```
Vision assembled — {N} sections, {M} principles, {K} anti-scope items, {Q} migration milestones.

  (y) write to <output-path>
  (e) restart at section: 1 / 2 / 3 / 4 / 5 / 6 / 7  → re-prompt for that section
  (q) quit — don't write
> 
```

### 5. Write the file + lint the Mermaid

Write the assembled markdown to the resolved output path. The Target-state section may contain a `` ```mermaid `` C4 L1 block (pasted by the operator or generated via `/c4`). Validate every Mermaid block in the file via the shared lint:

```bash
SKILL_DIR="$(dirname "$(realpath "$0")")"
"$SKILL_DIR/lint.sh" "$vision_out" || lint_rc=$?
```

Wraps `_lib-mermaid-lint.sh` — graceful-degrades when Node / npx is unavailable (exit 3, advisory only). Exit 1 (parse error) → ask the operator whether to fix the Target-state block by hand or re-run with `--skip-lint`. Exit 3 → one-line warning, proceed.

End the file with the apexyard-skill footer convention (same as `/c4`, `/dfd`, `/extract-features`):

```markdown
---

_Generated by `/tech-vision` on YYYY-MM-DD. Re-run quarterly (or after a significant architecture decision) — `/tech-vision <project>` with the `r` (refresh) option preserves the existing content as defaults._
```

Print a one-line summary:

```
✓ Vision written: projects/<name>/architecture/vision.md
  Sections: 7 · Principles: 5 · Anti-scope: 3 · Migration milestones: 4
  Reviewed quarterly per § "Review cadence" — next review: {Q+1}
```

### 6. Suggest follow-ups

Surface the natural next-steps the operator likely wants:

- **C4 current-state diagrams** — if no `projects/<name>/architecture/{context,container}.md` exists, suggest `/c4 <project>` to capture the as-is system topology (the vision's Target-state section describes where we're going; `/c4` documents where we are today).
- **Migration ticket** for the Q1 milestone — `/migration` if it touches schema, `/feature` otherwise.
- **AgDRs** for any technical decisions implied by the migration path — `/decide` for each.
- **Quarterly review reminder** — surface the cadence so the operator knows to re-run `/tech-vision <project>` (refresh mode) in 3 months.

## Rules

1. **Operator authors the content; the skill structures the prompts.** Never fill in section bodies on the operator's behalf — the worked examples in the template are starting suggestions, not auto-accepted answers.
2. **Never auto-overwrite** — existing `vision.md` requires explicit `o` or `r`. The file may have been hand-edited; clobbering silently is the worst-case failure.
3. **Per-section confirm is mandatory** — the operator iterates one section at a time, not by re-running the whole interview.
4. **Anti-scope cannot be skipped silently** — the second-warning prompt is the load-bearing UX that turns the "stub vision" failure mode into a deliberate decision.
5. **Follow the resolved template's section list** — do not hardcode the framework default's seven sections. An adopter with a custom template (5 sections, 9 sections) gets an interview that matches their template.
6. **Footer signature is mandatory** — every generated file ends with the `Generated by /tech-vision on YYYY-MM-DD` line so future readers know how to refresh it.
7. **Markdown-only output** — no HTML, no SVG, no JSON sidecar. The vision IS the source of truth.
8. **Refuse if no template resolves** — `portfolio_resolve_template` returning empty means the framework default is missing too; stop with a clear error rather than producing an empty file.

## When to use this

| Trigger | Use `/tech-vision`? |
|---------|----------------|
| Quarterly architecture review for a registered project | Yes — re-run with `r` (refresh) to preserve last quarter's content as defaults |
| New project just adopted via `/handover`; need to set north-star architecture | Yes — fresh run, all 7 sections from scratch |
| Tech Lead onboarding wants to see "what's the target state" | Read the existing `projects/<name>/architecture/vision.md` — the skill produced it for exactly this reader |
| Drawing a current-state container diagram | No — use `/c4` |
| Drawing a data-flow diagram | No — use `/dfd` |
| Recording a single technical decision (library choice, framework upgrade) | No — use `/decide` (writes an AgDR, much narrower scope) |
| Multi-team vision (one team's vision feeds another's) | No — out of scope for v1; one vision per system / domain |
| Product / company vision (audience, market, business goals) | No — `/tech-vision` is the **technical / architecture** vision; product vision belongs in a separate PRD / strategy doc |

## Anti-patterns

- **Don't auto-generate vision content from a problem statement** — the model doesn't have the operator's architecture context. The skill structures the interview; the operator authors the answers.
- **Don't chain `/c4` automatically from inside `/tech-vision`** (v1 scope). `/c4` produces a *current-state* diagram; the vision's Target-state section is by definition NOT today's code. Suggest `/c4` as a follow-up if no current-state diagram exists; let the operator paste a target-state Mermaid block inline.
- **Don't ship without an Anti-scope section.** The skill enforces this via the second-warning prompt; the rationale section in the output documents WHY each item was declined and WHEN to reconsider — without those the section is filler.
- **Don't treat the vision as a once-and-done artefact.** The template includes a Review cadence (default quarterly). Re-run with `r` (refresh) at each review; preserve content for unchanged sections, update the rest.

## Out of scope (v1)

- **Chaining `/c4`** to scaffold the target-state diagram — accept inline Mermaid in v1; chain in a v1.x follow-up if operators ask.
- **HTML / SVG / interactive rendering** — markdown-only by design.
- **A `/tech-vision-review` companion** that re-prompts every section quarterly — the idempotent refresh mode handles this.
- **Vision enforcement** (Rex checking whether new code matches the vision) — that's a `/decide` + AgDR concern, not a vision-doc one.
- **Multi-team vision composition** — one vision per system / domain.
- **Vision-doc trend tracking** across quarterly reviews — use `git log projects/<name>/architecture/vision.md` and the AgDR history instead.
