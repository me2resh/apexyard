# AgDR Materiality Threshold — Record Material Decisions, Not Every Decision

> In the context of an over-broad decision-recording rule that demanded an AgDR before *any* technical decision, facing a real user reporting "infinite loops of AgDRs then backend then devops and zero progress", I decided to replace the blanket trigger with an explicit materiality threshold plus a concrete exemption list, to restore "make progress by default" without losing the durable record of architectural calls, accepting that a small number of borderline decisions will now go unrecorded unless the ambiguity-rounds-up rail catches them.

## Context

`.claude/rules/agdr-decisions.md` opened with **"HARD STOP: before making any technical decision, run `/decide`"** and listed triggers including *"Pick an implementation approach"* and *"Am I about to write code that introduces a new pattern?"*. Read literally, that covers nearly every implementation choice.

Three things made this actively harmful rather than merely verbose:

1. **It compounded the role-handover loop.** Every AgDR lands a file under `docs/agdr/**`, which re-fires the Tech Lead activation trigger (and, for migration AgDRs, the Solution Architect trigger too). So the AgDR rule *manufactured* the exact churn that [AgDR-0107](AgDR-0107-right-size-ceremony.md) and me2resh/apexyard#995 were fixing. The three issues are one disease.
2. **The prose was far broader than its own enforcement.** The mechanical hooks are bounded path sets (`require-agdr-for-arch-changes.sh` on `*.tf`/Dockerfile/compose/workflows; `require-agdr-for-arch-pr.sh` on `**/domain/**`, `**/migrations/**`, `template.yaml`, IaC paths, and dependency *additions*). `CLAUDE.md` already said "significant". Only the rule file said "any".
3. **A rule nobody can satisfy is a rule nobody follows.** An unmeetable bar doesn't produce more records; it produces ignored prose and spends the session's finite ceremony budget on decisions nobody needed written down.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Leave as-is** | Zero risk of under-recording; no work | Keeps feeding the reported loop; the bar stays unmeetable and therefore ignored in practice |
| **Delete the rule; rely on hooks alone** | Maximally cheap; hooks are already well-scoped | Loses the decisions no path glob can see — new technologies, security controls, cross-cutting patterns. Hooks match paths, not judgment |
| **Narrow the prose to the hooks' exact path set** | Perfectly consistent prose↔mechanism | Under-covers: a new technology or auth model introduced in ordinary source files would need no record |
| **Materiality threshold + explicit exemption list** (chosen) | Restores progress-by-default; keeps judgment-based coverage wider than globs; rails prevent the dangerous failure | Requires an agent to make a judgement call; borderline cases depend on rail 2 |

## Decision

Chosen: **an explicit materiality threshold plus a concrete "does NOT need an AgDR" list**, because the failure modes are asymmetric and the rails make the remaining risk cheap.

An AgDR is required when a decision is architectural, hard to reverse, or cross-cutting: a new dependency / technology, a new service or external integration, a data-model or schema change, a security-relevant control, CI/CD-release-infra design, or a pattern adopted repo-wide. It is **not** required for routine choices reversible inside a single PR: local naming, extracting a helper, control flow, test structure, or calling an API from a dependency already in the manifest.

Two rails from AgDR-0107 carry over unchanged and are non-negotiable:

1. **Security, trust chain, and migrations are never exempt** — regardless of diff size.
2. **Ambiguity rounds up** — if you can't tell, write the record.

The old *"could you explain the trade-off?"* heuristic is demoted from a trigger to a **writing aid**. As a trigger it over-fires by construction, because almost every line of code has an unexplained alternative.

Deliberately **not** in scope: any change to hook, gate, or marker logic. This narrows guidance only. Notably, `require-agdr-for-arch-pr.sh` still prints the old "any technical decision" phrasing in its agent-facing block message — that file is rail-1 trust chain (`.claude/hooks/**`) and must be corrected on the Heavy path with the Security Auditor, not tacked onto a prose change.

## Consequences

- Routine implementation work no longer triggers an AgDR, so it no longer triggers the downstream Tech Lead / Solution Architect activations that produced the reported handover loop.
- The threshold remains **wider than the hooks** by design — it covers judgment-visible decisions (technology, security posture, cross-cutting patterns) that no path glob can detect. Prose and mechanism are now consistent in *spirit* without pretending to be identical in *scope*.
- Rex's blocking AgDR check was narrowed to match; leaving it at the old bar would have silently cancelled this change at review time.
- Residual risk: a genuinely material decision judged "routine" and left unrecorded. Mitigated by rail 2, the unchanged mechanical hooks, and Rex's review pass. The tolerated failure is an occasional unnecessary AgDR — never a silently unrecorded architectural call.
- This AgDR exists because the new rule, applied to itself, says it should: changing the portfolio's decision-recording policy is cross-cutting. AgDR-0107 was scoped to *review* tiering; the *recording* threshold is a distinct policy call, so it gets its own record rather than inheriting one.

## Artifacts

- me2resh/apexyard#997 — the ticket
- me2resh/apexyard#998 — this PR
- [AgDR-0107](AgDR-0107-right-size-ceremony.md) — right-size-ceremony, the review-tiering sibling
- me2resh/apexyard#995 / #996 — the role-trigger convergence fix this change stops undermining
