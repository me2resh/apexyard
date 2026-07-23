# Right-Size Ceremony — Match the Gates to the Change

The framework's SDLC gates exist to keep high-blast-radius work safe: a merge needs a review, a migration needs a rollback plan, a trust-chain edit needs the Security Auditor. That machinery is *correct* for the work it was built for. The failure mode is applying it **uniformly** — running the same review agents, role handoffs, and gate chain on a three-line `CODE_OF_CONDUCT.md` PR as on a schema migration. Uniform ceremony turns a batch of small changes into a gatekeeper queue (Rex → Tech Lead → Solution Architect → …) and burns tokens with nothing watching the disproportion.

This rule is the **trigger heuristic** — the sibling of [`plan-mode.md`](plan-mode.md), [`parallel-work.md`](parallel-work.md), and [`loop-mode.md`](loop-mode.md). It tells you how to **right-size the ceremony to the change** instead of defaulting every change to the full chain. It does **not** relax any existing hard gate — it adds the missing **lean floor** for work that plainly doesn't need them.

## The signals — how to tell what a change needs

Score the change on three cheap signals you can read before touching it:

| Signal | Read from | Low ← → High |
|--------|-----------|--------------|
| **Path class** | the file globs the framework already configures | docs/config-text (`.md`, `.txt`, issue templates) → ordinary code (`.py`, `.ts`) → **high-blast** (`.claude/hooks/**`, `.claude/settings.json`, `**/auth/**`, `**/crypto/**`, `**/secrets/**`, migrations, design artifacts, CI) |
| **Blast radius** | diff size + reversibility | a few lines, revert-in-one-commit → a large diff, or an externally-visible / hard-to-reverse act (a released tag, a schema change, a message send) |
| **Behavior surface** | does it change runtime behavior? | prose / comments only → touches code or tests → changes a security-critical control path |

## The tiers

The signals map to three tiers of ceremony:

| Tier | What it is | Ceremony |
|------|-----------|----------|
| **Lean** | docs / comments / config-text, small, trivially reversible, no behavior change | An **inline** correctness read + one approval. **No review sub-agent, no role chain.** |
| **Standard** | ordinary code changes | Rex (one review) + the human merge nod. Unchanged from today. |
| **Heavy** | trust-chain, auth / crypto / secrets, migrations, design artifacts, large diffs, releases | The **full chain stays** — Rex + Security Auditor / Solution Architect / design review as the paths dictate. Unchanged from today. |

The key realization: the framework **already detects every Heavy class** (the auto-fire triggers in [`role-triggers.md`](role-triggers.md), the migration gate, the architecture-review gate, the design gate). What was missing is the **Lean floor** — so everything not-Heavy was silently treated as Standard-full-ceremony. This rule adds only that floor.

## Two safety rails (non-negotiable)

A right-sizing heuristic is only safe if it fails in the harmless direction:

1. **Security and trust-chain never go Lean.** Any change touching `.claude/hooks/**`, `.claude/settings.json`, the merge-gate/marker libraries, auth, crypto, secrets, or a migration takes the Heavy path regardless of diff size. A one-line hook edit is exactly where you *want* the chain. This rail overrides the size signal every time.
2. **Ambiguity rounds up.** If you're not sure which tier a change is, take the higher one. The tolerated failure is "occasionally too much review on a borderline case" — never "too little review on a risky one."

## When to apply this (proactively)

Before spinning up review ceremony for a change, classify it:

- **Lean** → do the inline read yourself, state your verdict plainly, and take it to the merge nod. Don't spawn a review sub-agent for a docs-only, small, reversible change.
- **Standard** → the normal Rex + nod flow.
- **Heavy** → the full chain, unchanged. Never shortcut it.

And batch: N tiny independent Lean changes don't each need their own review pass — group the review, or merge them under one PR where the tracker model allows.

## The "watch" half — process cost vs change size

The other half of the operator's ask ("something to watch the overengineering") is a **disproportion nudge**: when the *process* is about to cost more than the *work* — e.g. spawning a ~100k-token review for a 3-line doc PR, or opening a five-agent fan-out for three two-line edits — stop and take the Lean path instead. The existing `enforce-budget.sh` hook already meters token cost; this rule is the judgment that reads that meter.

## Self-check before spawning review ceremony

```
[ ] What tier is this change — Lean / Standard / Heavy? (path class + blast radius + behavior)
[ ] If I'm about to spawn a review sub-agent or role chain, does the change actually warrant it, or is it Lean?
[ ] Does it touch security / trust-chain / a migration? → Heavy, no exceptions (rail 1).
[ ] Am I unsure of the tier? → round UP (rail 2).
[ ] Is the process cost (agents, tokens, latency) proportionate to the change size?
```

If you're spinning up the full chain for a change that's plainly Lean, you missed a right-sizing opportunity — the same class of miss as over-using `/fan-out` on trivial edits.

## Backstop

This rule is **primarily self-discipline** — the same shape as [`plan-mode.md`](plan-mode.md) and [`loop-mode.md`](loop-mode.md). Mechanical enforcement of the *Lean* floor isn't viable: a shell hook can't see "the agent is about to spawn a review sub-agent for a tiny change" — the `Agent`/`Task` spawn boundary has no `PreToolUse` matcher (see [AgDR-0056](../../docs/agdr/AgDR-0056-subagent-mcp-first.md)), the same reason `parallel-work.md` and `agent-role-selection.md` are self-discipline too. And a *blocking* tier-classifier would re-introduce the exact rigidity this rule exists to reduce — a mis-tier that hard-blocks is worse than the over-ceremony it replaces.

So the enforcement split is deliberate: the **Heavy** classes keep their existing hard gates (merge gate, migration gate, architecture/design/security review — all unchanged); the **Lean** floor is agent judgment, watched by `enforce-budget.sh`'s token meter. Pair with feedback memory: if the operator says a change got "too much process" or "too much token burn," lean into this rule harder next time.

The cost of taking the Lean path on a change that turns out to need more is a follow-up review — cheap, and rail 2 makes it rare. The cost of running the full chain on every trivial change is the gatekeeper queue and token burn that prompted this rule.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
