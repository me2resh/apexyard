---
name: code-review
description: Review a PR for quality, security, and standards compliance. Invokes the Code Reviewer agent (Rex).
disable-model-invocation: false
argument-hint: "<pr-number> [repo]"
allowed-tools: Bash, Read, Grep, Glob
---

# /code-review — Code Review

Review a pull request for quality, security, and adherence to standards.

## LSP-aware (optional, recommended)

This skill performs semantic code navigation — finding definitions, walking references, tracing handlers across modules. With LSP enabled (`ENABLE_LSP_TOOL=1` + per-language plugin per `docs/getting-started.md`), queries are ~3-15× cheaper in token cost than grep + Read. Without LSP, the skill falls back to grep + Read transparently — no new failure mode, just optional speed.

Per-language LSP plugins live in Claude Code's marketplace. Install once; the skill detects the active language and dispatches automatically.

## Activated agent + role

When `/code-review` runs:

1. **Primary reviewer**: the **Code Reviewer agent (Rex)** at [`.claude/agents/code-reviewer.md`](../../agents/code-reviewer.md) — runs on every commit, owns the automated first-pass review.
2. **Human approval gate**: the **[Tech Lead](../../../roles/engineering/tech-lead.md)** — activates to sign off on architecture, design patterns, and team conventions that Rex can't judge from code alone.
3. **Conditional Security Auditor**: if the diff touches `**/auth/**`, `**/crypto/**`, `**/secrets/**`, `.env*`, or similar, the **[Security Auditor](../../../roles/security/security-auditor.md)** also activates and must sign off before merge. Consider chaining `/security-review` for the deeper pass.
4. **Conditional UI Designer**: if the diff touches visible UI, the **[UI Designer](../../../roles/design/ui-designer.md)** activates for design review.

See [`.claude/rules/role-triggers.md`](../../rules/role-triggers.md) for the full activation protocol.

## Usage

```
/code-review 30
/code-review 30 your-org/your-repo
```

## Running tests in a scratch clone

Rex may need to run tests or attack probes against the PR head, outside this repository's working tree. Use a plain `git clone` into a literal scratch path. Or export the PR head with `git archive | tar -x` into a literal non-git directory. The export step still needs an active session ticket. A later write to a literal path inside that directory can use the me2resh/apexyard#883 exemption. If a hook blocks a command, stop that step. Report the exact command, the hook, and its message to the orchestrator. Never rephrase, split, encode, or disguise a command to get past a hook. Full pattern: `.claude/agents/code-reviewer.md` § "Running tests in a scratch clone".

The reviewer mutation lock blocks `git clone`, `git fetch`, and `git checkout` while the active-reviewer marker exists. Prepare the scratch clone and fetch the PR head before step 0 arms the marker.

## Process

Before you draft or post a review, read .claude/rules/writing-standard.md.
Use the controlled technical writing profile. The review is a durable artifact.
Treat a writing-profile fault in the PR as advisory, per the Code Reviewer
agent's § "Blocking-Severity Bar", unless the fault changes meaning or drops
evidence — request changes only for that kind of fault.
State the verdict and next action first. State the reason and evidence after it.
Use the Code Reviewer agent's required Output Format for first reviews, re-reviews, and reduced-scope reviews.
Retain its required sections and give each checklist result a reason or evidence reference.
Before submission, check the report against that format and repair omissions.
Do not write a process transcript.

### 0. Write the active-reviewer marker (REQUIRED — me2resh/apexyard#843)

Before spawning the Code Reviewer agent (Rex), write the active-reviewer session marker. It records that this review pass is the sanctioned one, and suppresses `warn-review-marker-write.sh`'s advisory warning on Rex's `*-rex.approved` write (that hook warns and never blocks since #1026 — AgDR-0111). The marker is scoped to THIS Claude Code session (me2resh/apexyard#1376) — resolve its path through `active_reviewer_marker_path`, never write the bare `.claude/session/active-reviewer` path directly, or a concurrent session's review would read or clobber it. At skill entry:

```bash
ops_root=$(git rev-parse --show-toplevel)
r="$ops_root"
while [ -n "$r" ] && [ "$r" != "/" ]; do
  [ -f "$r/.apexyard-fork" ] && { ops_root="$r"; break; }
  [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ] && { ops_root="$r"; break; }
  r=$(dirname "$r")
done
. "$ops_root/.claude/hooks/_lib-review-markers.sh"
active_marker=$(active_reviewer_marker_path "$ops_root")
mkdir -p "$(dirname "$active_marker")"
printf '%s\n' "<owner/repo>#<pr>:rex" > "$active_marker"
```

On skill exit (after Rex posts its verdict, whether APPROVED or CHANGES REQUESTED), clear the marker. Shell variables do not persist across separate Bash tool calls, so the exit step re-resolves `ops_root` and `active_marker` from scratch — it does not reuse the step-0 variable, which would silently be empty in a later call and turn the `rm -f` into a no-op:

```bash
ops_root=$(git rev-parse --show-toplevel)
r="$ops_root"
while [ -n "$r" ] && [ "$r" != "/" ]; do
  [ -f "$r/.apexyard-fork" ] && { ops_root="$r"; break; }
  [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ] && { ops_root="$r"; break; }
  r=$(dirname "$r")
done
. "$ops_root/.claude/hooks/_lib-review-markers.sh"
active_marker=$(active_reviewer_marker_path "$ops_root")
rm -f "$active_marker"
```

Nothing mechanically stops a build-class sub-agent writing the same file; what makes Rex's marker legitimate is that a real, independent review happened. See `.claude/hooks/warn-review-marker-write.sh` and `.claude/rules/pr-workflow.md` § "Build agents cannot self-review".

### 0a. Never hand the reviewer a marker path (me2resh/apexyard#1144)

**The spawn prompt for Rex MUST NOT contain a literal marker path.** Say
*"write your approval marker on an APPROVED verdict"*; say nothing about where.

Rex already resolves the correct path through `review_marker_path` — the
repo-qualified `<owner>__<repo>__<pr>-rex.approved` form from AgDR-0060,
which is the exact path the gates read. A path in the prompt overrides that
correct resolution: the agent obeys the instruction it was handed, and the
marker lands at the bare-number `<pr>-rex.approved` instead. **No gate reads
that path** — there is no bare-number fallback on any on-disk marker lookup.

The failure is silent in the dangerous direction. `ls .claude/session/reviews/`
shows a file that reads, to a human, like a valid approval; only the merge
attempt reveals otherwise. And at that moment the obvious repair — moving the
file into place — is marker forging, the behaviour
[`pr-workflow.md`](../../rules/pr-workflow.md) § "Build agents cannot
self-review" exists to prevent. The right recovery is always: delete the
gate-invisible file and re-run a real review.

`warn-unqualified-review-marker.sh` warns (advisory, never blocks) when a
bare-number marker appears, and the merge gates name the near-miss in their
refusal message — but the cheap fix is upstream of both: don't pass a path.

1. Fetch PR details and the latest commit SHA
2. Get the diff
3. Review against the checklist (acceptance criteria, architecture, code quality, testing, security, performance)
4. Check for the required Glossary section
5. Check for AgDR links if technical decisions were made
6. On JS/TS diffs, run the Fallow static-analysis pass (§ 9 of the agent) — changed-scope, fail-soft, advisory; render a `### Fallow Findings` table + dry-run fix preview
7. Submit the review through the tracker-agnostic `tracker_review_submit` (gh PR / glab MR / custom host — #758), not a hardcoded `gh pr review`, then clear the active-reviewer marker from step 0

### 8. Offer pre-merge QA after APPROVED

Run this step only after Rex posts an APPROVED verdict and the active-reviewer marker is clear.
Do not offer QA after CHANGES REQUESTED or COMMENT.

Resolve the ops root again. Shell variables from step 0 do not persist across Bash calls.
Read the setting through the shared config reader:

```bash
ops_root=$(git rev-parse --show-toplevel)
r="$ops_root"
while [ -n "$r" ] && [ "$r" != "/" ]; do
  [ -f "$r/.apexyard-fork" ] && { ops_root="$r"; break; }
  [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ] && { ops_root="$r"; break; }
  r=$(dirname "$r")
done
source "$ops_root/.claude/hooks/_lib-read-config.sh"
qa_offer=$(config_get_or '.qa.pre_merge_offer' 'ask')
case "$qa_offer" in
  ask|always|never) ;;
  *) qa_offer=ask ;;
esac
```

- `ask`: Ask: "Rex approved PR #<pr>. Run QA (Salim) against the acceptance criteria before merge? (yes / no)" Replace `<pr>` with the actual PR number.
  On `yes`, run Salim now. On `no`, leave QA for the existing post-merge `qa` label trigger.
  If there is no answer, finish the review with the offer pending. Do not infer consent from silence.
- `always`: Run Salim now without asking.
- `never`: Skip this offer. Keep the existing post-merge QA flow.

For `yes` or `always`, fetch the PR HEAD SHA from the forge.
Run Salim against the PR branch at the recorded HEAD SHA.
Use a scratch checkout or a test deployment built from that SHA.
Give Salim the linked ticket and comments.
Salim must verify each acceptance criterion and return evidence for every result.
If the ticket has no acceptance criteria, report INCOMPLETE.
If the PR HEAD changes during QA, discard the result and run Rex again before another QA attempt.

Post Salim's result on the PR with `tracker_review_submit <owner/repo> <pr> comment <body_file>`.
Use the `comment` verdict, never `approve`.
Include the full PR HEAD SHA, environment, criterion results, and evidence.
Start the body with `## Pre-merge QA (Salim)` so the post-merge role can identify it.
For a complete PASS, include this line in the posted body. Replace the SHA placeholder with the full SHA:

```text
<!-- apexyard-pre-merge-qa: sha=<full-commit-sha> status=PASS -->
```

Use `status=FAIL` or `status=INCOMPLETE` for failed or unverified criteria.
Never mark such a report PASS.
If posting fails, report the failure and do not claim a reusable QA result.
Stop before requesting human merge approval when any criterion fails or cannot be verified.
Give the author the findings and let them revise the PR.
A new commit needs a new Rex verdict and QA run.

This offer is advisory. Never write or relax a merge marker, and never merge from this step.
Only the human-invoked `/approve-merge` records merge approval and merges.
A QA PASS does not grant approval. A QA failure stops this review flow but creates no mechanical merge gate.

## Review Checklist

### Acceptance Criteria — BLOCKING

- Read every linked issue with its comments: `gh issue view <N> --repo <owner/repo> --comments`
- Report each acceptance criterion as Met, Not met, or Not verifiable, with evidence
- A Not met criterion requires CHANGES REQUESTED and no approval marker
- Write "No linked issue" or "No acceptance criteria in #N" when that applies
- See the agent's § "Acceptance Criteria" for the full procedure

### Architecture

- Domain layer has no external dependencies
- Application layer doesn't import infrastructure
- Proper separation of commands vs queries

### Code Quality

- Type-safety enforced
- No unjustified `any` types
- Proper error handling
- Clear naming conventions

### Testing

- Unit tests for domain logic
- Tests test behavior, not implementation
- Edge cases covered

### Security

- No secrets in code
- Input validation present
- No injection vulnerabilities

### PR Description

- Links to the ticket
- **Has a Glossary section** (REQUIRED — request changes if missing)
- AgDR links if decisions were made

### Technical Decisions (AgDR) — BLOCKING

Scan the diff for unrecorded decisions:

- New dependencies / libraries in build files
- New frameworks (ORM, queue, cache, etc.)
- Architecture patterns implemented
- Design pattern choices

**If a decision is detected but no AgDR is linked**:

1. REQUEST CHANGES (do not approve)
2. List the specific decisions found
3. Instruct the author to run `/decide`
4. The PR cannot merge until the AgDR is linked

## Output

Posts a GitHub review comment with:

- Commit SHA reviewed
- Acceptance criteria: each criterion of each linked issue as Met, Not met, or Not verifiable, with evidence
- Checklist results
- Issues found
- Fallow findings (advisory; JS/TS diffs only, when the `fallow` CLI is available)
- Verdict: APPROVED / CHANGES REQUESTED / COMMENT

Invokes: Code Reviewer Agent (Rex)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
