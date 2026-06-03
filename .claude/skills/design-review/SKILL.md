---
name: design-review
description: Review a technical design / migration AgDR / feature spec for architectural soundness BEFORE the Build phase. Invokes the Solution Architect agent (Tariq) — the non-code analog of /code-review.
disable-model-invocation: true
argument-hint: "<pr-number-or-path> [repo]"
allowed-tools: Bash, Read, Grep, Glob
---

# /design-review — Solution Architecture Review

Review a **design artifact** — a technical design doc, a migration AgDR, or a feature spec / PRD — for architectural soundness before any code is built against it. This is the non-code analog of `/code-review`: where Rex reviews a code PR, **Tariq (the Solution Architect)** reviews the design.

The Tech Lead *authors* the design; Tariq *reviews* it. Authoring and reviewing are deliberately separate — an author reviewing their own design is the gap this role closes.

## Activated agent + role

When `/design-review` runs:

1. **Primary reviewer**: the **Solution Architect agent (Tariq)** at [`.claude/agents/solution-architect.md`](../../agents/solution-architect.md) — reviews the design against the architecture review lens (NFRs, patterns, tech debt, AgDR linkage, risk, trade-offs, traceability, migration safety) and discovers + applies adopter handbooks exactly as Rex does.
2. **Escalation**: the **[Head of Engineering](../../../roles/engineering/head-of-engineering.md)** — for enterprise / cross-project / new-tech-stack concerns that exceed the Solution Architect's remit.
3. **Conditional Security Auditor**: if the design touches auth / crypto / secrets / user data, chain `/security-review` for the deeper pass.

See [`.claude/rules/role-triggers.md`](../../rules/role-triggers.md) for the full activation protocol. Per the role's `isolated-work-class`, the reviewer runs as a spawned sub-agent.

## Usage

```
/design-review 42                         # review the design in PR #42
/design-review 42 your-org/your-repo      # specify the repo
/design-review docs/designs/checkout.md   # doc-only review (no PR yet)
```

## Process

1. Resolve the target — a PR number (preferred: gives a diff + a place to post the verdict + a marker key) or a path to a design artifact.
2. Fetch PR details and the latest commit SHA (when reviewing a PR).
3. Read the design artifact(s).
4. Review against the architecture review lens (below) plus discovered handbooks.
5. Submit a GitHub review via `gh pr review` (when reviewing a PR).
6. On APPROVED only: write the sign-off marker so the Design→Build gate passes (see `/approve-architecture` — Tariq writes the marker himself on an APPROVED verdict; `/approve-architecture` is the human/operator path to record the same marker).

## Review Lens

### Quality attributes / NFRs

- NFRs stated and addressed; targets concrete, not vague.

### Design patterns & structure

- Pattern fits the problem; fits the established architecture; dependencies point the right way.

### Technical debt

- Incurred debt is explicit, justified, and has a paydown path — no silent debt.

### Decisions (AgDR linkage) — BLOCKING

- Every significant technical decision (library, framework, storage, integration, pattern) is captured in an AgDR.
- A real decision with no AgDR → REQUEST CHANGES (run `/decide` first).

### Risk

- Failure modes, blast radius, and rollback addressed.

### Trade-off analysis

- Alternatives genuinely considered; trade-offs of the chosen path stated.

### Requirements traceability

- Design satisfies the PRD / acceptance criteria; no scope creep, no uncovered requirement.

### Migration safety (migration AgDRs)

- Data-loss risk, downtime, lock contention, cross-service consumers, observability, reversible cutover.

### Adopter Handbooks

- Discover + apply the public `handbooks/**` tree and the private `custom-handbooks/**` layer (framework defaults unless overridden in the sibling portfolio repo). Blocking handbooks turn a finding into a required change.

## Output

Posts a GitHub review comment with:

- Commit SHA reviewed
- Review-lens results
- Blocking findings + handbook findings
- Verdict: APPROVED / CHANGES REQUESTED / COMMENT

On APPROVED, Tariq writes `<owner>__<repo>__<pr>-architecture.approved` (repo-qualified, see AgDR-0060) so the `require-architecture-review.sh` gate lets the design PR merge.

Invokes: Solution Architect Agent (Tariq)

## Relationship to other review skills

| Skill | Reviewer | Reviews | Gate |
|-------|----------|---------|------|
| `/code-review` | Rex (Code Reviewer) | code PRs | `block-unreviewed-merge.sh` (Rex marker) |
| `/security-review` | Hakim (Security Auditor) | security-sensitive diffs | auto-fire on auth/crypto/secrets |
| **`/design-review`** | **Tariq (Solution Architect)** | **technical designs / migration AgDRs / feature specs** | **`require-architecture-review.sh` (architecture marker)** |

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
