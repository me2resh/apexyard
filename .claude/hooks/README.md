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

## The Ticket-Vocabulary Backstops

These two hooks are the mechanical backstop for the rule in `.claude/rules/ticket-vocabulary.md` — "`Ticket`, `#N`, and dependency notation refer ONLY to real GitHub issues". The rule itself is self-discipline; these hooks catch the downstream symptom (a fabricated `#N` that slipped into a durable artifact).

### 5. PR-title issue verification — `validate-pr-create.sh` (extended)

**Event:** `PreToolUse` on `Bash(gh pr create *)`.

**What it does:** after the existing title-format / glossary / branch-ID checks, extracts the issue number from the PR title (e.g. `14` from `feat(#14): …`) and runs `gh issue view <N> --repo <tracker>` to verify it exists. Blocks PR creation with a clear message if the issue is missing.

**Tracker repo resolution:**

1. First tries `.tracker_repo` in `.claude/project-config.json` if present
2. Falls back to parsing the `origin` remote (`owner/repo` from SSH or HTTPS URL)

**Why:** catches the case where Claude built a plan using `Ticket N` vocabulary, forgot to create the real issue, and then went straight to `gh pr create --title "feat(#N): …"`. The title is the moment the fabrication becomes durable. This hook refuses to let that happen.

### 6. Commit-message ref verification — `verify-commit-refs.sh` (new)

**Event:** `PreToolUse` on `Bash(git commit *)`.

**What it does:** parses the commit message from `-m "..."`, `-m '...'`, or `-F <file>` args and scans for issue references matching any of:

- `Closes #N` / `Close #N` / `Closed #N`
- `Fixes #N` / `Fix #N` / `Fixed #N`
- `Resolves #N` / `Resolve #N` / `Resolved #N`
- `Refs #N` / `Ref #N` / `References #N`
- `Related to #N`

Each referenced number is verified against the tracker repo via `gh issue view`. Blocks the commit if any reference doesn't resolve.

**Limitation:** interactive commits (no `-m` / `-F`) are skipped. Parsing `.git/COMMIT_EDITMSG` before git's own validation would race, and Claude rarely uses the interactive path anyway. Accepted gap — in practice Claude almost always uses `-m` with a HEREDOC.

**Why:** same root as validate-pr-create.sh — commit messages are the other main path where a fabricated `#N` becomes durable. `git log` + `git blame` + GitHub's auto-linking all lean on these references, so wrong ones pollute the permanent record.

### Both hooks are backstops, not primary fixes

The primary fix for the vocabulary-collision failure mode is the **rule** in `.claude/rules/ticket-vocabulary.md`. Read it. The hooks catch downstream symptoms at the moment of durable commitment (PR title, commit message). They cannot see prose output — so the vocabulary rule has to come first, and these hooks are the grep-able artifact trail when the rule fails.

## The Rule-Mechanization Hooks (GH-13)

Four more hooks added by the rule-audit ticket ([#13](https://github.com/me2resh/apexstack/issues/13)) and recorded in [`docs/agdr/AgDR-0001-rule-mechanization-hooks.md`](../../docs/agdr/AgDR-0001-rule-mechanization-hooks.md). Each closes a specific "prose rule the model drops under pressure" gap that the audit surfaced.

### 7. AgDR-for-arch-changes — `require-agdr-for-arch-changes.sh`

**Event:** `PreToolUse` on `Bash(git commit *)`.

**What it does:** parses the commit message and the staged diff. If any staged file matches the architecture path list, requires **either** (a) a new AgDR file staged alongside (`docs/agdr/AgDR-NNNN-*.md`), **or** (b) an AgDR reference in the commit message (`AgDR-NNNN` or `docs/agdr/AgDR-`). Blocks the commit otherwise.

**Default architecture paths** (regex):

```
\.tf$                         # any terraform file at any depth
\.tfvars$                     # any terraform vars at any depth
(^|/)docker-compose.*\.ya?ml$ # compose files at root or in monorepo subdirs
(^|/)Dockerfile               # Dockerfiles at root or in monorepo subdirs
^\.github/workflows/          # GitHub Actions workflow files
```

All path patterns use the `(^|/)` anchor so they catch **monorepo layouts** (`backend/Dockerfile`, `web/docker-compose.yml`, `services/api/Dockerfile.prod`) as well as root-level files. This was refined post-#13 in #18 — the original `^Dockerfile` only caught root-level files and silently skipped monorepo Dockerfiles.

**Customize:** set `.architecture_paths` in `.claude/project-config.json` to a JSON array of regex patterns. The default list is deliberately narrow — see AgDR-0001 for why dependency manifests (`package.json`, `go.mod`) and API schemas are explicitly excluded.

**Not in the default list (known gap):** CDK / Pulumi / generic-IaC projects that use plain `.ts` / `.py` / `.go` files inside an `infrastructure/` directory. The original draft had a generic `(^|/)infrastructure/` pattern for this, but testing showed it false-positives on `docs/infrastructure/notes.md` and `src/types/infrastructure/foo.ts` — the word "infrastructure" is ambiguous as a directory name. Projects that want CDK-style coverage should add an explicit override like `(^|/)infrastructure/.*\.(ts|py|go)$` via `.architecture_paths`.

**Enforces:** `.claude/rules/agdr-decisions.md § Enforcement` — specifically the line "Pre-commit hook warns if architecture files changed without an AgDR reference", which was prose-only until this hook shipped.

### 8. Design-review-for-UI merge gate — `require-design-review-for-ui.sh`

**Event:** `PreToolUse` on `Bash(gh pr merge *)`.

**What it does:** if the PR's diff touches any UI file, requires a design-approval marker at `.claude/session/reviews/<pr>-design.approved` with a SHA matching HEAD. Non-UI PRs bypass silently.

**Default UI paths** (regex):

```
\.tsx$                    # React (TSX only, NOT plain .ts)
\.jsx$                    # React (JSX only, NOT plain .js)
\.vue$
\.svelte$
\.css$ / \.scss$ / \.sass$ / \.less$
design-tokens
```

**Critical note:** `.tsx`/`.jsx` are matched **exactly**, not as `.tsx?` / `.jsx?`. The original draft had the regex-optional form, which also matched plain `.ts` and `.js` files — caught in smoke testing and fixed before merge. Server-side TypeScript/JavaScript should never trigger a design gate.

**Customize:** `.ui_paths` in `.claude/project-config.json`.

**Companion skill:** `/approve-design <pr>` (in `.claude/skills/approve-design/`) writes the marker. It follows the same pattern as `/approve-merge`: verify PR state → verify Rex marker at HEAD → write the design marker at the repo root → confirm → stop. The skill definition includes explicit valid/invalid triggers and an anti-pattern section distinguishing mockup approval (design phase) from implementation-review approval (PR phase).

**Manual fallback:** for projects that deliberately skip design review (admin tools, internal dashboards), `touch .claude/session/reviews/<pr>-design.approved` is a visible, auditable "we decided to skip" artifact rather than an invisible omission.

**Enforces:** `.claude/rules/pr-quality.md § "Design Review (UI Changes)"` and `workflows/code-review.md § "UI Designer (conditional)"` — both prose-only until this hook shipped.

### 9. No-red-CI merge gate — `block-merge-on-red-ci.sh`

**Event:** `PreToolUse` on `Bash(gh pr merge *)`.

**What it does:** runs `gh pr checks <pr>` on the target PR and blocks if any check is failing, cancelled, timed out, pending, or in-progress.

**State handling:**

| State | Behavior |
|-------|----------|
| All green | Allow |
| Any failing / cancelled / timed out | **Block** with the check output in the error message |
| Any pending / in-progress / queued | **Block** (pending is not green; wait for CI to finish, then retry) |
| "No checks reported" (no CI configured) | Allow with a NOTE to stderr — legitimate state for early apexstack forks |

**Enforces:** `.claude/rules/pr-quality.md § "No Red CI Before Merge"` — "Never merge with red CI, even if the failure is pre-existing or unrelated." Was prose-only.

### 10. Commit-format validator — `validate-commit-format.sh`

**Event:** `PreToolUse` on `Bash(git commit *)`.

**What it does:** parses the commit message from `-m` or `-F` args (multi-line safe, same pattern as `verify-commit-refs.sh`) and validates the subject line against:

```
^(feat|fix|refactor|test|docs|chore|style|perf|build|ci|revert)(\([^)]+\))?:[[:space:]]+.+
```

Accepts `type: subject` and `type(scope): subject`. Rejects subjects without a valid type prefix.

**Why this list of types:** identical to the PR-title type list in `git-conventions.md`, plus `revert` which PR titles allow. Keeping the commit-type list aligned with the PR-title list prevents "commit passes but PR title using the same type fails" asymmetry.

**Customize:** set `.commit_types` in `.claude/project-config.json` to a JSON array of strings. When set, ONLY those types are accepted — the default list is **not** merged; the override replaces it entirely. This lets teams with strict conventions whitelist exactly the types they use:

```json
{ "commit_types": ["wip", "feat", "fix"] }
```

With that config, `wip: scratch work` is accepted and `refactor: cleanup` is rejected. Remove the field or the file to restore the default 11-type list.

**Interactive commits (no `-m` / `-F`)** are skipped — accepted gap, matches sibling hooks' policy.

**Enforces:** `.claude/rules/git-conventions.md § "Commit Message Format"` — was prose-only.

## Settings Ordering Note

The new hooks are registered in `.claude/settings.json` alongside the existing ones on the same `Bash(git commit *)` / `Bash(gh pr merge *)` matchers. The Claude Code harness runs all matching hooks sequentially, and **any exit-2 blocks the tool call**. Order of registration within a matcher block is execution order. Current order (GH-13 additions shown in **bold**):

**On `git commit`:**

1. `check-secrets.sh`
2. `verify-commit-refs.sh`
3. **`validate-commit-format.sh`**
4. **`require-agdr-for-arch-changes.sh`**

**On `gh pr merge`:**

1. `block-unreviewed-merge.sh` (Rex + CEO markers)
2. **`require-design-review-for-ui.sh`**
3. **`block-merge-on-red-ci.sh`**

The ordering is deliberate: cheap local checks first, expensive remote checks (`gh pr checks`) last, so that a merge already blocked by Rex/CEO/design markers doesn't pay the network cost.

## Pre-existing Hooks

These were already in place before the enforcement layer and remain unchanged (except `validate-pr-create.sh` which was extended in GH-14 — see above). The newer hooks layer on top; nothing below is regressed.

| Hook | Event | Purpose |
|------|-------|---------|
| `block-git-add-all.sh` | PreToolUse / Bash | Blocks `git add -A / . / --all` |
| `block-main-push.sh` | PreToolUse / Bash | Blocks pushing to `main` / `master` |
| `validate-branch-name.sh` | PreToolUse / Bash | **Warns** on non-conforming branch names before push (warning-only; warning→blocker upgrade deferred to a follow-up ticket — breaking change) |
| `check-secrets.sh` | PreToolUse / Bash | Scans commits for hardcoded secrets |
| `pre-push-gate.sh` | PreToolUse / Bash | Reminds to run lint / typecheck / test / build |
| `validate-pr-create.sh` | PreToolUse / Bash | **Blocks** on title format / glossary / branch ID (upgraded from warning in GH-20). Also **blocks** when the title's issue number doesn't exist in the tracker (extended in GH-14). |

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
