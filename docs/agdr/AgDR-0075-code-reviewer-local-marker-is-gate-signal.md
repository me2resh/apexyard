# Code-reviewer flow is auto-mode-friendly — the local marker is the gate signal, not a GitHub "Approved" state

> In the context of the merge gate requiring a `*-rex.approved` marker, facing recurring "blocked / security-warning" noise when the sanctioned `code-reviewer` agent tried to post a GitHub `gh pr review --approve` (self-approval refusal + auto-mode write-classifier flag), I decided to make the canonical happy path explicit in docs only — the **local marker is THE gate signal**, reviews post as `--comment` carrying the verdict, and `--approve` is expected-to-be-blocked and not required — to achieve a friction-free, auto-mode-compatible flow, accepting that this is an instruction/documentation clarification that changes no hook or gate logic.

## Context

The merge gate (`block-unreviewed-merge.sh` + `_lib-review-markers.sh`) reads a **local** `.claude/session/reviews/<owner>__<repo>__<pr>-rex.approved` marker file to decide whether the code-review side of the two-reviews requirement is satisfied. It does **not** read GitHub's review-state UI.

Reported in me2resh/apexyard#587: in auto-mode (background / non-interactive) sessions, the sanctioned `code-reviewer` (Rex) sub-agent repeatedly surfaced "blocked / security-warning" noise. Investigation showed the noise came from attempts to post `gh pr review --approve`:

1. GitHub refuses to let an account approve its own PR ("Cannot approve your own PR") in the default single-maintainer / single-GitHub-account setup.
2. An auto-mode write-classifier may additionally flag the `--approve` attempt.

Crucially, the **gate flow is not actually broken**: in practice the agent CAN write the local `*-rex.approved` marker, and that local marker is what the gate reads. What was broken was the *expectation* — the agent file told Rex to attempt `--approve` and treated its block as a problem to work around, when the block is expected and the GitHub "Approved" state is not required at all.

The maintainer's standing position (issue comments) is that **independent review by a separate entity is load-bearing** — the two-reviews rule only means something if the reviewer isn't the author. This decision does **not** weaken that: the sanctioned `code-reviewer` is a distinct sub-agent (separate context) from the author, so its writing of the marker is the gate working as designed. The author-vs-reviewer separation lives in *which agent* writes the marker, not in the GitHub review-state UI. A *build* agent writing the marker remains the author-impersonating-reviewer violation documented in `.claude/rules/pr-workflow.md` § "Build agents cannot self-review".

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Do nothing (status quo) | No work | Recurring "blocked / security-warning" noise persists; the agent file still tells Rex to attempt `--approve` and treats its block as a failure to work around |
| **Documentation/instruction-only clarification** — local marker is THE gate signal; post reviews via `--comment` with verdict in body; `--approve` is expected-blocked and not required | Zero risk (no hook/gate/validation change); removes the recurring noise; matches how the gate already works; keeps the strict author-vs-reviewer separation intact | Doesn't add a *new* mechanical capability; relies on the agent following its (now clearer) instructions |
| Change `block-unreviewed-merge.sh` to accept a posted GitHub review at PR HEAD as proof (AgDR-0062 path) | Sidesteps the write-classifier entirely | Changes load-bearing gate logic; in a single-account setup self-approval can never be satisfied and would block every merge; explicitly out of scope and deferred to an opt-in flag per AgDR-0062 |
| Carve out a classifier exception for Rex marker writes | Targets the symptom directly | Harness-level (Claude Code), not apexyard-side; non-deterministic; not something this repo controls |

## Decision

Chosen: **documentation/instruction-only clarification.** Make the canonical happy path explicit across three files, touching no hook, gate, or marker-validation logic:

1. `.claude/agents/code-reviewer.md` — the local `*-rex.approved` marker is the required gate output; post the human-readable review via `gh pr review --comment` with the verdict in the body; do **not** attempt `--approve` by default and treat its block as expected, not a failure. Reinforced that Rex (a distinct review pass) writing its own marker is the gate working as designed, with an explicit carve-out reminder that build agents must not.
2. `.claude/rules/pr-workflow.md` — a note in the merge-gate section: the load-bearing signal is the local marker, reviews post as comments under single-account / auto-mode setups, and a GitHub "Approved" state is optional and unavailable when reviewing your own account's PR.
3. This AgDR.

Load-bearing principles:

1. **The local marker is the gate signal** — not GitHub's review-state UI.
2. **`--comment` is the canonical happy path** — verdict goes in the body; this always works in interactive and auto-mode sessions.
3. **`--approve` is expected-blocked and not required** — do not attempt it by default; do not treat the block as a review failure.
4. **The author-vs-reviewer separation is preserved** — it lives in *which agent* writes the marker; the sanctioned `code-reviewer` is distinct from the author, build agents are not (and still must not write markers).
5. **No gate logic changes** — explicitly out of scope; the AgDR-0062 opt-in proof-path remains the place for any future mechanical change.

## Consequences

- The recurring "blocked / security-warning" noise from Rex attempting `--approve` in auto-mode disappears, because Rex no longer attempts `--approve` by default.
- The merge gate is unchanged and behaves identically; no hook, `_lib-review-markers.sh`, or validation logic was touched.
- The strict author-vs-reviewer separation the maintainer requires is unchanged and now more clearly documented (which agent may write the marker).
- A future mechanical change (accepting a posted GitHub review at HEAD as proof, behind a config flag) remains available via the AgDR-0062 opt-in path; this decision is the cheap, zero-risk fix that did not require it.

## Artifacts

- Issue: me2resh/apexyard#587
- PR: fix(#587) — code-reviewer flow is auto-mode-friendly — local marker is the gate signal
- Files: `.claude/agents/code-reviewer.md`, `.claude/rules/pr-workflow.md`, this AgDR
- Related: AgDR-0062 (opt-in posted-GitHub-review proof path), `.claude/rules/pr-workflow.md` § "Build agents cannot self-review"
