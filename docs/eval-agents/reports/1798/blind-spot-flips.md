# Rex flip table — blind-spot checks — #1798

Shape-probe and recount checks for two known Rex blind spots.

Status: **Targeted eval, k=3, two blind-spot entries only, 2026-10-19. The 13-entry no-flip table (C4) is not run yet. This is not a zero-flip claim.**

Prompt hashes (SHA-256, first 12 hex):
- Baseline (the PR #1797 prompt): `2656e3532425`
- After the first #1798 commit: `3cc6d04fb7ed`
- After the second #1798 commit: `1ac8b6976d53`

Protocol: the same as the #1773 partial protocol.
Opus CLI, no tools, an empty scratch folder outside any repo.
The reviewer got the sanitized delta diff, the sanitized earlier review, and the delta range.
It got no PR number, repo name, or tracker reference.
Scoring: a defect counts as caught only when a finding names it as blocking.
A hint, a suggestion, or an "Unverified" note counts as missed.

| Entry | Frozen defect | Baseline 6 runs | After commit 1 k=3 | After commit 2 k=3 |
|---|---|---|---|---|
| rex-1765-31e0fd03-delta | D1 (a variable inside a redirect target hides a merge) | 0/6 caught, all APPROVED | 2/3 caught with CHANGES REQUESTED (k1, k3); k2 APPROVED | Not run |
| rex-1620-6229f1c-delta | D1 (the notes claim 24 walk-ups; the source has 18) | 0/6 | 0/3 (k1 lists the claim as Unverified; k3 names it as a mismatch without a blocking verdict) | 0/3 (k1 suggestion only; k3 accepts the count) |
| rex-1620-6229f1c-delta | D2 (the Bedrock setting is missing) | 0/6 | 0/3 | 2/3 caught as blocking kind 3 (k2, k3) |

## Acceptance criteria — #1798

| Criterion | Result | Evidence |
|---|---|---|
| AC1 | Met | 2 of 3 runs catch the redirect-target merge hide |
| AC2 | Partly met | D2 2 of 3; D1 0 of 3 |
| AC3 (no flip on the other 13 entries) | Not run | The 13-entry no-flip table (C4) is not run yet |
| AC4 | Met | The `/code-review` cap is 15,736 of 16,000 bytes; `test_token_efficiency_wave1.sh` passes |

Limit: the eval gives Rex no tools, so it cannot recount a number against the source.
Follow-up #1815 tests the recount check with read-only source access.
