# AgDR-0207: Pin CI snapshot proofs to full commit SHAs

> In the context of CI snapshot proofs for reviewed hook trees, facing short SHA ambiguity as history grows, I decided to pin each snapshot by its full 40-character SHA and verify each object after the fetch. This keeps fail-before proofs tied to the reviewed commits and fails the job with a clear message when one is missing.

## Context

Hakim reviewed PR #1496. The CI job fetches `refs/pull/1466/head` and loads snapshot hook code by 7-character SHAs. Short SHAs can become ambiguous as history grows. A fork that runs the workflow resolves its own copy of the PR ref. AgDR-0199 already requires the fetch and a missing-snapshot failure. It did not pin full SHAs or verify them after the fetch.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep short SHAs | Smaller diff | Ambiguous as history grows |
| Pin full SHAs in the test only | Must-block archive is exact | CI still trusts the fetch tip alone |
| Pin full SHAs and verify after fetch | Exact pins. Clear CI failure | Workflow step is longer |

## Decision

Chosen: **pin full 40-character SHAs and verify each after the fetch**.

- The workflow lists the three full SHAs after it fetches `refs/pull/1466/head`.
- Each SHA must exist as a commit object via `git cat-file -e`.
- A missing object prints `CI snapshot proof failed: commit <sha> is not present after fetching refs/pull/1466/head` and exits non-zero.
- The must-block test archives the same full SHAs for fail-before proofs.

## Consequences

- Snapshot proofs stay tied to the reviewed commits even when short prefixes collide.
- CI fails before the hook suite when a pinned commit is absent from the fetched ref.
- AgDR-0199 remains the snapshot-fetch decision. This record narrows the pin and verify contract.

## Artifacts

- Issue #1505
- `.github/workflows/tests.yml`
- `.claude/hooks/tests/test_command_scrub_must_block.sh`
- `.claude/hooks/tests/test_ci_snapshot_proofs.sh`
- AgDR-0199 (updated)
