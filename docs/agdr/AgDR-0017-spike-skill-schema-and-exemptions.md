# Spike skill — schema additions, naming, exemption set, disposition gate

> In the context of ApexYard's ticket types being uniformly production-shaped (`Feature` / `Bug` / `Chore` / `Refactor` / `Testing` / `CI` / `Docs`), facing a missing scaffold for **throw-away exploration code** — prototypes, proof-of-concepts, spikes whose goal is to prove or disprove a hypothesis with minimum investment — I decided to ship a `Spike` ticket type with hypothesis-driven required fields (Hypothesis, Budget, Kill Criteria, Disposition), a surgical exemption from the AgDR + coverage gates (Rex + security auditor still apply), and a mandatory `/spike-close` disposition gate (PROMOTE or DISCARD only, no "decide later"), to achieve a coherent path for 1-3 day exploration work that doesn't drag in the full production SDLC, accepting that the exemption is opt-in (skills must write the right marker; a non-cooperating workflow won't get the exemption), the disposition gate is prose-only on the close path (no hard block — closure is the operator's call, motivated by the loss-of-record cost), and the schema-completion across all four whitelists (`branch.type_whitelist` already had `spike`; `commit`, `pr.title_type_whitelist`, and `ticket.prefix_whitelist` did not) closes the half-built scaffolding the framework had been carrying.

## Context

Three problems pointed at the same gap:

1. **Schema asymmetry.** `branch.type_whitelist` shipped with `spike` since the early days. `commit.type_whitelist` did not. `pr.title_type_whitelist` did not. `ticket.prefix_whitelist` had no matching entry. The result: an engineer following the framework's own `branch/commit/PR/ticket` convention would create a `spike/...` branch and immediately get blocked by `validate-commit-format.sh` and `validate-pr-create.sh` — the very hooks meant to enforce the convention. Half-built scaffolding is worse than none — it advertises a workflow then refuses to support it.

2. **The bar is wrong.** A spike done under feature-class rules is too expensive. Full PRD, AgDR for every decision (`require-agdr-for-arch-pr.sh` blocks the PR), 80% coverage. Authors avoid filing them and either skip the exploration entirely (decide blind) or do it without a ticket (defeats the framework). The framework has no signal for "this is throw-away code; the deliverable is the answer, not the implementation".

3. **Disposition rot.** Production code persists. Spike code either gets promoted to a real feature with fresh delivery, or it gets deleted with a memo. Letting spike code sit half-merged into main is the worst-of-both case — neither shipped nor cleaned up, no record of what was learned, future engineers re-explore the same ground a year later. Without a structural disposition gate, this happens by default.

## Options Considered

### Option A — Just add `spike` to commit / PR / ticket whitelists; reuse `Feature` body schema

| Pros | Cons |
|------|------|
| One-config-file change | Doesn't address problem 2 (bar is wrong) — Hypothesis/Budget/Kill Criteria/Disposition are different from User Story/AC |
| No new skills | Doesn't address problem 3 (disposition rot) — no gate |
| | Adopters file `[Spike]` tickets that look identical to `[Feature]` ones; the only difference is the prefix word; no behavioural change |

### Option B — `Spike` with own required-section schema + opt-in label-based exemption + close skill

`Spike` gets its own required-section list (`Hypothesis`, `Budget`, `Kill Criteria`, `Disposition` — drops User Story / AC). AgDR-required hooks detect `[Spike]` ticket prefix, `spike` PR-title type, OR `spike/` branch prefix and skip. Coverage hooks (when added) read the same signal. A sibling `/spike-close` skill enforces the disposition gate via prompts (PROMOTE writes a follow-up `[Feature]`, DISCARD writes a memo to `docs/spike-memos/<slug>.md`).

| Pros | Cons |
|------|------|
| Addresses all three problems coherently | More surface — new skill, new template, new exemption logic in two hooks |
| Schema differences mirror the conceptual difference (a spike's contract IS a hypothesis, not a story) | Disposition gate is prose-only on the close path — no hard block; relies on operator running `/spike-close` |
| Uses existing config layer (`.claude/project-config.defaults.json`) — no new mechanisms | Three exemption signals to maintain (prefix / label / branch); detection complexity grows linearly |
| Hooks read schema from defaults, so adopters can add or rename via `.claude/project-config.json` | Adopters who customise `prefix_whitelist` to drop `Spike` get a graceful warning from the skill, not a hard pass-through |

### Option C — Boolean `is_throwaway` flag on every ticket type instead of a separate `Spike` type

Add a flag like `throwaway: true` to any ticket; the AgDR / coverage hooks read the flag and skip. No new ticket type, no new whitelist entries.

| Pros | Cons |
|------|------|
| Schema stays simple — one new optional field instead of a new ticket class | "Throwaway feature" / "throwaway bug" are concept collisions — a feature that ships is not throwaway, by definition |
| Could in theory apply to `[Feature]` for a v0 prototype | The hypothesis-driven schema (Hypothesis / Budget / Kill / Disposition) is structurally different from a user story; one schema can't host both |
| | Disposition gate has no natural home — `[Feature]`-with-flag would close on QA sign-off, not via `/spike-close` |
| | Upgrade path is awkward — promoting a "throwaway feature" to a "real feature" is the same ticket with the flag flipped, leaving no trail of what was learned |

## Decision

Chosen: **Option B — `Spike` with own schema, three-signal exemption detection, and `/spike-close` disposition gate.**

Three reasons it wins:

1. **Schema asymmetry IS the right shape.** Hypothesis / Budget / Kill Criteria / Disposition are not a subset or superset of User Story / Acceptance Criteria — they describe a different kind of work product. Trying to share the schema (Option C) confuses both. A separate ticket class makes the conceptual difference visible at the prefix level.

2. **The exemption set must be surgical.** Code review (Rex) and the security auditor stay required. Even throw-away code can leak secrets, mishandle PII, or cargo-cult an attack vector into "the way we do it". The exemption removes the gates whose purpose is to capture *durable* decisions (AgDR) or *long-term* quality (coverage). This is why the rule lands as a per-gate table, not a blanket "spikes opt out of the SDLC".

3. **Disposition gate motivated by cost-of-omission, not hard-block.** A hard block on `gh issue close <spike>` until `/spike-close` runs would be the strict version. Rejected because (a) it's hard to enforce reliably across all close paths (web UI close, `gh issue close` directly, auto-close from PR body), and (b) the cost of forgetting the gate is the loss of one memo / one follow-up — bad, but not catastrophic. Prose-only with a strong prompt + the operator's natural incentive to capture findings is enough. If the gate gets routinely skipped in practice, the next iteration can add the hard block.

### Why `Spike` over `POC`

- `branch.type_whitelist` already has `spike` (#180's "today's partial scaffolding"). Renaming would orphan whatever spike branches existed pre-#180.
- "Spike" is the canonical Agile term and the engineer-audience word. "POC" / "Proof of Concept" is the broader business term, more common in stakeholder conversation. The framework targets the engineering audience first; stakeholder language can ride along in the title (`[Spike] POC: replace Auth0 with Cognito`).
- Adopters who prefer `POC` can override `.ticket.prefix_whitelist` in their fork to add `POC` alongside or in place of `Spike` — the validate-issue-structure hook is whitelist-driven (#109), so the rename is a one-line config change.

### Three-signal exemption detection

Detection prefers **any one match wins**, not "all three must match", because the agent is rarely standing on all three at the same time:

| Signal | Where it lives | When it's available |
|--------|----------------|---------------------|
| PR title type = `spike(...)` | The PR title at `gh pr create` time | At PR-create time. Cleanest signal — the PR is already shaped as a spike |
| Active ticket marker title starts with `[Spike]` | `.claude/session/{current-ticket,tickets/<project>}` | Whenever `/start-ticket` ran |
| Branch name starts with `spike/` | `git branch --show-current` | Whenever the operator created the branch |

The redundancy is deliberate. An operator who created the branch via `git checkout -b spike/GH-123-x` but never ran `/start-ticket` should still get the exemption. An operator inside a managed-project clone where the per-project marker resolves correctly should still get the exemption when their PR title carries `spike(N): ...`.

### Disposition gate — PROMOTE / DISCARD only

The disposition gate forbids "decide later" because that's the failure mode the gate exists to prevent. A spike that "succeeded" but never decides what to do with the code is the worst-of-both case — neither shipped nor cleaned up. The gate forces the binary choice in advance (at ticket creation, in the `Disposition` field) and again at close time (via `/spike-close --promote | --discard`).

Both branches produce a durable artefact:

- **PROMOTE** files a fresh `[Feature]` with a "Spike findings" section that links back to the spike. The new feature goes through full SDLC; the spike branch is NOT lifted into production. The cross-reference is the trail.
- **DISCARD** writes a memo to `docs/spike-memos/<slug>.md` that captures the hypothesis, the finding, why we're not pursuing, and what would change the answer. The memo is the trail.

## Consequences

### Now safer

- The schema asymmetry is closed — `branch`, `commit`, `pr.title_type_whitelist`, `ticket.prefix_whitelist` all align on `spike`. A `spike/<TICKET-ID>-<slug>` branch + `spike(N): subject` commits + `spike(#N): description` PR title + `[Spike] title` ticket all validate cleanly.
- AgDR-required hooks no longer block exploration work that legitimately doesn't merit an AgDR. Authors no longer skip the exploration to avoid the ceremony.
- Disposition rot is structurally discouraged. The `Disposition` field is required at ticket-creation time; `/spike-close` makes the closing artefact (follow-up feature OR memo) one command away. The path of least resistance now produces the artefact.

### Now riskier

- Three-signal detection is heuristic. A spike-branch operator who carelessly retitles their PR to `feat(N): ...` (not `spike(N): ...`) and has no active-ticket marker but kept the `spike/` branch name would still get the exemption — *correctly*, because the branch name is a strong signal. But if they renamed their branch off `spike/` mid-flow, the exemption silently disappears. Acceptable: the signal-redundancy is meant to catch operator-shaped exemptions, not to be airtight.
- Disposition gate is prose-only on close. An operator who closes the spike via the GitHub web UI without running `/spike-close` skips both artefacts. Cost is the loss of one memo / one follow-up; recoverable by re-opening the spike and running the gate.
- Skill cooperation matters. `/spike` writes the `spike` label; the AgDR-PR hook reads either the label OR the PR-title type OR the branch. An operator who files a spike-shaped ticket via raw `gh issue create` without the `spike` label still gets exemption via the title-prefix signal — but the label-driven fork, where adopters extend the exemption to e.g. CI pipelines, requires the label to be present.

### Now slower

- N/A — exploration work is the use case that this slows down least. Spikes are explicitly scoped to 1-3 days; the exemptions remove the gates that would have added days.

### Future work

- **Hard-block disposition gate.** If `/spike-close` is routinely skipped in practice (measurable: count of closed `spike`-labelled issues with no follow-up `[Feature]` cross-ref AND no `docs/spike-memos/` commit linked to the spike, over the trailing N closures), revisit and add a `block-spike-close-without-disposition.sh` PreToolUse hook on `gh issue close`.
- **Auto-deletion of spike branches after disposition.** Currently manual ("Delete the spike branch once the memo PR merges"). A `/spike-cleanup` skill could find closed-spike branches and offer batched deletion. v2.
- **Cross-project spikes.** A spike spanning multiple managed projects. v1 is single-project; the disposition gate's PROMOTE branch assumes the new `[Feature]` lives in the same repo as the spike. v2 question.
- **Integration with `/validate-idea`.** `/validate-idea` is a 5-question pre-spec gate. `/spike` is a post-validate-pre-feature exploration. Their relationship is "validate-idea answers 'is the problem worth solving', spike answers 'is the technical approach feasible'". An idea that passes `/validate-idea` and has technical risk could chain into `/spike` via an offered follow-up. Out of scope for this AgDR.

## Artifacts

- `me2resh/apexyard#180` — feature ticket
- `.claude/project-config.defaults.json` — schema additions (`Spike` prefix, `Spike` required-sections, `spike` commit type, `spike` PR-title type)
- `.claude/skills/spike/SKILL.md` — new skill
- `.claude/skills/spike-close/SKILL.md` — disposition-gate skill
- `templates/spike.md` — ticket template
- `.claude/hooks/require-agdr-for-arch-pr.sh` — spike-PR exemption (3-signal)
- `.claude/hooks/require-agdr-for-arch-changes.sh` — spike-commit exemption (2-signal)
- `.claude/hooks/validate-issue-structure.sh` — `Spike` whitelist + `Spike` required-sections inline fallback + `/spike` skill suggestion
- `.claude/hooks/validate-pr-create.sh` — `spike` in PR-title-type fallback
- `.claude/hooks/validate-commit-format.sh` — `spike` in commit-type fallback + BLOCKED message
- `.claude/rules/workflow-gates.md` — § "Spike work" rule statement
- `workflows/sdlc.md` — Phase 1 sidebar
- `.claude/hooks/tests/test_validate_issue_structure.sh` — `[Spike]` accepted; required-sections enforced
- `.claude/hooks/tests/test_require_agdr_for_arch_pr.sh` — spike PR-title / branch / marker exemptions
