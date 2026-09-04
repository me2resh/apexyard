# Human-friendly text regression cases

These cases are human-adjudicated inputs for `.claude/rules/writing-standard.md` (me2resh/apexyard#1164). Each one describes a task, an observable failure, and an observable pass. A static shell test cannot score them; a person or a behavioral evaluator (me2resh/apexyard#1165) must.

## HF-01 — Opening states the outcome and next action

- **Given**: A PR is open, Rex approved it, and CI is green.
- **Prompt**: `Write the status update.`
- **Fail if**: The update opens with a table of checks, a marker path, or a hook name, and the reader must scan to learn that the PR is ready and needs their approval.
- **Pass if**: The first sentences say the PR is ready, why it matters, and that the reader's next action is the per-PR approval.

## HF-02 — Empty conditional section is deleted

- **Given**: A feature ticket is being filed and the interview produced no design notes and no out-of-scope items.
- **Prompt**: `File the ticket.`
- **Fail if**: The filed body contains "## Design Notes" with "N/A", "None", or a placeholder under it.
- **Pass if**: The filed body omits the Design Notes and Out of Scope sections and keeps the required User Story, Acceptance Criteria, and Glossary.

## HF-03 — No placeholder survives

- **Given**: A PRD draft is complete except for a launch date that nobody has set.
- **Prompt**: `Finalise the PRD.`
- **Fail if**: The document contains `[Feature Name]`, `YYYY-MM-DD`, `{{...}}`, or the template's guidance comment.
- **Pass if**: Every placeholder is replaced, the unknown date reads `TBD`, and the guidance comment is gone.

## HF-04 — Strict mode block message

- **Given**: A hook must refuse a merge because the Rex marker is missing.
- **Prompt**: `Write the block message.`
- **Fail if**: The message buries the reason in a paragraph, uses "should", or gives two instructions in one sentence.
- **Pass if**: The message states what was blocked in one line, why in one sentence, the fix as imperative steps, and the rule path.

## HF-05 — Strict mode spawn brief

- **Given**: An orchestrator briefs a build agent on a ticket.
- **Prompt**: `Write the brief.`
- **Fail if**: A sentence carries two instructions, an instruction uses "may", or the same artifact has two names in the brief.
- **Pass if**: Each sentence carries one instruction, conditions come before instructions, and every identifier appears verbatim.

## HF-06 — Flavored mode keeps uncertainty and precision

- **Given**: An investigation note says "the expired token may have caused the failure at commit 1b12123".
- **Prompt**: `Tighten this section.`
- **Fail if**: The rewrite says the token caused the failure, or drops the SHA.
- **Pass if**: The rewrite is shorter and keeps `may` and the SHA.

## HF-07 — Conversation is not forced into Strict mode

- **Given**: The operator asks in chat why an approach was chosen.
- **Prompt**: `Why did you go with a single rule file?`
- **Fail if**: The reply reads like a numbered procedure with no explanation or voice.
- **Pass if**: The reply is a plain conversational answer that gives the reason.

## HF-08 — Durable PR and review artefacts use Flavored mode

- **Task**: Draft a PR description and review comment for a small framework fix.
- **Fail if**: The text opens with process logs, repeats internal workflow steps, or uses long dense paragraphs before stating the result.
- **Pass if**: Both artefacts lead with the outcome and next action, use short plain sentences, preserve uncertainty, and place supporting evidence after the opening.

## HF-09 — Durable artefact producers carry the central rule

- **Task**: Add or update a ticket, design, audit, threat model, handover, or roadmap document.
- **Fail if**: The producer has no explicit reference to the central writing standard and silently falls back to its own prose conventions.
- **Pass if**: The producer names Flavored mode and keeps required, conditional, placeholder, and modality rules aligned with `writing-standard.md`.
