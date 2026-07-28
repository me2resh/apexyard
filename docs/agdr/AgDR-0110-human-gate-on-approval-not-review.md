# Put the mechanical human gate on approval, not on review

> In the context of **skill invocability across the review-and-merge chain**, facing **a human gate that blocked the harmless step while leaving the irreversible one model-invocable**, I decided **to swap them — review skills become model-invocable, approval skills become human-only** to achieve **enforcement that matches the rule `pr-workflow.md` has always stated in prose**, accepting **that the operator now types `/approve-merge <pr>` themselves for every merge**.

## Context

Skill invocability is controlled by `disable-model-invocation` in each SKILL.md's frontmatter. Before this decision the chain was arranged like this:

| Skill | What it does | Model-invocable? |
|---|---|---|
| `/code-review` | Triggers an independent reviewer sub-agent (Rex) | **NO** |
| `/security-review` | Triggers Hakim | **NO** |
| `/design-review` | Triggers Tariq | **NO** |
| `/approve-merge` | **Writes the CEO marker and runs the merge** | **YES** |
| `/approve-design` | Writes the design approval marker | **YES** |
| `/approve-architecture` | *(no frontmatter at all)* → defaults to yes | **YES** |

Two independent problems follow from that arrangement.

**The framework instructed an action it forbade.** `auto-code-review.sh` fires on every `gh pr create` and tells the orchestrator: *"Run the code review through the /code-review skill on PR #N."* Attempting exactly that returns `Skill code-review cannot be used with Skill tool due to disable-model-invocation`. Every PR therefore required the operator to hand-type `/code-review <pr>`. In one session this meant six manual invocations for a batch of routine fixes, plus three more for security reviews.

**The merge gate's human requirement was prose-only.** `/approve-merge` writes `approved_by=user` and merges in the same turn. Its own SKILL.md says *"The discrete approval moment is the invocation of /approve-merge"* and *"INVOKE THIS SKILL ONLY ON EXPLICIT, PER-PR, USER-NAMED MERGE APPROVAL"* — but nothing mechanical enforced that. A model could invoke it.

This was never a regression. `/code-review`'s flag dates to `8fa3c92` (2026-04-06), the initial `feat(#1): add Claude Code primitives` commit, and was never revisited. `/approve-merge` arrived later via `feat(#11): require explicit per-merge CEO approval — never infer from "go"` with `disable-model-invocation: false` set **explicitly**. The change whose stated purpose was making merge approval a deliberate human moment shipped the skill as model-invocable.

The two were also **coupled by accident**: because a model could not invoke `/code-review`, it could not obtain a Rex marker, so it could not merge. The locked review skill was incidentally the thing preventing autonomous merges — which is why unlocking it alone would have been actively dangerous.

**That coupling was weaker than it looks, and the distinction matters.** `.claude/agents/code-reviewer.md` documents that the **orchestrator** may set the `active-reviewer` marker and spawn the reviewer sub-agent directly via the Agent tool, without going through `/code-review` at all. So the autonomous `open → review → approve → merge` path was already *reachable* before this decision, not merely latent behind a flag. The pre-existing protection was therefore weaker than "the review skill is locked" suggests — which strengthens rather than weakens the case for this change: the swap replaces an incidental, bypassable barrier with a mechanical one on the step that actually authorises the irreversible action.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Leave as-is** | Zero change; the accidental coupling does block autonomous merge today | Framework keeps instructing an impossible action; friction on every PR; the merge gate stays prose-only, so the protection is incidental rather than designed |
| **Unlock review skills only** | Removes the friction immediately; smallest diff | Opens a fully autonomous `open → review → approve → merge` path with no human anywhere. Trades a real safety property for convenience — the worst available trade |
| **Lock approval skills only** | Closes the autonomous-merge gap | Operator still hand-types `/code-review` on every PR; the `auto-code-review.sh` contradiction persists |
| **Swap both (CHOSEN)** | Gate lands where authorisation actually happens; friction removed where it bought nothing; enforcement finally matches `pr-workflow.md` | Operator must type `/approve-merge <pr>` themselves — no longer delegable by saying "approved" in prose |

## Decision

Chosen: **swap both**, because the two changes are only safe together and are jointly a strict improvement.

- **Review skills → model-invocable.** Independence comes from the skill spawning a **separate reviewer sub-agent with its own context**, not from who typed the command. A review triggered by the model is exactly as independent as one triggered by a human. Locking it bought no safety and taxed every PR.
- **Approval skills → human-only.** These write the markers that merge gates read. `/approve-merge` additionally performs the merge — irreversible and externally visible. This is where a human belongs, and it is what the rule already demanded.

`/approve-architecture` had no frontmatter at all, so it was silently model-invocable by default. It now carries a proper `name` / `description` / `disable-model-invocation` block like its siblings.

## Consequences

- The operator stops typing `/code-review`, `/security-review`, `/design-review` — the orchestrator triggers them, as `auto-code-review.sh` always instructed.
- The operator starts typing `/approve-merge <pr>`, `/approve-design <pr>`, `/approve-architecture <pr>`. Saying "approved" in prose is no longer sufficient; the *invocation* is the approval, and only a human can make it. This is the intended cost.
- The two-marker merge gate is unchanged. Rex still writes `*-rex.approved`; the CEO marker still requires a human. What changes is that the human requirement is now **mechanical**, not prose.
- The **skill-invocation** path to an autonomous merge is closed by design rather than by side effect. This is deliberately not the claim that autonomous merge is *impossible*: raw-Bash forgery of a marker remains technically available, as AgDR-0104 and AgDR-0109 already state, and `active-reviewer` writes are not themselves gated. What changes is that the supported path now requires a human at the step that authorises the irreversible action, instead of relying on an unrelated flag to block it incidentally.
- `warn-review-marker-write.sh` is unaffected — it gates marker *writes* on the active-reviewer session marker, which the review skills manage regardless of who invokes them.
- A regression test pins the invariant so a future frontmatter edit cannot silently reopen the gap. This matters: the original defect was exactly a frontmatter value nobody was watching.

### What this does NOT change

It does not touch the *review* gates themselves, the marker formats, or `block-unreviewed-merge.sh`. It does not make the agent's reviews more or less trustworthy. And it does not address the separate, larger problem that these hooks infer intent from raw shell command text — see AgDR-0104 and issues #1026, #1032, #1038, #1039.

## Artifacts

- me2resh/apexyard#1042 — the issue
- `.claude/skills/{code-review,security-review,design-review}/SKILL.md`
- `.claude/skills/{approve-merge,approve-design,approve-architecture}/SKILL.md`
- `.claude/hooks/tests/test_skill_invocability_gates.sh` — pins the invariant
