# Validate the Rex review body before writing the approval marker

> In the context of Rex posting a review and writing `*-rex.approved`, facing an Output Format that was instruction-only, I decided to validate the local review body file inside `_lib-review-markers.sh` before the marker write, to refuse a SHA write when required sections are missing, accepting that a raw redirect can still bypass the helper.

## Status

Accepted

## Context

A debug of me2resh/apexyard#1320 on 2026-09-17 showed two posted reviews that did not match the Output Format in `.claude/agents/code-reviewer.md`.

One review had `### Checklist Results` and omitted `### Validation`. One review was a GitHub `APPROVED` state with an empty body. `tracker_review_submit` accepts any Markdown. The Rex marker is a bare SHA. `block-unreviewed-merge.sh` compares that SHA to forge HEAD. It does not read the review body. `test_writing_standard.sh` checks headings in the agent template. It does not check a posted body.

Parent records: AgDR-0075 (local marker is the gate signal) and AgDR-0062 (marker authenticity).

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep instruction-only Output Format | No trust-chain change | A missing section still produces a valid SHA marker |
| Validate the local body file in a write helper, then write the SHA | Couples marker write to the required headings. Merge gate stays SHA-only. No host JSON parse | A raw `printf SHA > marker` still bypasses. That remains a visible rule break |
| Parse the host review after `tracker_review_submit` | Checks what humans see | Fails for `tracker.kind=none`. Binds the gate to host JSON. Ticket forbids this |
| Bind `block-unreviewed-merge.sh` to GitHub review JSON | Host is the source of truth | Breaks AgDR-0075. Single-account cannot approve its own PR |

## Decision

Chosen: **validate the local body file in a write helper**, because the ticket needs a mechanical check without changing the merge-gate SHA contract.

`review_validate_rex_body` reads the body file. It requires these headings:

- `## Code Review`
- `### Summary`
- `### Checklist Results`
- `### Issues Found`
- `### Validation`
- `### Verdict`
- a `Reviewed commit` footer

`review_write_rex_approved` calls that check. It also refuses `CHANGES REQUESTED` and empty bodies. It writes the same bare SHA plus newline as today.

Rex calls the helper instead of a raw redirect. `tracker_review_submit` still posts. The merge gate still reads only the SHA.

## Consequences

- A body that omits `### Validation` cannot write a Rex marker through the helper.
- A `## Checklist` heading does not satisfy `### Checklist Results`.
- Submit and marker stay independent on the host. The coupling is local and happens before the write.
- A raw marker redirect remains possible. AgDR-0111 keeps the write hook advisory. This ticket does not reopen that gate.
- `tracker.kind=none` still validates a local body file.

## Artifacts

- Issue: me2resh/apexyard#1322
- Files: `.claude/hooks/_lib-review-markers.sh`, `.claude/agents/code-reviewer.md`, `.claude/hooks/tests/test_validate_rex_review_body.sh`
- Related: AgDR-0075, AgDR-0062, AgDR-0111
