# PR Quality Requirements

## Glossary (MANDATORY)

Every PR description **must** include a Glossary section:

```markdown
## Glossary
| Term | Definition |
|------|------------|
| ... | ... |
```

If missing → the Code Reviewer agent requests changes. No exceptions.

**Why a glossary?** Every PR is a learning opportunity. Explaining terms helps junior engineers learn from senior work, helps senior engineers articulate their thinking, helps future readers understand decisions, and builds shared vocabulary across the team.

## Summary bullets — narrative quality (MANDATORY)

Every bullet in the `## Summary` section **must** answer two questions: **what changed** AND **why it matters to the person reading this**. Label-only bullets (terse noun phrases naming the area that changed, without the *why* or the consequence) force reviewers into diff archaeology and waste their judgment time. PR descriptions are the primary async communication channel between author and reviewer; a label-only description converts every reviewer into a code archaeologist before they can decide whether the change is safe.

### Bad — label-only

```markdown
## Summary
- State fix
- OPA/Rego compliance policies
- CI pipeline changes
- Pre-commit hooks
```

A reviewer reading this cold has no idea what the state fix was, why it was needed, or what they should look for when reviewing.

### Good — what changed + why it matters

```markdown
## Summary
- **Fixed broken repository state** — a prior refactor triggered a destroy+create
  race condition; added `moved` blocks so Terraform renames the state address
  instead of destroying, preventing data loss on next apply
- **OPA/Rego policies** — four policies now block plans that create repos without
  a description, with merge commits enabled, or without Dependabot alerts; a fifth
  warns on missing topics. Every policy has unit tests.
- **Parallel CI quality gates** — format, lint, validate, security, and policy checks
  now run in parallel before the plan job starts; a bad PR never burns self-hosted
  runner capacity
- **Pre-commit hooks** — `tofu fmt`, `tflint`, and `conftest verify` run locally on
  every commit so CI regressions are caught before push
```

Each bullet answers: *what changed* AND *why it matters to the person reading this*. The reviewer can now decide where to spend their judgment time without reading the diff first.

### Self-check before pushing the PR description

```
[ ] Does every bullet name WHAT changed?         (label alone is not enough)
[ ] Does every bullet say WHY it matters?        (consequence, risk, or rationale)
[ ] Could a cold reader pick the right review focus from the bullets alone?
```

If any box fails, expand the bullet before submitting. Two well-written bullets beat six label-only ones.

### Legitimate exceptions

Some bullets are genuinely short by nature:

- **Dependency bumps** — `Bumps lockfile` / `Updates eslint to 9.x` is fine when paired with the *why* on the next line or in the PR body
- **Pure mechanical refactors with no behaviour change** — `Renames Foo → Bar across 17 files` self-explains
- **Single-line bug fixes whose fix is the rationale** — `Fixes off-by-one in pagination guard (issue #42)` self-explains

Rex's advisory check (see `.claude/agents/code-reviewer.md`) flags label-only bullets as a `nit:` / `suggestion:` finding, not a blocking verdict, so legitimate short bullets don't churn the merge gate.

## Commit SHA Verification

Before merge, verify that the Code Reviewer's approved commit matches the current HEAD:

```
[ ] Code Reviewer approved commit: <sha>
[ ] Current HEAD commit:           <sha>
[ ] Match? YES → merge.  NO → re-request review.
```

This prevents merging code that was pushed after the last review.

## Design Review (UI Changes)

If the PR touches user-facing UI → design review is required before merge. Mechanically enforced by `require-design-review-for-ui.sh` (blocks merge without a design marker) and the `/approve-design <pr>` skill (writes the marker on explicit designer approval). See `.claude/skills/approve-design/SKILL.md` for the full invocation rules.

**Customising what counts as "UI"** (`.claude/project-config.json`):

| Key | Behaviour | When to use |
|-----|-----------|-------------|
| `.ui_paths` | **REPLACE** the default regex list entirely (JSON array of patterns). | Full control over the UI definition; you accept the maintenance cost of keeping the list in sync with framework defaults. |
| `.ui_paths_exclude` (#275) | **ADDITIVE** carve-out: paths matching any pattern here are removed from the touched-UI set *after* `.ui_paths` matching. | Keep the broad defaults but skip specific dirs where `.jsx`/`.tsx` are doc samples (e.g. `["^docs/examples/", "^wiki/artifacts/"]`) — non-breaking, doesn't drift from upstream. |

Prefer `ui_paths_exclude` for the common case of "the default is right except for these few dirs"; reach for `ui_paths` only when the framework's UI definition genuinely doesn't fit your repo layout.

## QA Gate Checklist

Before moving a ticket to Done:

```
[ ] All acceptance criteria verified
[ ] Test coverage > 80% for new code
[ ] Integration tests pass
[ ] E2E critical paths pass
[ ] No open Critical/High bugs
[ ] Performance within targets
[ ] Security scan clean
```

## No Red CI Before Merge

**Never** merge with red CI — even if the failure is pre-existing or unrelated. Fix the pre-existing issue first (separate commit), rebase the PR so all checks are green, and only then merge.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
