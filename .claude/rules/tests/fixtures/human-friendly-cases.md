# Controlled technical writing regression cases

These cases test the writing rule for new and changed artifacts. A reviewer
judges the text. Static tests check that each producer and reviewer loads the
rule.

## HF-01 — Opening states the outcome and next action

- **Given**: A PR is ready for approval.
- **Prompt**: Write the status update.
- **Fail if**: The reader must scan a process log to find the result.
- **Pass if**: The opening states the result, reason, and next action.

## HF-02 — Empty conditional section is deleted

- **Given**: A ticket has no design notes.
- **Prompt**: File the ticket.
- **Fail if**: The ticket has an empty Design Notes section.
- **Pass if**: The ticket omits the empty section.

## HF-03 — No placeholder survives

- **Given**: A PRD has no launch date.
- **Prompt**: Finalize the PRD.
- **Fail if**: The PRD has a template placeholder.
- **Pass if**: The PRD uses TBD for the unknown date.

## HF-04 — Machine instruction uses one action

- **Given**: A hook must block a merge.
- **Prompt**: Write the block message.
- **Fail if**: One sentence has two instructions.
- **Pass if**: Each instruction uses one short sentence.

## HF-05 — Agent brief uses clear terms

- **Given**: An orchestrator gives a build task to an agent.
- **Prompt**: Write the brief.
- **Fail if**: The brief uses two names for one artifact.
- **Pass if**: Each term has one meaning.

## HF-06 — Artifact retains uncertainty

- **Given**: A note says commit `1b12123` may have caused an expired-token failure.
- **Prompt**: Improve the note.
- **Fail if**: The rewrite removes may or the commit identifier.
- **Pass if**: The rewrite is clear and retains the uncertainty and identifier.

## HF-07 — Conversation stays outside this rule

- **Given**: An operator asks why a decision was made.
- **Prompt**: Explain the decision.
- **Fail if**: The reply reads as a procedure with no explanation.
- **Pass if**: The reply gives a plain reason.

## HF-08 — PR and review use the profile

- **Given**: A framework fix needs a PR body and a structured Rex review under the controlled technical writing profile.
- **Prompt**: Draft both artifacts using Rex's Output Format. Then show a shorter re-review after one finding is fixed. Finally show a reduced-scope variant for an eligible docs-only change. Preserve required sections, checklist reasons, validation results, and verification limits in each version. Mark unavailable evidence as unverified.
- **Fail if**: A sentence has more than 25 words or uses a semicolon. Any review omits required sections, checklist reasons, validation results, or verification limits. The review marks an unperformed check as Pass or invents evidence.
- **Pass if**: Both artifacts use short sentences, active voice, and clear terms while retaining required sections and supporting evidence.

## HF-09 — Producers load the profile

- **Given**: An agent creates a ticket, design, audit, or roadmap.
- **Prompt**: Draft the artifact.
- **Fail if**: The producer does not load the central writing rule.
- **Pass if**: The producer names the controlled technical writing profile.

## HF-10 — Reviewer rejects a profile fault

- **Given**: A PR body uses dense text and inconsistent terms.
- **Prompt**: Review the PR.
- **Fail if**: The review approves the PR without a writing finding.
- **Pass if**: The review requests changes and names the failed profile rule.
