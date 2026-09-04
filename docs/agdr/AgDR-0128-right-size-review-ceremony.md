# Right-size review triggers and handbook applicability

> In the context of review feedback that small hook-test and documentation changes consumed full Heavy ceremony, facing a broad trust-chain path trigger and handbook instructions that treated every candidate as applicable, I decided to distinguish production controls from their tests and require handbook applicability triage before reading, to preserve safety while reducing unrelated review work, accepting that ambiguous enforcement changes still round up to Heavy.

## Context

- Production hook scripts and matcher settings enforce governance and must keep the Heavy Security Auditor path.
- Test fixtures under `.claude/hooks/tests/**` exercise those controls but are not controls themselves.
- Rex's handbook discovery previously described architecture and general candidates as always applicable, which made unrelated guidance look like required review work.
- The right-size rule requires ambiguity to round up, so this change must not weaken review when a test changes enforcement semantics.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Exclude hook tests by path and triage handbook applicability** | Removes the measured over-ceremony while preserving production-control and blocking-handbook safeguards | Requires reviewers to make an explicit applicability judgment |
| Keep every `.claude/hooks/**` path Heavy and load every handbook | Simple, conservative | Repeats the disproportionate review cost this task addresses |
| Add a self-declared bypass flag | Easy to implement | Creates a forgeable gate-relaxing surface and weakens trust |

## Decision

Chosen: **exclude test-only hook paths from the automatic Security Auditor trigger and require handbook applicability triage**, because tests do not enforce governance, while production controls and genuinely applicable blocking handbooks retain their existing Heavy behavior. If a test changes enforcement semantics or the reviewer is unsure, the ambiguity rule rounds the work up.

## Consequences

- `.claude/hooks/tests/**` no longer triggers Security Auditor by path alone; production `.claude/hooks/*.sh` and `.claude/settings.json` still do.
- Rex may discover handbook candidates, but it reads and reports only those applicable to the changed paths or substantive commit content.
- Blocking handbooks remain blocking whenever applicable.
- The path distinction is advisory trigger behavior, not a replacement for security review when the test changes a control's semantics.

## Artifacts

- Ticket: me2resh/apexyard#1171
- PR: me2resh/apexyard#1172
