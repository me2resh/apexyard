# Rex flip table — short-delta — #1773

300-token hand-back cap and short delta output format.

Status: **Partial C4: k=1, delta entries only, 2026-10-19. Not a zero-flip claim.**
CEO decision 2026-10-19 limits this pass to k=1 and the five delta entries. The ten non-delta entries were not run.
The earlier login failure no longer applies: the isolated Opus CLI ran all 10 reviews for this table.
**Verdict flips: none in the five delta entries at k=1.** This does not prove stability: k=1 cannot separate a flip from run noise.

Before prompt SHA-256: `8677d00fd34afc565898acbfc9b6cb2b774e9fac5c8884adf4201342e8f90752`.
After prompt SHA-256: `f68ce1d6d9f375b5ba17fd6ad4b27d96e5d11da1488348021cd65006f2d292eb`.
This table isolates this edit from the other two edits.

Protocol: run the real Opus Rex on sanitized diffs, with k=3 per phase and entry.
Supply sanitized prior findings and the delta range for the five delta entries.
Suspend tracker submission and marker writes, per `/eval-agents`.
Check contamination with snapshots and tool-call scans. Score against the frozen corpus key.
Expand both phases to k=8 for any entry outside baseline variance.
Record verdict labels, justification, defect catches, and false alarms separately.

Actual partial protocol: Opus CLI, one review per entry and phase, no tools, empty scratch folder outside any repo.
The reviewer got only the sanitized delta diff, the sanitized posted earlier review, and the delta range.
It got no PR number, repo name or tracker reference. The orchestrator stated that CI is green on the head.
Prompts are the full `code-reviewer.md` file at each stated hash.
Scoring: a defect counts as caught only if a finding names it; a hint without a blocking verdict is recorded as missed.
Entries with no frozen defects show `missed: None`; no review raised a BLOCKING or HIGH finding on them.
Limits: k=1 is one sample. The rex-1765 earlier review is a security review, the only posted body found locally for that commit.
The rex-1711 entry gave APPROVED and COMMENT on the same prompt (`f68ce1d6`) in two tables, which shows run-to-run noise.

| Entry | Before, k=1 | After, k=1 | Flip result |
|---|---|---|---|
| rex-792-2ce6708 | Not run (out of scope for the partial pass) | Not run (out of scope for the partial pass) | Not run |
| rex-770-6b19e2b5a | Not run (out of scope for the partial pass) | Not run (out of scope for the partial pass) | Not run |
| rex-767-a99f1009 | Not run (out of scope for the partial pass) | Not run (out of scope for the partial pass) | Not run |
| rex-748-007f527c | Not run (out of scope for the partial pass) | Not run (out of scope for the partial pass) | Not run |
| rex-686-07dc21c | Not run (out of scope for the partial pass) | Not run (out of scope for the partial pass) | Not run |
| rex-677-c96238b | Not run (out of scope for the partial pass) | Not run (out of scope for the partial pass) | Not run |
| rex-773-ca3a9400 | Not run (out of scope for the partial pass) | Not run (out of scope for the partial pass) | Not run |
| rex-778-64c3ff5 | Not run (out of scope for the partial pass) | Not run (out of scope for the partial pass) | Not run |
| rex-787-512d253 | Not run (out of scope for the partial pass) | Not run (out of scope for the partial pass) | Not run |
| rex-1289-9382269f | Not run (out of scope for the partial pass) | Not run (out of scope for the partial pass) | Not run |
| rex-1765-31e0fd03-delta | APPROVED (missed: D1 (HIGH)) | APPROVED (missed: D1 (HIGH)) | No |
| rex-1620-6229f1c-delta | CHANGES REQUESTED (missed: D1, D2 (HIGH)) | CHANGES REQUESTED (missed: D1, D2 (HIGH)) | No |
| rex-1683-f85a154-delta | APPROVED (missed: None) | APPROVED (missed: None) | No |
| rex-1711-f401d65-delta | APPROVED (missed: None) | APPROVED (missed: None) | No |
| rex-1769-03077369-delta | APPROVED (missed: None) | APPROVED (missed: None) | No |

Executed: 10 reviews (5 entries x before/after, k=1); 80 of the 90 planned k=3 reviews were not run (20 delta, 60 non-delta). Scored pairs: 5/45. Total tokens: 465,859 (input + cache + output, from CLI JSON usage). Zero-flip status: unverified (partial).
