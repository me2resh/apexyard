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

This rule (and the rest of this file) uses "CEO" as the default human-approver display title — override the printed word via `.claude/project-config.json` → `review_markers.human_approver_title` (default unchanged); the marker filename, structured fields, and gate logic are the same regardless (me2resh/apexyard#957).

### Plan-level "go" is NOT merge approval

A common failure mode: you present a multi-step plan that includes a merge as one of its steps, the user says "go" or "continue" or "ship it" or "execute the plan", and you execute all the steps *including the merge*. **This is wrong.** Plan-level authorization covers everything in the plan *except* merge steps. Merge steps always require an **explicit per-PR approval that names the PR**.

The load-bearing rule is "explicit per-PR approval", not "two user messages." After the per-PR-naming approval is given, `/approve-merge <pr>` writes the structured CEO marker AND runs `gh pr merge` in the same turn — they're a single deterministic consequence of one authorization moment, not two separate moments. Earlier versions of this rule split the consequence across two messages (write marker → wait → merge); that ceremony added latency without safety. The mechanical safety net is the structured marker (#48) + per-PR-naming gate, not the two-message split.

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
You: "Steps 2–6 done. PR #10 is ready to merge — run /approve-merge 10 when you're happy."
CEO: /approve-merge 10          ← CORRECT: the CEO invokes it. The skill is
                                   human-only (#1042), so the model cannot.
```

#### Why

CEO approval is meant to be a **discrete moment per PR**. Merges are hard to reverse, externally visible, and can trigger downstream deploys. An umbrella "go" on a plan does not give you enough evidence that the CEO consciously signed off on each merge. When in doubt: stop and ask for the per-PR explicit nod.

The discrete moment is the **invocation of `/approve-merge`**, and since #1042 that invocation can only come from a human — `disable-model-invocation: true`. Saying "approved" in prose is no longer sufficient on its own; the model's job is to get the PR ready and say so. Treat the invocation with the seriousness the merge warrants: once it runs, the merge runs.

This rule also applies to other destructive / externally-visible / hard-to-reverse actions: force pushes, branch deletes, closing issues with dependents, posting to external channels. Plan-level "go" does not carry through to any of these. List them in the plan if you want — just stop before executing and ask.

## Build agents cannot self-review

A build-class sub-agent (backend-engineer, frontend-engineer, platform-engineer, product-manager, data-engineer, ui-designer, ux-designer) is spawned to implement a ticket. It cannot nest the Agent tool, which means it cannot spawn the real `code-reviewer` (Rex). Any "review" a build agent produces is the author reviewing their own work — not an independent pass.

**This matters for the merge gate.** The two-reviews requirement (workflow-gates rule #5) depends on Rex being a separate agent with a separate context. A build agent impersonating Rex — framing its final report as "Rex Code Review — Verdict: APPROVED" and fabricating a `*-rex.approved` marker — satisfies the *filename* of the gate requirement without satisfying its *intent*. It is a visible rule violation, not an edge case.

### Rule

Build agents MUST NOT:

- Write any file under `.claude/session/reviews/`, including `*-rex.approved`, `*-ceo.approved`, `*-security.approved`, or `*-architecture.approved`. **Nothing mechanically stops you** — `warn-review-marker-write.sh` warns and exits 0 (see "Mechanical backstop" below). That is why this is a MUST NOT rather than a can't: writing one records a review that never happened, and the human approving the merge relies on it
- Frame their final report as a code review, Rex review, or include a "Verdict: APPROVED / CHANGES REQUESTED" section
- Claim to be performing an independent review

Build agents MUST:

- Report build results plainly: what was built, what tests ran, what passed or failed
- Hand off to the orchestrator, which runs the real Rex review as a separate sub-agent call

### Mechanical backstop

**`warn-review-marker-write.sh` is ADVISORY — it warns, it does not block.** It was a blocking gate from #843 until #1026 returned it to advisory per [AgDR-0111](../../docs/agdr/AgDR-0111-marker-gate-plain-advisory.md). Do not read it as enforcement:

1. `warn-review-marker-write.sh` — PreToolUse hook that fires when a Write or Bash call looks like it targets `*-rex.approved`, `*-security.approved`, or `*-architecture.approved` under `.claude/session/reviews/`. It prints a warning and **exits 0** when no matching **active-reviewer session marker** exists at `.claude/session/active-reviewer` (one line: `<owner>/<repo>#<pr>:<kind>`), written by the orchestrator (or one of `/code-review`, `/security-review`, `/design-review`) immediately before spawning the sanctioned reviewer. Setting that marker suppresses the warning for the sanctioned write; it does not "unblock" anything, because nothing is blocked. `*-ceo.approved` has always been advisory-only and has its own structured-field defence in `block-unreviewed-merge.sh` (`sha=` / `approved_by=user` / `skill_version=`). A `clear-active-reviewer-marker.sh` SessionStart hook sweeps stale markers, mirroring `clear-bootstrap-marker.sh`.
2. The prompt-convention guardrail in each build-agent file — a build agent is told plainly not to write these files, and that nothing will stop it, which is exactly why the instruction matters.

**Why it stopped blocking.** It decided by pattern-matching the *text* of a shell command, which AgDR-0104 established cannot be made sound. It failed in both directions at once: 13 false positives in a single session (a read-only `grep`, a commit message, a reviewer's own prose, `/approve-merge`'s documented merge step) while the split-path spelling walked straight through. #843's actual root cause was separately repaired — `auto-code-review.sh`'s banner used to tell whoever ran `gh pr create` to "Invoke Rex NOW", which a build-class sub-agent cannot do, so twice (PRs #835, #842) it resolved the contradiction by writing the marker itself. That banner now addresses both readers explicitly (AgDR-0056), so the inducement is gone and the block was belt-and-braces on a fixed cause.

**What actually enforces this**, and where to look if you want it stronger:

| Layer | Strength |
|---|---|
| The per-PR human merge approval (`/approve-merge`) | The control. A human decides. |
| `block-unreviewed-merge.sh` — marker SHA vs **forge-reported** HEAD | Structured state; a local file write cannot fake the forge's HEAD |

A stronger control — asking the forge whether a review was actually *posted* at the merge commit — ships behind `review_markers.require_posted_review` (**default off**, GitHub-only). Enabling it makes "Rex reviewed this" a server-side fact rather than a local file an agent can write. It is deliberately weaker than the author-independence gate AgDR-0062 deferred: it accepts a review from the PR's own author, so it is **not** separation of duties. See [AgDR-0112](../../docs/agdr/AgDR-0112-verify-posted-review-at-head.md) and me2resh/apexyard#1051.

### Mechanical enforcement

The `block-unreviewed-merge.sh` hook enforces this rule at the shell level. It requires **two** approval markers in `.claude/session/reviews/` before letting any merge command through:

| Marker | Written by | Format | Semantics |
|--------|------------|--------|-----------|
| `<pr>-rex.approved` | the `code-reviewer` agent after a successful review | Bare 40-char SHA | Code reviewed, no blocking issues |
| `<pr>-ceo.approved` | the `/approve-merge <pr>` skill, **only** on explicit user invocation | Structured key/value (see below) | CEO has looked at this specific PR and said ship it |

The CEO marker is **structured** (key/value format) so the model cannot pass the gate by writing a bare SHA via `echo SHA > file`. Required fields:

```
sha=<40-char hex>
approved_by=user
skill_version=2
```

Optional audit fields the skill writes but the gate doesn't validate: `approved_at=<ISO>`, `approval_summary="..."`. See me2resh/apexyard#48 for the design rationale — the structured format makes a forged marker a deliberate, visible rule violation rather than a one-line accident.

Both markers' SHAs must match the PR's HEAD as reported by GitHub (`gh pr view <N> --json headRefOid`). New commits after approval invalidate both — you must re-review and re-approve.

**Note on "HEAD":** the merge gates compare marker SHAs against the PR's real HEAD on GitHub, not the local working tree's HEAD. Earlier versions of the hooks used `git rev-parse HEAD`, which forced a `gh pr checkout <N>` dance before every `gh pr merge <N>` (local was rarely the PR branch, and any mismatch blocked the merge). After #55, the hooks resolve the PR HEAD via `gh pr view` and fall back to local HEAD with a visible warning only when the gh call fails (network / auth).

**Note on the load-bearing signal — local marker, not a GitHub "Approved" state (#587):** the merge gate reads the **local `*-rex.approved` marker file**, never GitHub's review-state UI. So the canonical code-reviewer flow is: post the human-readable review with `gh pr review <N> --comment` (verdict stated in the body) AND write the local marker on an APPROVED verdict. The local marker is the required gate output; the GitHub comment is for human visibility. A GitHub "Approved" review state is **optional** and, in the default single-maintainer / single-GitHub-account or auto-mode setup, **unavailable** — GitHub refuses to let an account approve its own PR, and an auto-mode write-classifier may additionally flag a `gh pr review --approve` attempt. That refusal is **expected, not a gate failure**: the sanctioned `code-reviewer` (Rex) sub-agent is a distinct review pass from the author, so writing its own marker satisfies the author-vs-reviewer separation the gate depends on regardless of the GitHub UI. Do not attempt `--approve` by default, and do not treat its block as a failure to review. (This applies ONLY to the sanctioned `code-reviewer` agent — a *build* agent writing a `*-rex.approved` marker is still the author-impersonating-reviewer violation described above.)

Claude can technically `rm` or `touch` these files by hand, or fabricate the structured fields. Doing so is a visible, auditable, grep-able rule violation — and the whole point of recording the rule mechanically is so that the failure mode is "Claude ignored a hook" (visible) instead of "Claude inferred approval from something vague" (invisible). The structured-marker format raises the visibility bar one more notch by requiring the model to type `approved_by=user` etc. on purpose.

### The approval skills are human-only (#1042, AgDR-0110)

"Explicit per-PR approval" is now enforced **mechanically**, not only in prose. `/approve-merge`, `/approve-design`, and `/approve-architecture` carry `disable-model-invocation: true`, so **only a human can invoke them**. Saying "approved" in conversation is no longer sufficient on its own — the operator types the command, and that invocation *is* the approval moment this rule has always described.

The mirror half matters just as much: the **review** skills (`/code-review`, `/security-review`, `/design-review`) are model-invocable, so the orchestrator triggers them itself — as `auto-code-review.sh` has always instructed. Independence comes from the reviewer being a **separate sub-agent with its own context**, not from who typed the command, so nothing is lost by letting the model start a review.

Before #1042 these were exactly inverted, and the safety was accidental: a model couldn't invoke `/code-review`, so it couldn't obtain a Rex marker, so it couldn't merge. Unlocking the review skills **alone** would therefore have opened a fully autonomous `open → review → approve → merge` path. The two sides are coupled — `test_skill_invocability_gates.sh` pins both, and fails loudly if review skills are ever unlocked while approval skills are not locked.

### Both merge shapes are gated (#47)

All three merge-gate hooks (`block-unreviewed-merge.sh`, `block-merge-on-red-ci.sh`, `require-design-review-for-ui.sh`) fire on **both** the `gh` subcommand shape and the raw REST-API shape:

| Shape | Example |
|-------|---------|
| `gh pr merge` | `gh pr merge 123 --squash` |
| `gh api .../pulls/<N>/merge` | `gh api repos/owner/repo/pulls/123/merge -X PUT` |

Historically only the first shape was matched. In April 2026 (incident: `me2resh/curios-dog#190` was merged via `gh api` while CI was still running), the second shape was discovered as a silent bypass and closed in [#47](https://github.com/me2resh/apexyard/issues/47). Both the matcher entries in `.claude/settings.json` and the PR-number extraction in each hook (`.claude/hooks/_lib-extract-pr.sh`) now recognise both shapes. Invoking either triggers the gate — there is no supported merge path that skips the two-reviews rule.

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

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
