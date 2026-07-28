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
- The `Agent`-tool spawn boundary has no `PreToolUse` hook (AgDR-0056), so the Lean floor cannot be mechanically enforced regardless; `enforce-budget.sh` already meters token cost. **[Incorrect — see Correction below: that hook is premium-only and does not ship in OSS.]**

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Advisory self-discipline rule (**chosen**) | Adds the Lean floor without touching any hard gate; matches the plan-mode / loop-mode pattern; a mis-tier can never hard-block | Relies on agent judgment; the Lean floor is not mechanically enforced |
| Blocking tier-classifier hook | Mechanical | Re-introduces rigidity; a mis-tier hard-blocks; can't see spawn intent anyway (AgDR-0056) |
| Do nothing | No work | The overengineering / latency / token-burn problem persists |

## Decision

Chosen: **an advisory self-discipline rule** (`.claude/rules/right-size-ceremony.md`) with a three-tier model (Lean / Standard / Heavy) selected from **path class + blast radius + behavior surface**, and two non-negotiable safety rails — **security / trust-chain / migration never goes Lean**, and **ambiguity rounds up a tier**. No new hook: the Heavy classes keep their existing hard gates (merge gate, migration gate, architecture / design / security review — all unchanged), and `enforce-budget.sh` is the token watch. **[The token-watch clause is incorrect — see Correction below: that hook is premium-only. The rest of this decision stands.]** The rule joins the `plan-mode` / `parallel-work` / `loop-mode` self-discipline family.

## Consequences

- Trivial docs / config-text changes no longer spawn a full review sub-agent or role chain — less gatekeeper latency, less token burn.
- Every existing hard gate is unchanged; safety is not relaxed (rail 1 keeps the chain exactly where blast radius justifies it).
- The failure mode is bounded to "occasionally too much review on a borderline case" (rail 2), never "too little on a risky one."
- The Lean floor is self-discipline; if it proves insufficient in practice, a dedicated advisory nudge-hook (process-cost-vs-change-size) is the deferred next increment.

## Correction (me2resh/apexyard#1044)

Two statements above are **factually wrong about what ships**, and are corrected here rather than edited in place — the decision was made as recorded; only the availability claim was mistaken.

The Consequences and Decision sections cite `enforce-budget.sh` as an existing hook that "already meters token cost" and serves as "the token watch" for the Lean floor. **That hook is not tracked in this repository.** It is a premium component (`apexyard-premium#335`, gated on a `features.budget` entitlement), so open-source adopters have no automatic disproportion signal at all.

The practical effect on this decision: the enforcement split described above is **advisory-rule-plus-nothing** for OSS adopters, not advisory-rule-plus-meter. The chosen option is unchanged and still stands on its own reasoning — a blocking tier-classifier would reintroduce the rigidity the rule exists to reduce, and the `Agent`-spawn boundary remains unhooked (AgDR-0056). But the "watch half" it leans on is weaker than recorded, which matters if the recurring over-process feedback persists: the deferred "dedicated advisory nudge-hook" listed in Consequences is then the *first* increment, not a contingency.

`.claude/rules/right-size-ceremony.md` and `CLAUDE.md` have been corrected to state the OSS enforcement honestly.

## Artifacts

- `.claude/rules/right-size-ceremony.md`
- `CLAUDE.md` wiring (Quality Rules bullet + rules-layer count)
- [me2resh/apexyard#993](https://github.com/me2resh/apexyard/issues/993)
- [me2resh/apexyard#1044](https://github.com/me2resh/apexyard/issues/1044) — the availability correction above
