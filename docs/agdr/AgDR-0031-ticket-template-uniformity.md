---
id: AgDR-0031
timestamp: 2026-05-19T00:00:00Z
agent: claude
model: claude-opus-4-7
trigger: user-prompt
status: accepted
ticket: me2resh/apexyard#281
---

# Ticket-template uniformity: every ticket-creating skill reads its body from `templates/tickets/<name>.md`

> In the context of adopters dropping `<private_repo>/custom-templates/feature.md` (or similar) and seeing the override silently fail because the framework had no template file at the mirrored path, facing the choice between (a) documenting the limitation, (b) re-implementing the path-mirroring contract per skill, or (c) extracting the issue body of every ticket skill into a uniform `templates/tickets/<name>.md` location, I decided to ship option (c) — moving the existing `templates/{spike,investigation}.md` into `templates/tickets/` and adding 5 missing files (`feature.md`, `bug.md`, `task.md`, `migration.md`, `idea.md`) plus refactoring all 7 SKILL.md files to resolve via `portfolio_resolve_template tickets/<name>.md` with a heredoc fallback — to achieve "drop a file at the mirrored path and it wins, for every ticket type", accepting that we now ship 7 template files where 2 existed before and adopters with `custom-templates/spike.md` / `custom-templates/investigation.md` overrides on the old top-level path need a one-time migration (handled by `/update`).

## Context

- AgDR-0023 (#244) established path-mirroring discovery + full-replacement override semantics for templates. The resolver lives at `portfolio_resolve_template <relative_path>` in `.claude/hooks/_lib-portfolio-paths.sh`.
- The contract worked for `/decide`, `/write-spec`, `/c4`, `/handover`, `/migration` (AgDR side), `/spike`, and `/investigation` — every skill that read a real template file.
- It silently failed for the 5 older ticket-creating skills (`/feature`, `/bug`, `/task`, `/migration` ticket-body side, `/idea`) because they constructed their issue body **inline via heredoc** — no template file existed for an adopter override to win over.
- The leak is invisible from the adopter's perspective: a `custom-templates/feature.md` is well-formed, lands at a path the README documents, and… does nothing. No error, no warning, no fallback. Just the framework's hardcoded heredoc body, unchanged.
- Two existing template files (`templates/spike.md`, `templates/investigation.md`) lived at the *top level* of `templates/`, mixing with non-ticket templates (PRD, AgDR, C4). A new `templates/tickets/` subdir gives the 7 ticket types a single home and a consistent path shape.

## Options Considered

### Option dimension 1 — where to put the new template files

| Option | Pros | Cons |
|--------|------|------|
| **`templates/tickets/<name>.md` (chosen)** | Single home for ticket-body templates; consistent path shape (`tickets/feature.md`, `tickets/bug.md`, …); discoverable via `ls templates/tickets/`; the existing 2 templates move in, the 5 missing ones fill in cleanly | Existing adopter overrides under `custom-templates/spike.md` / `custom-templates/investigation.md` need a one-time path migration |
| **Top-level `templates/<name>.md`** — same as the existing spike/investigation layout | No move needed for spike/investigation overrides | Mixes ticket templates with non-ticket templates (PRD, AgDR, C4); `templates/` becomes a flat 12-file dir; no semantic grouping |
| **Per-skill subdir, e.g. `templates/feature/ticket-body.md`** | Each skill owns a sub-tree | 7 new dirs for 7 one-file payloads; over-engineered |

`templates/tickets/<name>.md` won because it groups the right things together (ticket bodies live next to each other), separates them cleanly from non-ticket templates, and produces a consistent shape (`tickets/<name>.md`) that's easy to remember and easy to extend.

### Option dimension 2 — refactor scope

| Option | Pros | Cons |
|--------|------|------|
| **All 7 ticket skills (chosen)** — Pattern A (heredoc-only) for 5 of them; Pattern B (template file) for 2 — collapse to Pattern B uniformly | One pattern across all 7; the same `portfolio_resolve_template` call shape works for every ticket-creating skill; adopter mental model is "the override lives at the mirrored path"; no skill has a "it's different for this one" exception | Mid-PR change to 7 SKILL.md files |
| **Only the 5 missing ones (additive)** | Smaller diff | Two patterns coexist — A for spike/investigation, B for the others — adopter still has to learn "this one uses the resolver, that one doesn't"; eventual consolidation still needed |
| **None — document the heredoc-only skills as override-unfriendly** | Smallest diff | Adopters keep dropping `custom-templates/feature.md` and being surprised it doesn't work; the path-mirroring contract has a 5-out-of-7 hole |

All 7 won because the bug is the *inconsistency*, not the missing files. Half-fixing it preserves the inconsistency.

### Option dimension 3 — backward-compat fallback

| Option | Pros | Cons |
|--------|------|------|
| **Heredoc fallback when template is missing (chosen)** — if `portfolio_resolve_template tickets/<name>.md` returns empty, the SKILL.md falls back to its pre-#281 inline body and prints a WARN on stderr | Partial adopter setups (e.g. someone who pulled the SKILL.md changes via cherry-pick without the new templates) keep working; the WARN surfaces the issue so it's not silent | Slightly more SKILL.md text; the fallback inline body has to stay in sync with the new template file (low risk: the inline shape is the source the template was extracted from) |
| **Hard fail on missing template** | Forces adopters to upgrade fully; no drift between SKILL.md and template | Partial cherry-picks become broken installations; first-time users of a fresh checkout where templates somehow didn't land get a confusing failure |

Heredoc fallback won because the framework cares more about "no surprise breakage on partial upgrades" than about "force the upgrade". The WARN ensures the fallback is visible, not silent.

### Option dimension 4 — `templates/{spike,investigation}.md` → `templates/tickets/{spike,investigation}.md` move

| Option | Pros | Cons |
|--------|------|------|
| **Move (chosen)** | Uniform shape: all 7 ticket templates under `templates/tickets/`; SKILL.md path arguments are uniform (`tickets/<name>.md`); easy to grep | Adopters with `custom-templates/spike.md` / `custom-templates/investigation.md` (top-level path) need to move their override to `custom-templates/tickets/spike.md` / `custom-templates/tickets/investigation.md` |
| **Leave at top level; add the new 5 under `templates/tickets/`** | No move needed for existing overrides | Two different argument shapes — `portfolio_resolve_template spike.md` vs `portfolio_resolve_template tickets/feature.md` — coexist forever |

Move won because the uniformity payoff outweighs the one-time migration cost. The migration step is documented under the `/update` skill's existing deprecated-path advisory pattern.

## Decision

Chosen: **`templates/tickets/<name>.md` for all 7 ticket types + Pattern A → Pattern B refactor across all 7 SKILL.md files + heredoc fallback with WARN-on-stderr when the template file is missing**.

Per-skill resolution call:

```bash
template=$(portfolio_resolve_template tickets/<name>.md)
# /feature       → tickets/feature.md
# /bug           → tickets/bug.md
# /task          → tickets/task.md
# /migration     → tickets/migration.md   (ticket body; agdr-migration.md still resolves separately for the AgDR)
# /idea          → tickets/idea.md
# /spike         → tickets/spike.md       (moved from templates/spike.md)
# /investigation → tickets/investigation.md (moved from templates/investigation.md)
```

Resolution order (unchanged from AgDR-0023):

1. `<private_repo>/custom-templates/tickets/<name>.md` — adopter override
2. `<ops_root>/templates/tickets/<name>.md` — framework default
3. Empty + nonzero exit → SKILL.md falls back to its inline heredoc body and prints a WARN on stderr

Updated consuming skills: `/feature`, `/bug`, `/task`, `/migration`, `/idea`, `/spike`, `/investigation`.

The `.ticket.required_sections` schema in `.claude/project-config.defaults.json` is **unchanged** — `validate-issue-structure.sh` still reads section names from the config, not from the template. The template controls the issue body's shape; the config controls what sections are mandatory. They overlap by design but stay independently editable.

## Consequences

- Adopters can override any ticket body shape by dropping a file at `<private_repo>/custom-templates/tickets/<name>.md`. The path-mirroring contract from AgDR-0023 now applies uniformly to all 7 ticket types.
- Existing adopters with `custom-templates/spike.md` or `custom-templates/investigation.md` (top-level path) need to move their file to `custom-templates/tickets/spike.md` / `custom-templates/tickets/investigation.md`. `/update` detects the old path at sync time and offers (default-yes) to move it.
- The framework ships 5 new template files (`feature.md`, `bug.md`, `task.md`, `migration.md`, `idea.md`) under `templates/tickets/`. They reproduce the previously-inline heredoc shape from each SKILL.md, plus a Glossary placeholder section to encourage the PR-quality glossary discipline already enforced on PR bodies.
- The 5 older SKILL.md files (`/feature`, `/bug`, `/task`, `/migration`, `/idea`) gain a new resolver step and a fallback warning, but the interactive interview flow is unchanged — adopters who never customise see no behaviour change.
- Partial adopter setups (cherry-picked SKILL.md without templates, or vice-versa) keep working via the heredoc fallback; the WARN-on-stderr makes the drift visible.
- AgDR-0017 (spike) and AgDR-0027 (investigation) reference `templates/spike.md` and `templates/investigation.md` in their Artifacts sections. Those are historical records of the artefact paths at decision time — they stay as-is; the current paths are documented in `templates/README.md` and `CLAUDE.md`.
- The `custom-templates/` README example file and the `docs/multi-project.md` tree diagram are updated to show the new `tickets/` subdir.

## Artifacts

- PR for me2resh/apexyard#281
- New ticket templates: `templates/tickets/feature.md`, `templates/tickets/bug.md`, `templates/tickets/task.md`, `templates/tickets/migration.md`, `templates/tickets/idea.md`
- Moved templates: `templates/spike.md` → `templates/tickets/spike.md`; `templates/investigation.md` → `templates/tickets/investigation.md`
- Refactored skills: `.claude/skills/{feature,bug,task,migration,idea,spike,investigation}/SKILL.md`
- New tests: `.claude/hooks/tests/test_ticket_template_resolution.sh` (36 cases covering default-resolution, custom-templates override, split-portfolio sibling override, heredoc fallback, and mixed-override scenarios across all 7 ticket types)
- Updated docs: `templates/README.md`, `templates/custom-templates.README.example.md`, `docs/multi-project.md` § "Custom templates", `CLAUDE.md` § "Templates"
- Out of scope (separate ticket): the `/update` migration step that detects `custom-templates/{spike,investigation}.md` (old top-level path) and offers to move them to `custom-templates/tickets/<name>.md` — couples with the existing update-chain ticket.
