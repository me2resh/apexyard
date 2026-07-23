---
id: AgDR-0107
timestamp: 2026-07-23T00:00:00Z
agent: claude (Tech Lead — Hisham)
model: claude-opus-4-8[1m]
trigger: user-prompt
status: executed
---

# Right-size ceremony: an advisory tiering guard against SDLC overengineering

> In the context of operator feedback that the framework had grown over-tightened and bureaucratic — uniform gate ceremony (review sub-agents + role-handoff chains) applied to trivial docs changes the same as to high-blast work, producing gatekeeper-queue latency and heavy token burn — facing the risk that the fix for "too much process" becomes *more* process, we decided to add a **self-discipline rule that right-sizes ceremony to change size via a three-tier (Lean / Standard / Heavy) advisory classifier**, keeping every existing hard gate untouched and adding only a Lean floor, to achieve proportionate review without relaxing any safety gate, accepting that the Lean floor is agent judgment (not mechanically enforced) and that a borderline change may occasionally get more review than strictly needed (rail 2: ambiguity rounds up).

## Context

- Operator feedback (2026-07-23): the new version feels "corporate / bureaucratic"; Rex → Hisham → Tariq → Nour handoff chains create a waiting queue; token burn is high; *"something needs to watch the overengineering — it's out of control."*
- The framework already detects every **high-blast** class (trust-chain, migration, design artifact, UI, auth/crypto/secrets) and gates it hard. The gap is the missing **Lean floor** — everything not-Heavy was silently treated as Standard-full-ceremony, so a `CODE_OF_CONDUCT.md` PR spawned a full Rex sub-agent and ran the same role chain as real code.
- A *blocking* tier-classifier would re-introduce the exact rigidity being complained about — a mis-tier that hard-blocks is worse than the over-ceremony it replaces.
- The `Agent`-tool spawn boundary has no `PreToolUse` hook (AgDR-0056), so the Lean floor cannot be mechanically enforced regardless; `enforce-budget.sh` already meters token cost.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Advisory self-discipline rule (**chosen**) | Adds the Lean floor without touching any hard gate; matches the plan-mode / loop-mode pattern; a mis-tier can never hard-block | Relies on agent judgment; the Lean floor is not mechanically enforced |
| Blocking tier-classifier hook | Mechanical | Re-introduces rigidity; a mis-tier hard-blocks; can't see spawn intent anyway (AgDR-0056) |
| Do nothing | No work | The overengineering / latency / token-burn problem persists |

## Decision

Chosen: **an advisory self-discipline rule** (`.claude/rules/right-size-ceremony.md`) with a three-tier model (Lean / Standard / Heavy) selected from **path class + blast radius + behavior surface**, and two non-negotiable safety rails — **security / trust-chain / migration never goes Lean**, and **ambiguity rounds up a tier**. No new hook: the Heavy classes keep their existing hard gates (merge gate, migration gate, architecture / design / security review — all unchanged), and `enforce-budget.sh` is the token watch. The rule joins the `plan-mode` / `parallel-work` / `loop-mode` self-discipline family.

## Consequences

- Trivial docs / config-text changes no longer spawn a full review sub-agent or role chain — less gatekeeper latency, less token burn.
- Every existing hard gate is unchanged; safety is not relaxed (rail 1 keeps the chain exactly where blast radius justifies it).
- The failure mode is bounded to "occasionally too much review on a borderline case" (rail 2), never "too little on a risky one."
- The Lean floor is self-discipline; if it proves insufficient in practice, a dedicated advisory nudge-hook (process-cost-vs-change-size) is the deferred next increment.

## Artifacts

- `.claude/rules/right-size-ceremony.md`
- `CLAUDE.md` wiring (Quality Rules bullet + rules-layer count)
- [me2resh/apexyard#993](https://github.com/me2resh/apexyard/issues/993)
