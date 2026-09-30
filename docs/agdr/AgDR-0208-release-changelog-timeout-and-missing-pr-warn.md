# Bound each release gh call and warn on a scoped commit with no trailing PR

> For issue #1506, facing advisory review points on the #1495 release close check, I decided to bound each `gh pr view` call with a 10-second timeout and to warn when a scoped commit has no trailing `(#PR)`. This keeps hung forge calls from stalling a release and surfaces a direct-push missing close to the author.

## Context

PR #1495 shipped the gh-backed close check (AgDR-0197). Reviews left three polish points. An empty PR body already returned success, but the comment said failure. A scoped commit with no trailing `(#PR)` stayed silent, so a direct push hid the missing close. A hung `gh` call had no bound after #1076 removed the older lookup timeout.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Docs-only note in AgDR-0197. No script change. | Smallest diff. | Hung gh still stalls. Direct push still silent. |
| B. Bound each call at 10s (restore #1078 default). Warn on missing trailing `(#PR)`. Treat timeout like any failed read. | Matches prior #1078 shape. Operator sees both failure modes. | Needs `timeout` or `gtimeout` for the bound. |
| C. Cache PR bodies and hard-fail the release on timeout. | Fewer API calls. Forces a clean forge. | Cache adds state. Hard-fail blocks a cut that could finish with a warned fallback. |

## Decision

Chosen: **B**.

1. Correct the `fetch_pr_body` comment. An empty body returns success.
2. Print a warning that names the short SHA when a scoped commit has no trailing `(#PR)`. Emit no close line for that commit.
3. Bound each `gh pr view` with `PR_LOOKUP_TIMEOUT` (default 10). Prefer GNU `timeout`, then macOS `gtimeout`. A timeout counts as a failed read with the existing scoped-title fallback warning.
4. Record the one-call-per-scoped-PR cost, rate-limit behaviour, and timeout in AgDR-0197. Cite #1393 and the v5.7.0 near-misses #1418, #1382, and #1403. State how this extends #1076.

## Consequences

- A hung forge stops after the timeout and may over-close from the scoped title.
- A direct-push scoped commit prints a warning and leaves the issue open.
- Stock macOS without coreutils still runs unbounded and prints a one-time warning.
- AgDR-0197 is the durable record of cost and related issues.

## Artifacts

- `bin/release-changelog.sh`
- `docs/agdr/AgDR-0197-release-closes-from-body-and-list-removed-lines.md`
- `.claude/hooks/tests/test_release_changelog.sh`
- Issue #1506
