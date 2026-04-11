# ApexStack Hooks

Hooks are shell scripts the Claude Code harness runs **before or after tool calls**. They are the only reliable way to make process rules stick — anything written only in `CLAUDE.md`, `.claude/rules/*.md`, or `workflows/*.md` is advice the model may drop under pressure. Anything in this directory is mechanically enforced.

> If a rule is important, put it in a hook. If it's a preference, put it in a rule file. If it's context, put it in `CLAUDE.md`.

## How It Fits Together

The harness fires hooks in this order around every action:

```
SessionStart  ->  PreToolUse  ->  (tool runs)  ->  PostToolUse
```

Hooks read tool-call JSON from stdin, use `jq` to parse, write messages to stderr, and signal intent via exit code:

- `exit 0` — allow, silent
- `exit 0` with stderr — allow, warn
- `exit 2` — block (PreToolUse) / nudge Claude with a follow-up message (PostToolUse)

All hooks are registered in `.claude/settings.json` under `hooks.{event}[].hooks[]`. The `if:` matcher lets a single `Bash` matcher attach multiple hooks that only fire on specific command prefixes.

## The Enforcement Layer

These four hooks make the SDLC mechanical instead of advisory. Each enforces a rule that was previously only prose in `workflows/sdlc.md` or `.claude/rules/*.md`.

### 1. Ticket-first — `require-active-ticket.sh`

**Event:** `PreToolUse` on `Edit | Write | MultiEdit`.

**What it does:** blocks edits to any code path unless `.claude/session/current-ticket` exists. Exempts `.claude/`, `docs/`, `projects/*/docs/`, and any `*.md` file so framework / doc / meta work is still fluid.

**Enforces:** the Pre-Build Gate in `.claude/rules/workflow-gates.md` — "do not start coding until the ticket exists, has acceptance criteria, and is broken into tasks."

**Unblock:** run `/start-ticket <issue>`. The skill verifies the issue via `gh issue view` and writes the marker.

### 2. Auto code review — `auto-code-review.sh`

**Event:** `PostToolUse` on `Bash(gh pr create *)`.

**What it does:** parses the PR URL from the `gh` output, writes a pending-review marker at `.claude/session/pending-reviews/<pr>`, and emits a loud reminder telling Claude to invoke the `code-reviewer` agent (Rex) immediately. Not a tool error — the PR is created fine. The hook just pushes the next step into the conversation so it can't be forgotten.

**Enforces:** the "After `gh pr create` → Invoke Code Reviewer agent" section of `.claude/rules/pr-workflow.md` and the Code Review phase of `workflows/sdlc.md`.

### 3. Merge gate — `block-unreviewed-merge.sh`

**Event:** `PreToolUse` on `Bash(gh pr merge *)`.

**What it does:** blocks the merge unless **both** approval markers exist for the PR number being merged, and both contain a SHA that matches the current HEAD. New commits after either approval invalidate it.

| Marker | Path | Written by | Semantics |
|--------|------|------------|-----------|
| Rex | `.claude/session/reviews/<pr>-rex.approved` | `code-reviewer` agent after a successful review | "Code reviewed, no blocking issues" |
| CEO | `.claude/session/reviews/<pr>-ceo.approved` | `/approve-merge <pr>` skill, **only** on explicit user invocation | "The human approver has looked at this specific PR and said ship it" |

Both files contain exactly one line: the 40-character HEAD SHA at the time of approval. The hook reads each, compares with `git rev-parse HEAD`, and blocks on any mismatch.

**Why two markers:** The Rex marker alone isn't enough because it would only enforce the "code review happened" half of the 2-reviews rule. The CEO marker is the mechanical enforcement of **"plan-level 'go' is NOT merge approval"** from `.claude/rules/pr-workflow.md`. A plan-level authorization does not produce the CEO marker — only the `/approve-merge` skill does, and the skill is defined to run only on explicit per-PR user invocation. This closes the failure mode where Claude infers merge approval from an umbrella "go" on a broader plan.

**Trust model:** the approval files are **local session state**, not a remote trust boundary. They're gitignored and live on the user's machine. Claude can technically `rm` or `touch` them directly, and a malicious local user could forge them too. That's fine — the goal is to prevent Claude (an automated agent in the same session) from merging without the discrete review-and-approve moments, not to protect against an adversary who owns the machine. The failure mode the hook closes is **invisible inference** ("Claude decided 'go' meant 'merge'"); it converts that into **visible rule violation** ("Claude `touch`ed the marker without being asked"). The latter is grep-able and auditable; the former is not.

For adversarial trust, rely on remote branch-protection rules (GitHub required reviews, CODEOWNERS, required status checks). This hook complements those, it does not replace them.

**Enforces:** `workflow-gates.md` rule #5 ("2 reviews, CI green, commit SHA matches review") AND `pr-workflow.md` § "Plan-level 'go' is NOT merge approval".

**Companion skill:** `/approve-merge <pr>` (in `.claude/skills/approve-merge/`) is the only supported way to write the CEO marker. The skill definition includes explicit anti-patterns describing the wrong invocation triggers; read it before using.

### 4. Onboarding — `onboarding-check.sh`

**Event:** `SessionStart`.

**What it does:** on every new session, if `.claude/session/onboarded` is missing, injects a reminder telling Claude to run `/onboard` with the user before doing work. The `/onboard` skill asks the day-one discovery questions (project identity, tracker, required checks, reviewers, UI, deploy targets, sensitive topics) and writes the marker plus `.claude/project-config.json`.

## Pre-existing Hooks

These were already in place before the enforcement layer and remain unchanged. The ticket-first + merge-gate + auto-review hooks layer on top; nothing below is regressed.

| Hook | Event | Purpose |
|------|-------|---------|
| `block-git-add-all.sh` | PreToolUse / Bash | Blocks `git add -A / . / --all` |
| `block-main-push.sh` | PreToolUse / Bash | Blocks pushing to `main` / `master` |
| `validate-branch-name.sh` | PreToolUse / Bash | Warns on non-conforming branch names before push |
| `check-secrets.sh` | PreToolUse / Bash | Scans commits for hardcoded secrets |
| `pre-push-gate.sh` | PreToolUse / Bash | Reminds to run lint / typecheck / test / build |
| `validate-pr-create.sh` | PreToolUse / Bash | Checks PR title format, glossary, branch ID |

## Session State Directory

`.claude/session/` is gitignored. It holds per-machine, per-clone state:

```
.claude/session/
├── onboarded                     # created by /onboard, read by onboarding-check
├── current-ticket                # created by /start-ticket, read by require-active-ticket
├── pending-reviews/<pr>          # created by auto-code-review, tracks PRs awaiting Rex
├── reviews/<pr>-rex.approved     # created by code-reviewer agent, read by merge-gate
└── reviews/<pr>-ceo.approved     # created by /approve-merge, read by merge-gate
```

If a marker gets stale, delete the file and re-run the corresponding skill.

## Testing a Hook

Each hook reads a tool-call JSON blob from stdin. Simulate the harness with `printf` (avoid `echo -e` to keep escape handling portable):

```bash
# require-active-ticket — should block
printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/foo.ts"}}' \
  | .claude/hooks/require-active-ticket.sh
echo "exit=$?"

# auto-code-review — should emit reminder + exit 2
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title foo"},"tool_response":{"stdout":"https://github.com/acme/repo/pull/42"}}' \
  | .claude/hooks/auto-code-review.sh
echo "exit=$?"
```

Exit code 2 with a block message means the hook is working.

## Adding a New Hook

1. Write the shell script in this directory, `chmod +x`.
2. Register it in `.claude/settings.json` under the right event + matcher.
3. Smoke-test it with a realistic stdin payload (see above).
4. Document it in this README under the right section.
5. If it enforces a rule that was previously only in a rule file, update that rule file with a trailing "enforced by `.claude/hooks/<name>.sh`" note so readers can trace the prose back to the enforcement.

## Dependencies

All hooks rely on:

- `bash` (invoked via shebang `#!/bin/bash`)
- `jq` for parsing tool-call JSON
- `git` for repo-relative path resolution and HEAD lookup
- `gh` for the merge-gate hook's PR-number fallback

On macOS these come from Homebrew (`brew install jq gh`). On Debian-based Linux, `apt install jq gh`. CI runners typically have them pre-installed. If `jq` is missing, the hooks short-circuit cleanly (they can't parse the input, so they exit 0 without blocking) — worth adding a `command -v jq` guard if you want loud failure instead.
