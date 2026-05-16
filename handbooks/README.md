# Handbooks — adopter coding standards consumed by Rex

Handbooks are markdown files containing **company-specific coding standards** that the Code Reviewer agent (Rex) consults during PR review, alongside the framework's generic rules in `.claude/rules/`. Adopters customise this directory; the framework ships a small set of opinionated samples to demonstrate the convention.

This is the place to encode the rules your team would otherwise enforce by Slack message, by lore, or by ad-hoc PR comments — *but only the ones that are stable enough to write down once and apply forever*.

Decision rationale: [`docs/agdr/AgDR-0020-adopter-handbooks-for-rex.md`](../docs/agdr/AgDR-0020-adopter-handbooks-for-rex.md).

> **Two layers, same convention.** This `handbooks/` tree lives in the public ops fork — handbooks here are safe to publish on a public framework fork. Split-portfolio adopters who want company-confidential handbooks (naming internal systems, referring to proprietary policy, etc.) can additionally drop them at `<private_repo>/custom-handbooks/{architecture,general,language/<lang>}/*.md`. Rex discovers both layers using the **same path-convention** described below and applies findings from both. Resolution helper: `portfolio_custom_handbooks_dir` in `.claude/hooks/_lib-portfolio-paths.sh`. Setup pointer: `docs/multi-project.md` § "Private custom skills + handbooks". Single-fork adopters typically only use this `handbooks/` tree.

## Discovery

Rex finds handbooks by **path convention** — there is no YAML frontmatter, no `applies_to:` glob to maintain. The directory IS the targeting metadata.

| Path | When Rex loads it |
|---|---|
| `handbooks/architecture/*.md` | **Always** — architecture standards apply to every PR |
| `handbooks/general/*.md` | **Always** — cross-cutting rules (commit messages, comment density, naming) apply to every PR |
| `handbooks/language/<lang>/*.md` | **On diff match** — only when the PR touches files of that language. `<lang>` matches by extension: `typescript/` → `**/*.{ts,tsx}`, `python/` → `**/*.py`, `go/` → `**/*.go`, `rust/` → `**/*.rs`, etc. |

If you need a fourth bucket, add the directory and update Rex's discovery logic in `.claude/agents/code-reviewer.md`. The path convention is open — Rex falls back to "always-load" for any directory it doesn't have specific rules for.

## File format

Flat markdown. No YAML frontmatter required. Rex reads the file as prose during review and applies the rules conversationally.

The recommended shape (mirrored across the four samples shipped with the framework):

```markdown
# Handbook: <Title>

**Scope:** <which PRs this applies to, derived from the directory>
**Enforcement:** advisory  (or: blocking — see below)

## The rule

<the rule in concrete, actionable language. Tables, bullet lists, and
code snippets are fine. Aim for ≤ 50 lines per handbook — one rule
cluster per file. Split into multiple files if a topic grows beyond
that.>

## Why

<the load-bearing rationale. What problem does this rule prevent?
What's the failure mode if it's ignored? Future-readers need to know
why before they decide to keep / amend / drop it.>

## What Rex flags

<concrete patterns Rex looks for in the diff. Be specific about file
paths, code patterns, and signal phrases. Vague rules generate vague
findings.>

## Sample finding

<an example of how Rex should phrase the finding in a review comment.
Format-by-example is the cheapest way to keep findings consistent.>

## What's NOT a violation

<the false-positive list. As load-bearing as the rule itself —
without it, Rex over-reports and adopters tune him out.>
```

Other shapes are fine — Rex reads as prose. The shape above just keeps the four samples consistent.

## Enforcement: advisory vs blocking

**Default: advisory.** Rex surfaces the finding as a `nit:` / `suggestion:` comment in the review. The PR can still merge if other gates pass.

**Opt in to blocking** by adding the literal phrase `ENFORCEMENT: blocking` at the **top of the file**, before any markdown content. Example:

```markdown
ENFORCEMENT: blocking

# Handbook: Migration Safety

...
```

When a blocking handbook is violated, Rex's overall review verdict becomes `request-changes` — the merge gate (Rex marker absent) blocks the PR until the violation is resolved or the handbook is amended via a separate PR.

**Pick blocking sparingly.** A handbook that day-1 blocks every PR generates ratio'd revolts and eventually gets removed. Use blocking for rules where a violation has *material* downstream cost — data loss, security incident, irreversible production outage. Everything else is advisory.

## Authoring conventions

1. **One rule cluster per file.** A handbook on "TypeScript" is too broad; split into "strict-mode", "naming", "error-handling". Smaller files keep Rex's per-PR token cost bounded.
2. **Be specific about the trigger.** "Use good types" is unenforceable. "`function fetchUser(id: any)` should declare `id: string` or `id: UserId`" is enforceable.
3. **Include the false-positive list.** Every "What Rex flags" section should be paired with a "What's NOT a violation" section. Without it, Rex over-flags and operators tune the layer out.
4. **Reference framework rules by `@.claude/rules/<file>.md` path** when a handbook extends or refines a generic framework rule. Don't duplicate; link.
5. **Reference AgDRs** when a rule has a documented decision rationale. The handbook is the rule; the AgDR is the why.

## Adding a new handbook

```bash
# Copy the shape of an existing sample
cp handbooks/architecture/clean-architecture-layers.md handbooks/architecture/<your-new-rule>.md
$EDITOR handbooks/architecture/<your-new-rule>.md

# Commit alongside whatever PR introduced the need
git add handbooks/architecture/<your-new-rule>.md
git commit -m "docs(#NN): handbook on <your-new-rule>"
```

No skill scaffolding — handbook authoring is intentionally raw markdown editing in v1. If authoring friction shows up, file a ticket for a `/handbook` skill.

## Out of scope (v1)

- **Per-project handbooks** layered over framework handbooks. v1 is framework-level only — handbooks travel with the ops fork and apply to all managed projects. File a follow-up if your team needs project-specific handbooks.
- **`/handbook` authoring skill.** Manual `cp` + edit is fine for v1.
- **Handbook conflict resolution between framework rules and handbooks.** Defer until a real conflict surfaces; in v1 the framework rule wins.
- **Cross-project handbook aggregation / dashboard.** Out of scope.

## The four samples shipped with the framework

| Path | Type | Enforcement | Rationale |
|---|---|---|---|
| `architecture/clean-architecture-layers.md` | Always-load architectural | Advisory | DDD layering — domain has no external deps; application doesn't import infrastructure |
| `architecture/migration-safety.md` | Always-load architectural | **Blocking** | Schema migrations must be backwards-compatible for one release — production rollout safety |
| `language/typescript/strict-mode.md` | Diff-matched language | Advisory | TS strict mode required; no bare `any` without justification |
| `general/commit-message-quality.md` | Always-load cross-cutting | Advisory | Commits explain WHY, not WHAT — reduces future archaeology cost |

Adopters can keep, edit, or replace any of these. They're not load-bearing for the framework — just demonstrative of the convention.
