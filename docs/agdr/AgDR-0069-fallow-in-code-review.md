# AgDR-0069 — Run Fallow static analysis as a code-review step on JS/TS diffs

> In the context of ApexYard's automated code review, facing the gap that Rex reasons about a diff but runs **no JS/TS static-analysis pass**, I decided to **add a fail-soft §9 step to the Code Reviewer agent that runs the Fallow CLI on JS/TS diffs (changed-scope) and renders a findings table plus a dry-run fix preview**, rather than wiring it as a hook or orchestrating the `/fallow` skill from the main thread, to achieve earlier detection of dead code, duplication, circular dependencies, and complexity hotspots, accepting an optional external CLI dependency and an advisory-only verdict effect.

## Context

- Rex (`.claude/agents/code-reviewer.md`) already gates language-specific **handbook** loading on the diff (`**/*.{ts,tsx}` → load `handbooks/language/typescript/`). It has no equivalent **tool** pass — nothing actually analyses the changed JS/TS for unused exports, clones, circular dependencies, or complexity.
- [Fallow](https://docs.fallow.tools) is a zero-config JS/TS intelligence CLI (`fallow check | find-dupes | check-health`, `fix --dry-run`) with `--changed-since` diff scoping and a JSON output mode — a natural fit for a review-time, changed-code-scoped pass. Exit code 1 means "issues found" (normal); only exit 2 is a real error.
- Two facts constrain the design:
  1. **Rex has `Bash` but no `Skill`/`Agent` tool** — it can run the `fallow` binary but cannot invoke the `/fallow` skill. The integration is "Rex runs the CLI," not "Rex calls the skill."
  2. **ApexYard is multi-language.** Not every adopter ships JS/TS, so the step must be invisible (no new failure mode) for projects that don't have fallow — the same fail-soft posture as the MCP semantic supplement (apexyard#449) and opt-in LSP.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| 1. **Rex runs the Fallow CLI (§9 step), fail-soft, advisory** (chosen) | Reuses Rex's existing JS/TS diff gate; no new hook; degrades silently when the CLI is absent; mirrors the handbook + MCP-semantic-supplement precedent | Adds an optional external CLI dependency; review wall-clock grows on JS/TS PRs |
| 2. PostToolUse hook runs fallow on `gh pr create` | Mechanical, deterministic | A shell hook can't compile a table or stage a model-reasoned dry-run; duplicates the `auto-code-review.sh` nudge; can't reason about which findings matter |
| 3. Main-thread `/code-review` skill orchestrates `/fallow`, then feeds Rex | Uses the skill as authored | Splits the review across two contexts; the skill surface and the agent drift; more moving parts for the same output |
| 4. Do nothing — leave fallow as a manual `/fallow` invocation | Zero cost | Loses the "every PR" coverage; relies on humans remembering |

## Decision

Chosen: **Option 1 — Rex runs the Fallow CLI as a new §9 review step**, because it reuses the existing JS/TS diff gate, needs no new hook, and follows the established fail-soft pattern for optional tooling. Findings are **advisory** (`nit:` / `suggestion:`, verdict unaffected) — fallow surfaces *candidates* (its own docs call security findings unverified) and cleanup opportunities aren't merge blockers. The step is scoped to **changed code** (`--changed-since <base>`), and fixes are **dry-run only** (`fix --dry-run`) — Rex carries `disallowedTools: Write, Edit` and never mutates the tree.

## Consequences

- JS/TS PRs gain an automatic dead-code / duplication / circular-dep / complexity pass with a results table and a proposed-fix preview in the review body.
- Adopters who never install the `fallow` CLI see identical Rex behaviour to before (silent skip) — no hard onboarding requirement.
- A new opt-in `quality.fallow_review` flag in `onboarding.yaml` lets a JS/TS adopter disable the pass even when the CLI is present.
- The `/code-review` skill (`.claude/skills/code-review/SKILL.md`) and `workflows/code-review.md` must be kept in sync with the agent's §9.
- If fallow's blocking value proves high later (e.g. a newly-introduced circular dependency), a narrow blocking subset can be added behind a follow-up AgDR.

## Artifacts

- Ticket: me2resh/apexyard#627
- Branch: `feature/GH-627-support-fallow` (fork: `tifa64/apexyard`)
- Touches: `.claude/agents/code-reviewer.md`, `.claude/skills/code-review/SKILL.md`, `workflows/code-review.md`, `onboarding.example.yaml`, `docs/getting-started.md`
- PR: me2resh/apexyard#628
