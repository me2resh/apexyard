# PR Workflow — Hard Stops

## Before `git push` (HARD STOP)

**Never** push without running CI checks locally. This prevents wasted CI minutes and failed checks.

```
[ ] Lint passes?              NO → fix before pushing
[ ] Type check passes?        NO → fix before pushing
[ ] Tests pass?               NO → fix before pushing
[ ] Build succeeds?           NO → fix before pushing
```

The `pre-push-gate.sh` hook reminds you of this on every `git push`.

Per-project commands depend on your stack. Common pattern:

```bash
npm run lint && npm run typecheck && npm run test && npm run build
```

For framework-specific projects, add the framework's own validator:

```bash
sam validate --lint        # AWS SAM
terraform validate         # Terraform
cdk synth                  # AWS CDK
```

Also check before pushing:

```
[ ] Only intended files staged?  NO → use specific `git add <file>` (NEVER `git add -A`)
[ ] PR title matches format?     NO → type(TICKET-ID): description
```

## Before `gh pr create`

```
[ ] Ticket exists?            NO → create the ticket FIRST
[ ] Ticket has AC?            NO → add acceptance criteria
[ ] Branch has ticket ID?     NO → rename branch
[ ] PR title has ticket ID?   NO → fix format (single ticket per title)
```

## After `gh pr create`

```
[ ] Invoke Code Reviewer agent
[ ] Wait for Code Reviewer approval
[ ] Wait for human approver (explicit "approved" or similar)
```

## Before `gh pr merge` (HARD STOP)

```
[ ] Code Reviewer approved for THIS commit SHA?     NO → WAIT
[ ] Human approver approved THIS specific PR?       NO → WAIT, ASK EXPLICITLY
```

NO EXCEPTIONS. Not for "small fixes". Not for "just a typo".

### Plan-level "go" is NOT merge approval

A common failure mode: you present a multi-step plan that includes a merge as one of its steps, the user says "go" or "continue" or "ship it" or "execute the plan", and you execute all the steps *including the merge*. **This is wrong.** Plan-level authorization covers everything in the plan *except* merge steps. Merge steps always require a second, per-PR, per-merge explicit approval that names the PR.

#### Wrong

```
You: "Here's the 6-step plan: 1. merge PR #10, 2. close PR #105, ..."
CEO: "go"
You: *runs gh pr merge 10*   ← FAILURE: "go" was plan-level, not merge-level.
```

#### Right

```
You: "Here's the 6-step plan: 1. merge PR #10, 2. close PR #105, ..."
CEO: "go"
You: *executes steps 2–6, stops before step 1*
You: "Steps 2–6 done. Ready to merge PR #10 — approved?"
CEO: "approved"
You: *runs gh pr merge 10*   ← CORRECT: explicit per-PR approval received.
```

#### Why

CEO approval is meant to be a **discrete moment per PR**. Merges are hard to reverse, externally visible, and can trigger downstream deploys. An umbrella "go" on a plan does not give you enough evidence that the CEO consciously signed off on each merge. When in doubt: stop and ask for the per-PR explicit nod.

This also applies to other destructive / externally-visible / hard-to-reverse actions: force pushes, branch deletes, closing issues with dependents, posting to external channels. Plan-level "go" does not carry through to any of these. List them in the plan if you want — just stop before executing and ask.

### Mechanical enforcement

The `block-unreviewed-merge.sh` hook enforces this rule at the shell level. It requires **two** approval markers in `.claude/session/reviews/` before letting any merge command through:

| Marker | Written by | Semantics |
|--------|------------|-----------|
| `<pr>-rex.approved` | the `code-reviewer` agent after a successful review | Code reviewed, no blocking issues |
| `<pr>-ceo.approved` | the `/approve-merge <pr>` skill, **only** on explicit user invocation | CEO has looked at this specific PR and said ship it |

Both markers must contain the current HEAD SHA, and both SHAs must match the live HEAD. New commits after approval invalidate both — you must re-review and re-approve.

Claude can technically `rm` or `touch` these files by hand. Doing so is a visible, auditable, grep-able rule violation — and the whole point of recording the rule mechanically is so that the failure mode is "Claude ignored a hook" (visible) instead of "Claude inferred approval from something vague" (invisible).

### Both merge shapes are gated (#47)

All three merge-gate hooks (`block-unreviewed-merge.sh`, `block-merge-on-red-ci.sh`, `require-design-review-for-ui.sh`) fire on **both** the `gh` subcommand shape and the raw REST-API shape:

| Shape | Example |
|-------|---------|
| `gh pr merge` | `gh pr merge 123 --squash` |
| `gh api .../pulls/<N>/merge` | `gh api repos/owner/repo/pulls/123/merge -X PUT` |

Historically only the first shape was matched. In April 2026 (incident: `me2resh/curios-dog#190` was merged via `gh api` while CI was still running), the second shape was discovered as a silent bypass and closed in [#47](https://github.com/me2resh/apexstack/issues/47). Both the matcher entries in `.claude/settings.json` and the PR-number extraction in each hook (`.claude/hooks/_lib-extract-pr.sh`) now recognise both shapes. Invoking either triggers the gate — there is no supported merge path that skips the two-reviews rule.

Using `gh api .../merge` as a workaround for other issues (e.g. cross-repo resolution, hook flakiness) is itself a rule violation on par with forging an approval marker. If a gate is mis-firing, fix the gate.

## After Pushing Commits to an Open PR

```
[ ] Re-invoke Code Reviewer for the new changes
```

A review is bound to a specific commit SHA — pushing additional commits invalidates the prior review.

## Resuming PR Sessions

Use the `--from-pr` flag to resume a Claude Code session linked to a specific PR:

```bash
claude --from-pr 123
```

This loads the PR context (diff, comments, review state) so you can continue work without re-explaining.
