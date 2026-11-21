# Severity reviews and drive-to-green

Rex reports severity before detail. The first line stays `Not covered by the checks: <limits or None>`.
The next line uses this exact form: `Blocking 0 | Important 2 | Nits 7`.
Rex lists at most five nits. For seven nits, Rex adds `Additional nits: 2`.
Each listed nit starts with `- Nit:`. Other required sections remain unchanged.
Severity changes presentation only. Existing gates retain their decisions.

## Override the review policy

The default policy is [REVIEW.md](../../templates/REVIEW.md).
The code-review skill uses `portfolio_resolve_template` from `_lib-portfolio-paths.sh`.
Before review, source `<ops-root>/.claude/hooks/_lib-portfolio-paths.sh`.
Resolve `portfolio_resolve_template "projects/<project>/REVIEW.md"` for a registered project.
If absent, resolve `portfolio_resolve_template "REVIEW.md"`.
Read the resolved file and give its path to Rex.
For one project, create `custom-templates/projects/<project>/REVIEW.md` beside the portfolio registry.
Use the registry project name. The skill resolves `projects/<project>/REVIEW.md` first.
Without that file, it resolves `REVIEW.md`.
A shared `custom-templates/REVIEW.md` overrides the framework default.
The helper preserves its existing override order.
An override cannot weaken the blocking bar or any approval gate.

## Run one PR

Use `/drive-to-green <pr-number> [repo]`.
The loop uses the CI Monitor and reviewer spawn from `/code-review`.
The orchestrator waits for CI. Rex checks CI once.
Stop on failed CI and report the failed checks when no authorised fix can resolve them.
Give actionable CI failures to a build agent within the same round budget.
Require green CI before each review.

Read `.review.drive_to_green.max_rounds` with `config_get_or` from `_lib-read-config.sh`.
Set this positive integer in the existing project configuration. The default is `2`.
Reject invalid values. Do not start an unbounded loop.
One round includes a CI wait and one independent review.
The first review counts as round one. Each delta review consumes another round.
Do not start fixes after the final review round.
Report open findings, failed checks, or missing evidence when the cap prevents progress.

Give fixes to a role-appropriate build agent under the existing ticket and isolation rules.
Give the agent finding IDs, evidence, scope, and required checks.
Require test results and the new head SHA before the next CI wait.
Request a delta review with the prior posted review ID and commit range.
Use the existing review-depth rules. Do not substitute an orchestrator summary for evidence.

After a base refresh, call `rex_approval_carries_over` from `_lib-merge-behind.sh`.
Use the command in [PR workflow](../../.claude/rules/pr-workflow.md#carry-over-check-after-a-refresh-me2reshapexyard1638).
For `true`, retain the existing evidence without another reviewer spawn.
For `false` or `unknown`, request a delta review within the cap.
Recheck the head and all applicable gates before reporting readiness.
Report other pending gates as blockers. Report human approval only when it alone remains.

The loop never writes approval markers. The independent reviewer retains its existing authority.
The loop never merges and never invokes `/approve-merge`.
Stop on any hook, sandbox, or permission block. Report the exact message.

## Preview without side effects

Use `/drive-to-green <pr-number> --dry-run <state-file>`.
The skill calls its local `dry-run.sh` helper. The helper reads fake state only.
State contains one value per line: `pending`, `failed`, `changes`, `approved`, `carry`, or `unknown`.
Each line represents a round. `carry` represents verified carry-over with all other automated gates satisfied.
`approved` represents a current review with all other automated gates satisfied.
The helper prints planned actions. It performs no network calls or mutations.
