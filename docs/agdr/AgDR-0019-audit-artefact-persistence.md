# AgDR-0019 — Audit-skill artefact persistence: schema shape, lib API, launch-check backward-compat

> In the context of generalising `/launch-check`'s persistence convention to the other nine audit skills (#218), facing four load-bearing choices (single vs paired artefact files, findings-shape rigidity, path-segment for launch-check, and lib-API surface), I decided **paired JSON+MD artefacts (preserving launch-check's existing pair pattern), a rigid common-denominator findings shape with per-dimension extension via the MD body, a new `audits/<dim>/` path root with launch-check's existing `launch-check/` path preserved (read-merged not migrated), and a four-function bash lib (`audit_resolve_dir` / `audit_run_persist` / `audit_run_list` / `audit_render_trend`)**, to achieve consistent on-disk structure across all nine audit dimensions without breaking launch-check's existing trend-history adopters, accepting that the rigid findings shape pushes per-dimension nuance into the MD body and the dual-path read for launch-check adds one branch to the trend reader.

## Context

[me2resh/apexyard#218](https://github.com/me2resh/apexyard/issues/218) asks for canonical structure + persistence for the audit-skill family so trend rendering becomes possible across `/threat-model`, `/security-review`, `/compliance-check`, `/accessibility-audit`, `/performance-audit`, `/seo-audit`, `/monitoring-audit`, `/docs-audit`, and `/analytics-audit` — currently only `/launch-check` persists. The technical design lives at [`docs/technical-designs/audit-artefact-persistence.md`](../technical-designs/audit-artefact-persistence.md).

Four decisions in the design needed an explicit airing because each has a viable alternative that would shape adoption differently. None are recoverable for free once shipped.

## Options Considered

### A. Single artefact file (MD-with-frontmatter) vs paired JSON+MD

| Option | Pros | Cons |
|---|---|---|
| **Paired JSON + MD** (chosen) | Matches `/launch-check`'s existing pattern (`runs/*.json` + per-run `<ts>.md`) — zero behaviour change for that skill. JSON is parser-friendly for trend renderers, dashboards, and ad-hoc `jq` queries; MD is the human artefact. Each format is good at exactly one job. | Two files per run instead of one. Slight duplication risk if frontmatter and JSON drift (mitigated by writing both from a single in-memory representation in `audit_run_persist`). |
| Single MD-with-frontmatter | One file per run. Frontmatter (YAML) is parseable. AgDRs and PRDs already use this shape — pattern is familiar. | `/launch-check` would need to migrate its existing JSON history — destructive op for adopters with committed run history. YAML frontmatter is awkward to query with `jq`-class tools; needs a YAML parser. Trend renderer becomes file-grep-and-extract instead of clean JSON load. |
| Single JSON-with-prose | Machine-friendly. | Operators who edit artefacts by hand (adding context to a finding) get JSON-string-escaped prose. Awful UX. |

### B. Findings shape: rigid common denominator vs per-dimension extensible schema

| Option | Pros | Cons |
|---|---|---|
| **Rigid common denominator** `{id, severity, status, summary}` (chosen) | Trend renderer can compare runs across all nine dimensions with one code path. Frontmatter stays small and parseable. Per-dimension extras live in the MD body where they belong. | Some per-dimension nuance (STRIDE category, OWASP class, WCAG criterion) doesn't fit the common shape and has to live in the body — slightly worse for programmatic per-category queries. |
| Per-dimension extensible (each dim adds its own fields) | Captures everything programmatically. | Trend renderer needs per-dim adapters (9 paths). The "common" structure becomes an empty interface. Adopters writing dashboards face a fragmented schema. |
| Hybrid (common required fields + a `dim_specific: {}` dict) | Best of both, in theory. | In practice the dict becomes a junk drawer. Dashboards still need per-dim awareness to read it; common-denominator queries get cluttered with `if dim_specific.X` checks. |

### C. Launch-check backward compatibility: migrate paths or read both

| Option | Pros | Cons |
|---|---|---|
| **Read both paths, write only to new** (chosen) | Zero destruction of adopters' existing `projects/<name>/launch-check/runs/` history. New runs land in the canonical `audits/launch-check/` tree. Trend reader merges chronologically. Adopters can manually `mv` the old dir to consolidate when ready. | Trend reader has one extra branch (try old path, try new path, merge). Two-tree state for adopters who never migrate manually. |
| Migrate on first new write | Single-tree state for everyone going forward. | First post-upgrade `/launch-check` run becomes destructive (file moves). Risk of mid-migration crash leaving a half-moved tree. Operators who had `git`-tracked their launch-check history get noisy diffs. |
| Leave launch-check's path alone, only generalise for the new dimensions | Zero risk for launch-check. | Inconsistency forever — `audits/threat-model/` next to `launch-check/` on the same project. Defeats the "canonical structure" half of the ticket title. |

### D. Lib API surface: four functions vs one omnibus

| Option | Pros | Cons |
|---|---|---|
| **Four discrete functions** (chosen): `audit_resolve_dir`, `audit_run_persist`, `audit_run_list`, `audit_render_trend` | Each has one job; each is testable in isolation. Skills only call what they need (e.g. trend-only mode skips `_persist`). Mirrors the `_lib-portfolio-paths.sh` / `_lib-read-config.sh` shape adopters already know. | Four functions to learn instead of one. |
| One omnibus `audit_run` with subcommands (`audit_run persist …`, `audit_run trend …`) | Single entry point. Looks like `git`. | Bash subcommand dispatch is awkward; arg parsing duplicates work. Tests harder to scope. Doesn't match the existing lib conventions in `.claude/hooks/`. |
| Skip the lib, copy-paste persistence into each skill | Zero coupling; each skill controls its own destiny. | Defeats the whole ticket. Drift across nine skills is exactly what the ticket is preventing. |

## Decision

Chosen — for all four:

**A.** Paired JSON + MD per run (preserves `/launch-check` exactly).
**B.** Rigid common-denominator `findings[]` shape; per-dimension extras in the MD body via per-dim templates.
**C.** Read launch-check's old + new paths, write only to new — no destructive migration.
**D.** Four-function shell lib at `.claude/hooks/_lib-audit-history.sh`.

Why this combination:

1. **Pair preserves launch-check** — the existing JSON history of every adopter on `/launch-check` keeps working with zero migration. The change is additive: future runs land in the canonical tree; old runs are still readable.
2. **Rigid findings shape keeps the trend renderer simple** — one code path across all nine dimensions. The MD body is the right place for per-dimension nuance because operators read those by hand; the structured layer only needs what the trend cares about.
3. **Dual-path read is one extra branch in one function** — `audit_run_list` checks both `projects/<name>/audits/launch-check/runs/*.json` and `projects/<name>/launch-check/runs/*.json` for that one dimension. ~5 lines of bash. Cheap insurance against orphaning adopter history.
4. **Four discrete functions** match the existing `_lib-*.sh` shape — adopters reading the source recognise the pattern from `_lib-portfolio-paths.sh`. Onboarding cost ≈ zero.

## Consequences

- The `/launch-check` skill keeps its four-state vocabulary (`go` / `go-with-warnings` / `conditional-go` / `no-go`) in its own stdout and MD body, but its frontmatter `verdict` field maps to the generic three-state (`pass` / `conditional` / `fail`) so trend comparisons across mixed-dimension data are coherent.
- Adopters with committed `projects/<name>/launch-check/.launch-check-history-tracked` markers get a follow-up choice on first post-upgrade run: keep the old marker (works for old path) and add `projects/<name>/audits/launch-check/.audit-history-tracked` (works for new path), or run the manual `mv` consolidation. Documented in launch-check's SKILL.md upgrade note.
- Per-dimension templates at `templates/audits/<dim>.md` are *reference material*, not auto-loaded by the skill. Each retrofitted skill embeds the body shape it produces inline; the template is a copy-paste starting point for adopters writing new audit-class skills (or for the seven follow-up retrofits).
- Schema versioning is explicit (`schema_version: 1` in both JSON and MD frontmatter). v2 won't ship until there's a forcing function; the renderer dispatches per version with v1 as the fallback reader.
- Cross-project audit aggregation (a portfolio-wide "every audit's latest verdict") becomes trivially possible — walk the registry, glob `projects/*/audits/*/<latest>.json`, render. Out of scope for #218; this AgDR records that the chosen shape doesn't block it.
- The follow-up ticket retrofitting the remaining seven dimensions (`/compliance-check`, `/accessibility-audit`, `/performance-audit`, `/seo-audit`, `/monitoring-audit`, `/docs-audit`, `/analytics-audit`) is mechanical: drop in the same `audit_run_persist` call, write a per-dim template, done. Each takes ~30 minutes once the lib + pilots are in place.

## Artifacts

- Ticket: [me2resh/apexyard#218](https://github.com/me2resh/apexyard/issues/218)
- Technical design: [`docs/technical-designs/audit-artefact-persistence.md`](../technical-designs/audit-artefact-persistence.md)
- Prior-art AgDR: [`AgDR-0014 — /launch-check trend tracking`](AgDR-0014-launch-check-trend-tracking.md)
- Existing skill (model for the convention): `.claude/skills/launch-check/SKILL.md` + `render-trend.sh`
