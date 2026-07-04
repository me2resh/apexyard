# AgDR-0073 — `/handover` generates an in-repo `AGENTS.md` (opt-in, assessment-derived, PR-delivered)

> In the context of `/handover` already performing a deep read of an adopted repo (tech stack, build/test/run commands, layout, harnessability, risks) but writing all of it to `projects/<name>/handover-assessment.md` in the **ops fork** — where no agent working *inside* the adopted repo ever auto-loads it — facing the choice of how to make an adopted repo self-describing to whoever (Claude Code, Cursor, Codex, …) later works in it, I decided to have `/handover` **offer (opt-in, default-OFF) to generate an `AGENTS.md` derived from the live assessment and deliver it into the target repo via a branch + PR**, treat `AGENTS.md` as canonical (offering a one-line `CLAUDE.md → @AGENTS.md` only when no `CLAUDE.md` exists) and never overwrite an existing `AGENTS.md`/`CLAUDE.md`, accepting that this is the first place `/handover` writes into the target repo at all (a deliberate, scoped exception to its read-only rule) and that the in-repo `AGENTS.md` and the ops-fork `handover-assessment.md` now hold deliberately non-overlapping subsets of the same source material.

## Context

`/handover` already computes everything an agent needs to start working in a repo without re-discovery: real build/test/run commands (steps 3-4), the project layout (step 2), conventions and lint/type baselines (step 4.5 harnessability), and the key gotchas/risks (step 5 Quality Risks). But the only durable artefact is `projects/<name>/handover-assessment.md`, which lives in the **ops fork** and is **not** on disk inside `workspace/<name>/`. An agent that opens the adopted repo a month later re-discovers the build command, the test runner, and the layout from scratch every session.

`AGENTS.md` is a tool-agnostic, in-repo convention that agents auto-load when they enter a repo. apexyard's own repo already uses the `CLAUDE.md → @AGENTS.md` import pattern. So the material to close this gap already exists in the handover flow — the only question was *how* to deliver it without violating the skill's load-bearing "read-only against the target repo" rule (Rule 1).

Two constraints shaped the decision:

1. **The target repo is not the ops fork.** Every other `/handover` write (assessment, architecture stubs, registry append) lands in the ops fork under the bootstrap exemption. Writing into the target repo is a categorically different act — it needs the target's normal SDLC (branch + PR), not the ops-fork bootstrap-exempt path.
2. **`AGENTS.md` and `handover-assessment.md` must not duplicate.** They serve different readers: the assessment is the *operator's* full analysis (risks, harnessability verdict, integration plan, next-step tickets); `AGENTS.md` is the *agent's* concise operating manual (stable commands, layout, conventions). Overlap would mean two artefacts to keep in sync.

## Options Considered

### Axis 1 — How to deliver the file into the target repo

| Option | Pros | Cons |
|--------|------|------|
| Direct commit to the target's default branch | Simplest; one fewer step | Violates "no direct pushes" / "every change through a PR"; surprises the repo owner with an un-reviewed file on `main` |
| Via the ops-fork bootstrap-exempt write path | Reuses existing machinery | Wrong repo entirely — the file would land in the ops fork, not the adopted repo; defeats the whole point (auto-load inside the repo) |
| **Branch + PR into the target repo** | Matches the target's normal SDLC; the repo owner reviews before merge; mirrors step 8's hand-off pattern | One more step; needs the operator's explicit go-ahead (it's the first target-repo write) |

### Axis 2 — Canonical file + relationship to `CLAUDE.md`

| Option | Pros | Cons |
|--------|------|------|
| Emit `CLAUDE.md` directly | Claude Code loads it natively | Tool-specific; a Cursor/Codex user in the same repo gets nothing |
| **Emit `AGENTS.md` as canonical; offer one-line `CLAUDE.md → @AGENTS.md` only when no `CLAUDE.md` exists** | Tool-agnostic single source of truth; mirrors apexyard's own repo; the import shim makes it work for Claude Code too without duplicating content | Slightly more to explain; relies on the `@import` convention |

### Axis 3 — Overwrite policy

| Option | Pros | Cons |
|--------|------|------|
| Overwrite an existing `AGENTS.md` | Always fresh | Destroys the repo owner's hand-tuned operating manual — the exact opposite of helpful |
| **Never overwrite; preserve (like the architecture stubs)** | Safe by default; a human-maintained file always wins | A stale `AGENTS.md` is left as-is (acceptable — the operator can refresh by deleting + re-running) |

## Decision

Chosen on all three axes:

- **Axis 1 — branch + PR into the target repo**, gated on the operator's explicit go-ahead and mirroring step 8's hand-off pattern. Never a direct commit to the default branch; never via the ops-fork bootstrap-exempt path.
- **Axis 2 — `AGENTS.md` is canonical**; when no `CLAUDE.md` exists, offer a one-line `CLAUDE.md` that imports it (`@AGENTS.md`). Tool-agnostic, matches apexyard's own convention.
- **Axis 3 — never overwrite** an existing `AGENTS.md` or `CLAUDE.md` — preserve, exactly like the architecture stubs (Rule 11).

The feature is **opt-in, default-OFF** as a row in the step 5.6 document checklist. Default-OFF is load-bearing: it keeps Rule 1 ("read-only against the target repo") true unless the operator consciously opts in. The generated content is **derived from the live assessment** (real commands, layout, conventions, key gotchas; for low-harnessability repos, what's fragile/missing) — not a generic template — and carries a "generated by `/handover` on `<date>` — review & refine" note.

## Consequences

- `/handover` Rule 1 is updated to document this as an **explicit, opt-in, PR-delivered exception** to read-only-against-the-target-repo. The default-OFF guarantee is what keeps the rule honest.
- A new role-split is documented: `handover-assessment.md` (ops fork — full operator analysis) vs `AGENTS.md` (in-repo — concise agent operating manual). They hold non-overlapping subsets of the same source material; no duplication.
- This is the first and only place `/handover` writes into the target repo. The bootstrap exemption explicitly does **not** cover it (it's a target-repo PR, not an ops-fork write).
- Refresh is manual: a stale `AGENTS.md` is preserved, not regenerated. The operator deletes it and re-runs to refresh — consistent with the architecture-stub and topology-instantiation never-overwrite rules.
- Keeping `AGENTS.md` in sync over time is explicitly out of scope (one-time generation), as is generating it outside the `/handover` flow.

## Artifacts

- PR: feat(#665): /handover offers in-repo AGENTS.md generation
- Ticket: me2resh/apexyard#665
- `.claude/skills/handover/SKILL.md` — step 5.6 catalogue row, step 8.5 generation + PR delivery, Rule 1 exception, Rule 21
- `docs/multi-project.md` — role-split note in the `/handover` behaviour row
