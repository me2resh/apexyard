# Escalation pattern

Agents settle work within their authority. They return decisions outside that authority to the operator.
The [reporting rule](../.claude/rules/reporting-style.md#human--vague) requires agents to name decisions that need the operator and stop.
A gate is a required check before work proceeds, as defined by the [workflow gates](../.claude/rules/workflow-gates.md).

## What an agent settles alone

An agent chooses local names, helpers, control flow, and tests within the ticket.
These reversible choices need no decision record under the [material decision rule](../.claude/rules/agdr-decisions.md#the-threshold).
The [ceremony rule](../.claude/rules/right-size-ceremony.md) requires the smallest change that meets the acceptance criteria.

The builder fixes review findings. Reviewers report findings and leave edits to the builder or orchestrator.
The [review boundary](../.claude/rules/pr-workflow.md#review-class-agents-are-read-only) assigns those duties.
Retries can continue within a bounded build and verification loop.
The [loop guardrails](../.claude/rules/loop-mode.md#guardrails-the-loop-must-not-run-off-a-cliff) require iteration limits, verification, and a stop when progress ends.
They also require the loop to stop at the human merge gate.

Ticket-first means declaring an active ticket before governed edits.
The [pre-build gate](../.claude/rules/workflow-gates.md), [/start-ticket](../.claude/skills/start-ticket/SKILL.md), and
[ticket hook](../.claude/hooks/require-active-ticket.sh) define the requirement, marker, exemptions, and block.
Other hooks stop specific actions:

- The [secrets hook](../.claude/hooks/check-secrets.sh) blocks commits when its staged-diff scan detects potential secrets.
- The [protected-branch hook](../.claude/hooks/block-main-push.sh) blocks direct commits and pushes to protected branches.
- The [merge gate](../.claude/hooks/block-unreviewed-merge.sh) checks review and human approval records.
- The [CI gate](../.claude/hooks/block-merge-on-red-ci.sh) blocks merges without passing continuous integration checks.

A retry must not bypass a block. The [workflow rule](../.claude/rules/pr-workflow.md#build-agents-cannot-self-review) requires agents to stop and report it.

## What review agents settle

A review verdict assesses work. It does not grant human merge authority.
The [workflow rule](../.claude/rules/pr-workflow.md) requires both independent review and explicit human approval.
Each reviewer has a distinct remit:

- [Rex](../.claude/agents/code-reviewer.md) reviews code and correctness. He reports findings and an approval or changes-requested verdict.
- [Hakim](../.claude/agents/security-reviewer.md) reviews security risks and remediation. His visible review does not supply a merge-gate marker.
- [Tariq](../.claude/agents/solution-architect.md) reviews designs and architectural decisions. His architecture sign-off does not approve a merge.
- [Naqid](../.claude/agents/contrarian.md) challenges premises after stating their strongest case. His advice never blocks a gate or writes a marker.

A build agent cannot independently review or approve its own work.
The [self-review rule](../.claude/rules/pr-workflow.md#build-agents-cannot-self-review) forbids impersonating a reviewer or writing approval markers.
The [marker warning](../.claude/hooks/warn-review-marker-write.sh) is advisory.
The [reviewer mutation hook](../.claude/hooks/block-reviewer-repo-mutation.sh) and
[write limiter](../.claude/hooks/limit-reviewer-writes.sh) constrain reviewers while their active marker exists.
The [merge gate](../.claude/hooks/block-unreviewed-merge.sh) checks the approval records, rather than accepting a builder's completion report.

## What reaches a named person

The [reporting rule](../.claude/rules/reporting-style.md#human--vague) requires agents to surface decisions that need the operator's call.
The following boundaries explain when to return that call:

- **Material decision:** An Agent Decision Record (AgDR) captures context, options, the choice, and consequences.
  The [decision rule](../.claude/rules/agdr-decisions.md) requires it for architectural, cross-cutting, or hard-to-reverse choices.
  [/decide](../.claude/skills/decide/SKILL.md) records the choice, but does not require a named person's approval. See Gaps.
- **Choice between options:** The orchestrator asks the operator through `AskUserQuestion`.
  The [operator choices rule](../.claude/rules/reporting-style.md#operator-choices) specifies the menu and a numbered-list fallback.
- **Scope change:** The [ceremony rule](../.claude/rules/right-size-ceremony.md) limits implementation to the acceptance criteria.
  The [product role](../roles/product/product-manager.md) forbids roadmap changes without approval and reserves new ideas for the Head of Product.
  These boundaries do not define a universal named human for every scope change. See Gaps.
- **Merge approval:** The human approves a specific pull request (PR), at its exact head commit identifier (SHA).
  [/approve-merge](../.claude/skills/approve-merge/SKILL.md) rejects umbrella approval and records the checked SHA.
  Its menu names the repository, PR, and full SHA.
  The [merge gate](../.claude/hooks/block-unreviewed-merge.sh) requires structured approval and checks it against the current head.
  It permits verified carry-over for a conflict-free base replay. Otherwise, a changed head requires fresh approval.

## Evidence each step leaves

[Rex](../.claude/agents/code-reviewer.md), [Hakim](../.claude/agents/security-reviewer.md), and [Tariq](../.claude/agents/solution-architect.md) post visible review comments with findings and verdicts.
Their definitions specify posting failures and required local records.
[Naqid](../.claude/agents/contrarian.md) returns an advisory challenge, not an approval record.

[/decide](../.claude/skills/decide/SKILL.md) writes AgDRs in the project's `docs/agdr/` directory.
[/approve-merge](../.claude/skills/approve-merge/SKILL.md) records the SHA, `approved_by=user`, timestamp, skill version, and approval summary.
The [menu recorder](../.claude/hooks/record-menu-approval.sh) writes menu approval records.
The [merge gate](../.claude/hooks/block-unreviewed-merge.sh) validates their additional fields.

A progress note can explain the current result, blocker, and next action.
The [reporting rule](../.claude/rules/reporting-style.md) defines that status report, but does not require a durable progress-note file.
The [build handoff rule](../.claude/rules/pr-workflow.md#build-agents-cannot-self-review) requires build results and test outcomes.

## Gaps

Each item below needs an owner decision. This page adds no controls.

- **Human authority:** Decide which material decisions and scope changes require a named human, and where to record that person's identity.
  [/decide](../.claude/skills/decide/SKILL.md) lets the agent choose.
  The [product role](../roles/product/product-manager.md) assigns role authority, rather than a universal human approval gate.
- **Reviewer identity:** Decide whether the advisory marker-write boundary needs stronger enforcement.
  The [self-review rule](../.claude/rules/pr-workflow.md#mechanical-backstop) and [warning hook](../.claude/hooks/warn-review-marker-write.sh) explicitly say it does not block writes.
  Structured fields in the [merge gate](../.claude/hooks/block-unreviewed-merge.sh) do not prove human identity by themselves.
- **Decision coverage:** Decide whether more material decisions need mechanical checks.
  The [AgDR enforcement limits](../.claude/rules/agdr-decisions.md#enforcement--and-the-honest-limits-of-it) describe bounded hook paths and an explicit PR bypass.
- **Retry and choice discipline:** Decide whether advisory rules need further controls.
  The [loop rule](../.claude/rules/loop-mode.md) and [reporting rule](../.claude/rules/reporting-style.md#backstop) rely on agent discipline.
- **Progress history:** Decide whether every escalation needs a durable progress note.
  The [reporting rule](../.claude/rules/reporting-style.md) governs status messages, without requiring that file.
