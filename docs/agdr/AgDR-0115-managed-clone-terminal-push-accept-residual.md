---
id: AgDR-0115
timestamp: 2026-08-01T06:57:51Z
agent: claude (Platform Engineer — Adel)
model: claude-sonnet-5
trigger: user-prompt
status: executed
category: security
projects: [apexyard]
---

# Managed-project clones: accept the terminal-push residual, lean on forge-native branch protection

> In the context of #1087 (step 1 of #1086) shipping `bin/install-git-hooks.sh` for the ops fork's own repo but deliberately NOT wiring it into `/handover` — because pointing `core.hooksPath` at an arbitrary just-cloned repo's own tracked `.githooks/` hands that repo's committed scripts silent execution on the very next `git fetch`/`checkout`, no push required — facing the resulting gap that a human running `git push origin main` from a terminal inside a `workspace/<project>/` clone is not blocked by anything client-side, I decided to **accept the residual (Option D)** rather than build a new client-side mechanism to close it, and to add a forge-native, advisory, fail-open check at `/handover` time that nudges the operator to turn on the managed repo's own server-side branch protection — to achieve an honest, non-overclaiming security posture consistent with AgDR-0104's controls-vs-backstops framing, accepting that terminal pushes in managed-project clones stay genuinely unprotected by ApexYard itself until either a future untracked-hook mechanism (Option A) or the operator's own forge-side branch protection covers them.

## Context

`.githooks/pre-push` is tracked in the **ops fork** and, once `core.hooksPath` is set (via `bin/install-git-hooks.sh`, invoked from `/setup`), protects the ops fork's own protected branches from a terminal push. #1086/#1087 built that installer and proved it works — but also proved, by direct reproduction against a scratch repo, that running the *same* installer against a repo `/handover` has just cloned is a distinct and much worse act: it points `core.hooksPath` at **that repo's own committed `.githooks/`**, and git hooks fire on ordinary, non-push operations too (`post-checkout`, `reference-transaction` both fired in the repro, with no push involved). Git deliberately never clones `$GIT_DIR/hooks` — that is precisely what makes cloning an untrusted repository a safe, read-only act. Repointing `core.hooksPath` at *tracked* content removes that property and hands the just-cloned repo's own scripts execution, with no operator confirmation and no provenance check. The security review on #1087 rated this HIGH, and the `/handover` call was removed before merge (see `.claude/skills/handover/SKILL.md`'s existing note on the clone step, and `bin/install-git-hooks.sh`'s own header).

That leaves a real, load-bearing gap, stated plainly on #1088:

| Push path | Protected today? |
|---|---|
| Agent-driven push in a managed project (Claude Code session) | Yes — the ops-fork `PreToolUse` hooks (`pre-push-gate.sh` and friends) fire because the *agent* runs in the ops-fork context, regardless of which repo it's writing to |
| **Human terminal push in a managed-project clone** (`cd workspace/<name> && git push origin main`) | **No — nothing in ApexYard covers this** |

This AgDR is the design decision #1088 asked for: how (or whether) a managed-project clone should gain protection for that second row, without the framework ever pointing git at tracked content it doesn't control.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. Install the framework's own hook into the clone's *untracked* `.git/hooks/pre-push`** | Closes the trust-boundary problem entirely — nothing tracked ever executes; the mechanism is the same shape as the ops fork's own (proven) `.githooks/pre-push` model, just delivered a different way | Not version-controlled, so it must be re-applied on every fresh clone/re-clone (drift); needs an explicit collision policy for a clone that already has its own `.git/hooks/pre-push` (overwrite is destructive, skip leaves it unprotected); still `--no-verify`-bypassable like any client-side git hook; needs its own design (payload content, install trigger, drift detection) and its own ticket — genuinely unscoped today, not a five-line change |
| **B. Point `core.hooksPath` at a framework-controlled directory *outside* the clone** | The clone's own `.githooks/` never runs, so the specific #1087 finding doesn't recur | Requires an absolute, per-machine path baked into `core.hooksPath` — which is *exactly* the stale-absolute-path failure mode #1086/#1087 exist to repair for the ops fork itself. Adopting the same shape for every managed-project clone multiplies that failure mode by the number of clones. **Rejected.** |
| **C. Prompt the operator at clone time, showing what would execute** | Puts a real decision in front of a human before anything runs | Weak in isolation — clone time is when the operator has the *least* context about a repo they're still evaluating (`/handover`'s whole point). Only defensible as a secondary confirmation layered on top of A, never as a standalone control |
| **D. Accept the residual — do nothing new client-side; lean on the forge's own server-side branch protection** | Honest about what ApexYard's client-side mechanism can and can't cover for a repo it doesn't own; zero new attack surface; the dominant real-world path (agent-driven pushes) is already covered; server-side branch protection is portable across every contributor and every clone, present or future, with no per-clone re-install and no `--no-verify` bypass | The gap is real and stays open for the one path it covers (a human, at a terminal, choosing to push straight to a protected branch, on a repo where the operator hasn't turned on forge-side protection) |

## Decision

Chosen: **Option D — accept the residual**, refined with a forge-native advisory check.

A human running `git push origin main` from a terminal inside a `workspace/<project>/` clone is **not blocked client-side** by anything ApexYard installs. Agent-driven pushes in that same clone remain gated by the ops-fork's own `PreToolUse` hooks, because those fire on the *agent's* context regardless of which repo it's writing to — that is the dominant path in practice, per #1088's own framing. For the residual — the terminal-push path — **the managed repo's server-side branch protection is THE control**, not a backstop to some client-side mechanism ApexYard doesn't ship. This is the same "controls vs backstops, honestly named" logic AgDR-0104 already established for the ops fork's own trust chain, applied here to a repo ApexYard doesn't own at all: a client-side hook the framework doesn't (and structurally can't safely) install cannot be the control, so don't describe it as one.

Because Option D alone leaves the operator with no signal that the gap exists on *their* specific repo, this decision pairs it with a lightweight, forge-native, **advisory** nudge: `/handover` now checks whether the managed repo's default branch has server-side branch protection turned on, and prints a one-time nudge if it's absent or can't be confirmed. This is not a new client-side control — it is a visibility improvement at exactly the moment (adoption) an operator is positioned to act on it. See `.claude/skills/handover/SKILL.md` § "1.7. Check server-side branch protection" for the implementation, dispatched by `tracker_kind` the same way `tracker_review_submit`/`tracker_pr_merge` already dispatch (`.claude/hooks/_lib-tracker.sh`).

### Load-bearing guardrail (record prominently — this is the rail, not a footnote)

**No configuration ApexYard writes into a cloned repo may ever cause that repo's own TRACKED content to execute.** Concretely: **never point `core.hooksPath` at a clone's tracked `.githooks/`** (or any tracked directory) from a skill or hook the framework runs against a repo it does not itself author. That is precisely the #1087 HIGH finding, and it must never recur regardless of which option a future iteration of this decision picks. Option B is rejected above in part *because* it edges toward this same shape (a path a future refactor could accidentally point back at tracked content) — the rail is about the entire class, not just the one instance already caught.

### Not pre-committing to Option A

This AgDR does **not** adopt Option A as the mechanism, now or as a committed next step. It records only this: **if** the terminal-push gap is ever shown to actually bite (a real incident, not a hypothetical), Option A — installing into the clone's *untracked* `.git/hooks/pre-push`, never `core.hooksPath` — is the only trust-safe *direction* available on the client side. Even then, a forge-native fix (verifying/enforcing branch protection programmatically, rather than only nudging) should be compared first and preferred if it clears the bar: it survives re-clone with no per-clone re-install, and it is not defeated by `git push --no-verify` the way any client-side git hook structurally is. Building Option A speculatively, before the gap has actually bitten, is exactly the kind of unscoped client-side mechanism this AgDR declines to commit to today.

### Risk-direction correctness (the invariant this AgDR exists to keep visible)

For any mechanism in this space, past or future: **a block, or any non-zero/error exit, is the SAFE outcome. Exit 0 (silent success) against a third-party clone is the outcome that transfers code execution to that clone's own content.** The original #1087 finding was exactly an inversion of this — treating `exit 3` ("nothing to install, hooks dir absent") as the unremarkable case and `exit 0` as the success worth reporting, when `exit 0` against an untrusted clone is the dangerous one. `bin/install-git-hooks.sh` was corrected to state this the right way round (see its own header comment) as part of closing #1087's findings. Nothing adopted in a future revision of this decision may re-invert it.

## Consequences

- Terminal `git push` to a protected branch inside a `workspace/<project>/` clone remains genuinely unprotected by ApexYard. This is a **documented, accepted residual**, not an oversight — operators who need it closed today must turn on server-side branch protection on the managed repo themselves (which `/handover`'s new step 1.7 now nudges them toward).
- `/handover` gains one new advisory, fail-open step (1.7) that checks server-side branch protection on the target repo's default branch and nudges if it's absent or unverifiable. It never blocks the rest of the handover flow, and it degrades silently to a generic note for tracker kinds it can't query (`none`, `custom`).
- `bin/install-git-hooks.sh`'s header is corrected so it no longer claims `/handover` invokes it — a stale claim left over from before #1087's finding, which is exactly the footgun that could lead a future agent to re-add the removed HIGH-risk wiring. The corrected header points at `.claude/skills/handover/SKILL.md`'s own explicit note and this AgDR.
- Options A and B remain on the table for a *future* decision, explicitly not this one. B is rejected outright (reintroduces the stale-absolute-path class #1086 exists to fix). A is the only client-side direction left, gated behind an actual incident and a comparison against a forge-native alternative first.
- The load-bearing guardrail (never point `core.hooksPath` at a clone's tracked content) and the risk-direction invariant (block = safe, silent exit 0 against a third party = dangerous) are recorded here so they survive independently of whatever mechanism, if any, eventually closes the gap.

## Artifacts

- #1086 (parent epic: install git pre-push hooks, then move protected-branch enforcement into them)
- #1087 (step 1 — installer for the ops fork's own repo; the HIGH finding that removed the `/handover` wiring)
- #1088 (this design question)
- AgDR-0104 (trust-chain controls vs. backstops, honestly named — the framing this decision applies to a repo ApexYard doesn't own)
- `bin/install-git-hooks.sh` (installer + corrected header)
- `.claude/skills/handover/SKILL.md` § "1.5-clone" (existing note on why `/handover` doesn't call the installer) and § "1.7. Check server-side branch protection" (new advisory nudge)
