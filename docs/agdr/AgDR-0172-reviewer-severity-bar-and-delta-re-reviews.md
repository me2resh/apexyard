---
id: AgDR-0172
timestamp: 2026-09-27T06:25:55Z
agent: platform-engineer
model: claude-opus-5.5
session: session_01KGvb2ba4gyT3TN8L2uMLTn
trigger: user-prompt
status: executed
category: patterns
projects: [apexyard]
---

<!-- Uses the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Give reviews a blocking-severity bar, a delta scope, and a round cap

> In the context of the framework's own review-fix loop, we faced review
> rounds that cost 10 to 15 minutes each and sometimes ran five or six deep.
> I decided to add a four-kind blocking-severity bar, a delta re-review
> scope, CI-first testing, and a two-round cap to Rex and Hakim. I accepted
> that a self-bypass edge case or a writing nit can now reach merge as an
> advisory note instead of a blocking finding.

## Context

me2resh/apexyard#1418 measured seven merged framework PRs. A PR that passed
review in one or two rounds merged within hours. A PR that went through five
or six rounds took most of a day. The issue names five causes:

1. Reviewers treated writing-profile nits and self-bypass edge cases as
   blocking, so each one forced another full round.
2. A re-review re-read the whole diff and re-ran the full suite, when only
   the fix commits had changed.
3. The full suite ran three times: the builder, each reviewer, and CI.
4. No cap on review rounds let a later round keep finding new advisory
   points.
5. The controlled technical writing profile had no severity distinction, so
   `.claude/rules/writing-standard.md` told a reviewer to request changes
   for any profile fault, including a nit with no effect on meaning.

The issue scopes this PR to items 1, 2, 3, 4, 5, and 7 of its proposed
behaviour. Item 6, an advisory sentence-check script wired into pre-push, is
a separate later PR — a script cannot see the review's own reasoning, and it
does not touch reviewer agent prose.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Add a blocking-severity bar (four kinds: regression, code-execution or approval-bypass vector, correctness bug, failed acceptance criterion) with every other finding advisory (chosen) | Removes the two most common false-blocking causes — self-bypass edge cases and writing nits — without touching the merge gate | A reviewer must classify each finding correctly. A wrong classification could let a real correctness bug through as advisory |
| Keep every finding blocking, and instead cap review rounds only | Simpler. One change | Leaves the root cause (over-broad blocking) in place. A round cap alone still forces a follow-up ticket for findings that never needed to block at all |
| Give reviewers a full re-clone and full re-run on every re-review (status quo) | Simple, no new procedure to follow | This is the exact cost item 2 and item 3 name — a 14-minute, 165k-token re-review that only checked fix commits |
| Add delta re-review scope (`git diff <last-reviewed-SHA>..HEAD`, `git range-diff` for a base merge) with a fresh marker at each new HEAD (chosen) | Matches the review to what changed. The merge gate's SHA check is unchanged | A re-review that misjudges "what the delta calls for" could miss a regression introduced by an earlier commit's interaction with a later one. Mitigated by keeping the acceptance-criteria and AgDR checks blocking and full-scope on every pass |
| Let reviewers keep re-running the full suite on every pass | No new procedure | CI already runs the full suite and is the merge gate's trusted result. Re-running it three times is the cost item 3 names |
| CI ownership of the full suite: reviewers read CI's check-run result for the head SHA, and run only changed-file tests plus fail-before proofs for new tests (chosen) | Cuts one of the three redundant full-suite runs without weakening the merge gate, which already requires green CI | A reviewer who skips reading CI's result could approve on a red suite. Mitigated by making a red CI check itself a blocking finding |
| No cap on review rounds | Simple | This is cause 4 verbatim — a later round can always surface one more advisory point, with nothing to stop it |
| Cap review rounds at two, and file remaining non-blocking findings as a follow-up ticket after round two (chosen) | Bounds the review-fix loop's cost. A blocking finding in round two still blocks, so safety is unchanged | A genuinely material non-blocking finding could still wait for a follow-up PR instead of landing in the same PR |
| Batch several tickets into one trust-chain PR, as allowed for any PR | Fewer PRs to open | A batched trust-chain PR cannot isolate one blocking finding to one criterion, and a delta re-review cannot cleanly attribute a later commit to one ticket |
| One ticket per trust-chain PR (chosen), with the existing Lean docs/config batching exemption unchanged | Keeps each review round scoped to one change on the highest-blast-radius path class | None material — this narrows batching only on the path class that already gets the full Heavy review chain |

## Decision

Chosen: **all five options marked "(chosen)" above**, because together they remove the
measured causes of slow review-fix loops without touching any Heavy-tier
safeguard. `.claude/rules/right-size-ceremony.md` rail 1 (security and
trust-chain never go Lean) and rail 2 (ambiguity rounds up) stay unchanged,
word for word. `block-unreviewed-merge.sh` still requires a fresh Rex marker
at the PR's real HEAD on every merge, including after a delta re-review.

## Consequences

- A self-bypass edge case, a pre-existing gap, and a writing-profile nit that
  does not change meaning or drop evidence now read as advisory findings.
  `.claude/rules/writing-standard.md`'s "must request changes" line now
  applies only when a profile fault changes meaning or drops evidence.
- A re-review reads `git diff <last-reviewed-SHA>..HEAD` by default, and
  `git range-diff` for a base-branch merge, instead of the whole PR.
- Rex and Hakim read `gh pr checks` for the head SHA and run only changed-file
  tests plus fail-before proofs, instead of the full suite.
- `.claude/rules/pr-workflow.md` caps review rounds at two. The orchestrator
  files a follow-up ticket for any non-blocking finding still open after
  round two.
- The builder pastes shellcheck, test, and fail-before evidence into the PR
  body (`.claude/rules/pr-quality.md` § "Builder Evidence"). The reviewer
  spot-checks it instead of reproducing every command.
- Rex and Hakim state a scope split — Rex owns code quality, tests, and
  writing. Hakim owns security and gate integrity. Neither repeats the
  other's checks, and the orchestrator may skip Hakim on a docs-only delta.
- A PR that changes `.claude/hooks/**`, `.claude/settings.json`,
  `.githooks/**`, or a delegated gate runner carries one ticket
  (`.claude/rules/right-size-ceremony.md` § "One ticket per trust-chain
  PR"). Lean docs/config batching stays acceptable, unchanged.
- Item 6 of me2resh/apexyard#1418 — an advisory sentence-check script wired
  into pre-push — is out of scope for this PR and tracked separately.

## Artifacts

- me2resh/apexyard#1418
- `.claude/agents/code-reviewer.md` §§ "Blocking-Severity Bar", "Delta
  Re-Reviews", "CI Ownership of the Test Suite", "Scope Split with the
  Security Auditor"
- `.claude/agents/security-reviewer.md` (mirrored sections)
- `.claude/rules/right-size-ceremony.md` § "One ticket per trust-chain PR"
- `.claude/rules/pr-workflow.md` § "After Pushing Commits to an Open PR"
- `.claude/rules/pr-quality.md` § "Builder Evidence"
- `.claude/rules/writing-standard.md`
- `docs/quality-regression/fixtures/human-friendly-cases.md` (HF-10)
