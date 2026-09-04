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

## Process

Before drafting or posting the review, read `.claude/rules/writing-standard.md`.
Apply **Flavored mode**. The review is a durable, human-facing artefact:
open with the verdict and next action, then give the reason and supporting
evidence. Do not turn the review into a process transcript.

### 0. Write the active-reviewer marker (REQUIRED — me2resh/apexyard#843)

Before spawning the Code Reviewer agent (Rex), write the active-reviewer session marker. It records that this review pass is the sanctioned one, and suppresses `warn-review-marker-write.sh`'s advisory warning on Rex's `*-rex.approved` write (that hook warns and never blocks since #1026 — AgDR-0111). At skill entry:

```bash
ops_root=$(git rev-parse --show-toplevel)
r="$ops_root"
while [ -n "$r" ] && [ "$r" != "/" ]; do
  [ -f "$r/.apexyard-fork" ] && { ops_root="$r"; break; }
  [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ] && { ops_root="$r"; break; }
  r=$(dirname "$r")
done
mkdir -p "$ops_root/.claude/session"
printf '%s\n' "<owner/repo>#<pr>:rex" > "$ops_root/.claude/session/active-reviewer"
```

On skill exit (after Rex posts its verdict, whether APPROVED or CHANGES REQUESTED), clear the marker:

```bash
rm -f "$ops_root/.claude/session/active-reviewer"
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
3. Review against the checklist (architecture, code quality, testing, security, performance)
4. Check for the required Glossary section
5. Check for AgDR links if technical decisions were made
6. On JS/TS diffs, run the Fallow static-analysis pass (§ 9 of the agent) — changed-scope, fail-soft, advisory; render a `### Fallow Findings` table + dry-run fix preview
7. Submit the review through the tracker-agnostic `tracker_review_submit` (gh PR / glab MR / custom host — #758), not a hardcoded `gh pr review`, then clear the active-reviewer marker from step 0

## Review Checklist

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
- Checklist results
- Issues found
- Fallow findings (advisory; JS/TS diffs only, when the `fallow` CLI is available)
- Verdict: APPROVED / CHANGES REQUESTED / COMMENT

Invokes: Code Reviewer Agent (Rex)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
