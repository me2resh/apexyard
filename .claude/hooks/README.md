# ApexYard Hooks

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

**What it does:** blocks edits to any code path unless the working tree holds a ticket marker. Each tree keeps its marker in its own git dir. That is `<repo>/.git/apexyard-ticket`, or `<repo>/.git/worktrees/<id>/apexyard-ticket` for a linked worktree. So parallel sessions on one project never share a ticket. `_lib-active-ticket.sh` finds and validates the git dir with shell builtins and no git process (AgDR-0222). It trusts that marker only for the ops fork and registered clones. A registered clone is `workspace/<project>/` or the `workspace:` path of its registry entry. Symlinks, forged `.git` files and repos owned by another user are not trusted. The one write into a `.git` directory that needs no ticket is the marker and its temporary file. When no trusted marker exists, the hook uses the old-layout markers under `.claude/session/`, with the rules it used before the move. `/start-ticket` still writes them, and a SessionStart notice lists them (AgDR-0222, Backward compatibility). Exempts `.claude/`, `docs/`, `projects/*/docs/`, and any `*.md` file so framework / doc / meta work is still fluid.

**Enforces:** the Pre-Build Gate in `.claude/rules/workflow-gates.md` — "do not start coding until the ticket exists, has acceptance criteria, and is broken into tasks."

**Unblock:** run `/start-ticket <issue>`. The skill verifies the issue via `gh issue view`, and writes the marker into the git dir of the tree you run it in. It also writes the old-layout marker: per-worktree or per-project for a registered repo, else the fallback marker.

### 1a. Migration ticket-first — `require-migration-ticket.sh`

**Event:** `PreToolUse` on `Edit | Write | MultiEdit`. Runs **before** `require-active-ticket.sh` so migration-specific messages surface first.

**What it does:** if `FILE_PATH` matches a migration-path pattern (`migrate-*.{ts,js,py,sql}`, `**/migrations/**`, `prisma/schema.prisma` + `prisma/migrations/**`, `src/migrations/*.{ts,js}` for TypeORM, `alembic/versions/*.py`, `db/migrate/*.rb`), verifies three gates:

1. Active ticket marker exists (same resolution as hook #1)
2. The referenced tracker issue is OPEN and carries the `migration` label (default; overridable per project via `.claude/project-config.json` → `migration_label`)
3. The issue body references a migration AgDR at `docs/agdr/AgDR-\d+-.*migration.*\.md`

If any gate fails, blocks with a message pointing at the `/migration` skill. If `FILE_PATH` doesn't match a migration pattern, exits silently (hook #1 handles the normal ticket check).

**Enforces:** gate 3a in `.claude/rules/workflow-gates.md` — "any edit to migration paths requires a labelled migration ticket + linked AgDR".

**Unblock:** run `/migration` to create a labelled ticket + migration AgDR in one flow, then `/start-ticket` the new ticket.

### 2. Auto code review — `auto-code-review.sh`

**Event:** `PostToolUse` on `Bash(gh pr create *)`.

**What it does:** parses the PR URL from the `gh` output and writes a pending-review marker at `.claude/session/pending-reviews/<pr>`. It then emits a banner of at most 300 bytes (me2resh/apexyard#1625). The banner tells a build agent to report the PR and stop. It tells the orchestrator to wait for green CI with a Monitor, then run `/code-review`. Not a tool error — the PR is created fine. The hook just pushes the next step into the conversation so it can't be forgotten.

Companion control: `block-reviewer-ci-wait.sh` (PreToolUse, through `dispatch-bash.sh`). For review agents only, it blocks `gh pr checks --watch`, `gh run watch`, `sleep` of 60 seconds or more, and a second `gh pr checks` in one review run. It finds a review agent from the `agent_type` field of the hook input. For a sub-agent that has no type, it uses the active-reviewer marker. The orchestrator is never blocked.

**Enforces:** the "After `gh pr create` → Invoke Code Reviewer agent" section of `.claude/rules/pr-workflow.md` and the Code Review phase of `workflows/sdlc.md`.

### 3. Merge gate — `block-unreviewed-merge.sh`

**Event:** `PreToolUse` on `Bash(gh pr merge *)`.

**What it does:** blocks the merge unless **both** approval markers exist for the PR number being merged, and both contain a SHA that matches the current HEAD. New commits after either approval invalidate it.

| Marker | Path (repo-qualified since #485) | Written by | Semantics |
|--------|----------------------------------|------------|-----------|
| Rex | `.claude/session/reviews/<owner>__<repo>__<pr>-rex.approved` | `code-reviewer` agent after a successful review | "Code reviewed, no blocking issues" |
| CEO | `.claude/session/reviews/<owner>__<repo>__<pr>-ceo.approved` | `/approve-merge <pr>`, or `record-menu-approval.sh` after a menu answer | "The human approver has looked at this specific PR and said ship it" |

Marker paths are constructed via `_lib-review-markers.sh::review_marker_path <owner/repo> <pr> <role>`. The double-underscore separator ensures the (owner, repo, pr) triple is unambiguous — GitHub slugs never contain `__`. This prevents same-numbered PRs in different managed repos from colliding on the same marker filename (AgDR-0060).

A Rex marker holds one line, the 40-character HEAD SHA. A typed CEO marker is a `skill_version=2` record. A menu record is `skill_version=3` with `approval_channel=menu`. The gate compares the recorded SHA with the PR head. It blocks on a mismatch.

**Why two markers:** The Rex marker alone isn't enough because it would only enforce the "code review happened" half of the 2-reviews rule. The CEO marker is the mechanical enforcement of **"plan-level 'go' is NOT merge approval"** from `.claude/rules/pr-workflow.md`. A plan-level authorization does not produce the CEO marker. The `/approve-merge` skill writes it on an explicit per-PR nod. The menu hook writes it when the operator selects the approve option. This closes the failure mode where Claude infers merge approval from an umbrella "go" on a broader plan.

**Trust model:** the approval files are **local session state**, not a remote trust boundary. They're gitignored and live on the user's machine. Claude can technically `rm` or `touch` them directly, and a malicious local user could forge them too. That's fine — the goal is to prevent Claude (an automated agent in the same session) from merging without the discrete review-and-approve moments, not to protect against an adversary who owns the machine. The failure mode the hook closes is **invisible inference** ("Claude decided 'go' meant 'merge'"); it converts that into **visible rule violation** ("Claude `touch`ed the marker without being asked"). The latter is grep-able and auditable; the former is not.

For adversarial trust, rely on remote branch-protection rules (GitHub required reviews, CODEOWNERS, required status checks). This hook complements those, it does not replace them.

**Enforces:** `workflow-gates.md` rule #5 ("2 reviews, CI green, commit SHA matches review") AND `pr-workflow.md` § "Plan-level 'go' is NOT merge approval".

**Companion paths:** `/approve-merge <pr>` writes the typed CEO marker. The approval menu is the other path. `record-menu-approval.sh` writes that record. See AgDR-0234.

### 3a. Menu approval — `record-menu-approval.sh`

**Event:** `PostToolUse` on `AskUserQuestion`.

The operator can approve a merge, a design review, or an architecture review from a menu. The question must name the repo, the PR, and the full head SHA. The selected option must be the exact approve label.

The hook reads the harness payload. It writes `approval_channel=menu` and `skill_version=3`. `Not yet` writes nothing. The menu record has the same trust level as a typed marker. The guard is a text-match backstop (AgDR-0104); the real control is the human-only menu answer plus the gate's head-SHA match.

`block-forged-menu-approval.sh` blocks Edit, Write, and Bash writes of that channel onto a marker file. The guard matches text. It is a backstop. See AgDR-0234 and AgDR-0104.

The typed commands stay. A typed merge marker has no menu channel.

### 4. Onboarding — `onboarding-check.sh`

**Event:** `SessionStart`.

**What it does:** on every new session, if `.claude/session/onboarded` is missing, injects a reminder telling Claude to run `/onboard` with the user before doing work. The `/onboard` skill asks the day-one discovery questions (project identity, tracker, required checks, reviewers, UI, deploy targets, sensitive topics) and writes the marker plus `.claude/project-config.json`.

### 4a. Upstream drift — `check-upstream-drift.sh`

**Event:** `SessionStart`.

**What it does:** if the repo has an `upstream` remote, runs `git fetch upstream --quiet` (cached to once per 10 minutes via `.claude/session/last-upstream-fetch`) and prints a one-line banner when the local default branch is behind `upstream/<default-branch>`:

```
ApexYard: 12 commits behind upstream/main. Run /update to sync.
```

Silent if: no `upstream` remote (upstream repo itself, or fork that hasn't configured it), fetch fails (offline / hosting down), or up-to-date.

**Runtime:** < 200ms on cache hit, 1-3s on cache miss (depends on fetch latency). `timeout 5 git fetch` caps the worst case.

**Companion skill:** `/update` performs the actual sync.

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

Four more hooks added by the rule-audit ticket ([#13](https://github.com/me2resh/apexyard/issues/13)) and recorded in [`docs/agdr/AgDR-0001-rule-mechanization-hooks.md`](../../docs/agdr/AgDR-0001-rule-mechanization-hooks.md). Each closes a specific "prose rule the model drops under pressure" gap that the audit surfaced.

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

**Enforces:** `.claude/rules/agdr-decisions.md § "Enforcement — and the honest limits of it"` — this hook is the mechanical, commit-time backstop for the materiality threshold defined in § "The threshold"; the rule was prose-only until this hook shipped.

### 8. Design-review-for-UI merge gate — `require-design-review-for-ui.sh`

**Event:** `PreToolUse` on `Bash(gh pr merge *)`.

**What it does:** if the PR's diff touches any UI file, requires a design-approval marker at `.claude/session/reviews/<owner>__<repo>__<pr>-design.approved` (repo-qualified, see AgDR-0060) with a SHA matching HEAD. Non-UI PRs bypass silently.

**Default UI paths** (regex, shared with `/approve-design` step 5 via `.claude/hooks/_lib-ui-paths.sh` — one list, not two, since me2resh/apexyard#1390):

```
\.tsx$                    # React (TSX only, NOT plain .ts)
\.jsx$                    # React (JSX only, NOT plain .js)
\.vue$
\.svelte$
\.astro$                  # Astro components
\.mdx$                    # MDX (Markdown + JSX)
\.hbs$ / \.njk$ / \.liquid$  # Handlebars / Nunjucks / Liquid templates
\.css$ / \.scss$ / \.sass$ / \.less$
design-tokens
```

**Critical note:** `.tsx`/`.jsx` are matched **exactly**, not as `.tsx?` / `.jsx?`. The original draft had the regex-optional form, which also matched plain `.ts` and `.js` files — caught in smoke testing and fixed before merge. Server-side TypeScript/JavaScript should never trigger a design gate.

**Customize:** `.ui_paths` in `.claude/project-config.json` (REPLACES the default list wholesale — see `docs/project-config.md`). `_lib-ui-paths.sh` filters out a malformed entry (`null`, an object, a nested array, or a whitespace-only string). If every entry is malformed, the library falls back to the shipped defaults above instead of resolving to an empty, always-passing pattern list. Hakim's LOW-2 (me2resh/apexyard#1397) reported this gap.

**Companion paths:** `/approve-design <pr>` writes the typed marker. The menu hook can also write a design record. See AgDR-0234. The typed skill checks the PR state and the Rex marker at HEAD. It then writes the design marker. It stops. The skill definition includes explicit valid and invalid triggers. It also separates mockup approval from review of the PR diff.

**Manual fallback:** for projects that deliberately skip design review (admin tools, internal dashboards), create `touch .claude/session/reviews/<owner>__<repo>__<pr>-design.approved` (using the repo-qualified name) as a visible, auditable "we decided to skip" artifact.

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
| "No checks reported" (no CI configured) | Allow with a NOTE to stderr — legitimate state for early apexyard forks |

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

## PWD-vs-command-context distinction

The harness's `$PWD` at hook-invocation time is whatever directory the parent
session was sitting in when it dispatched the tool call. For most single-shell
sessions that happens to match the worktree the operator is editing — but it
**does not have to**. Three failure modes recur:

1. **Agent fan-out workers** — `/fan-out` (and direct `Agent` calls with
   `isolation: "worktree"`) spawn parallel agents that `cd` into per-task
   worktrees. The parent harness's `$PWD` may still point at a sibling
   worktree or the ops-fork root.
2. **Cross-repo shells** — operators routinely run `gh pr create --repo X`
   from a clone of repo Y when bouncing between projects.
3. **Backgrounded long-running shells** — a tool call dispatched from a
   shell whose `cwd` has drifted since session start.

The lesson from #194 (validation hooks) and #47 (the `gh api .../merge` bypass)
is the same: **gate on the command's actual context, not on the harness's
`$PWD`**. The command itself almost always carries the truth — `--head`,
`--repo`, the push source-ref, the API path's `/pulls/<N>/merge` segment.
Falling back to `$PWD`-derived state (`git branch --show-current`,
`git rev-parse HEAD`, repo-root via parent-walk) is acceptable as a fallback
when the command does not name the context, but it must never override what
the command says.

For hook authors:

- Prefer the command-arg-first, fallback-to-local-context shape:
  `BRANCH="${HEAD_FLAG:-$(git branch --show-current)}"`. The fallback
  preserves backwards compatibility for shapes that don't pass the flag.
- Centralise extraction in a `_lib-extract-*.sh` helper rather than reimplementing
  the parsing inline in each hook — same pattern as `_lib-extract-pr.sh` for
  the merge-gate hooks. One helper, one set of tests, all hooks safe.
- Heredoc substitution (`-m "$(cat <<EOF...)"`) is a special case where the
  command string the hook reads is **literal-pre-expansion** — the actual
  message lives in the heredoc body and is invisible to the hook. Detect the
  shape and skip validation rather than block; recommend the file-based
  alternative (`git commit -F file`) in the INFO message so operators who
  want full validation on multi-line content know where to go.

Helpers that implement this convention:

| Helper | Used by | What it parses |
|--------|---------|----------------|
| `_lib-extract-pr.sh` | `block-unreviewed-merge.sh`, `require-design-review-for-ui.sh`, `block-merge-on-red-ci.sh` | PR number from `gh pr merge` and `gh api .../pulls/<N>/merge` |
| `_lib-extract-push-ref.sh` | `validate-branch-name.sh` | Source ref from `git push origin <ref>` (and refspec / -u / --set-upstream / --force-with-lease variants) |
| `_lib-orbit-records.sh` | `validate-branch-name.sh`, `validate-pr-create.sh` | Validate ORBIT records branch names, simple pushes, and files against remote trunk refs |
| `_lib-flag-value.sh` | `validate-issue-structure.sh`, `require-agdr-for-arch-pr.sh`, `block-private-refs-in-public-repos.sh`, `require-orbit-slice-for-ticket.sh` | Quoted flag value from a command string. Callers pass the trim and the dash anchor their previous copy used. |

When you add a new hook that depends on git state, ask first: "is the answer
already in the command string?" If yes, parse it from there. If no, falling
back to local context is fine — but document the trade-off.

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

All three merge-gate hooks are **also** registered on `Bash(gh api *)` so the REST-API merge shape (`gh api repos/<owner>/<repo>/pulls/<N>/merge -X PUT`) can't silently bypass them. The merge-shape detection and PR-number extraction live in the shared sourced helper `_lib-extract-pr.sh` — any future change to PR-number parsing should be made there, not in the individual hooks. Context: [#47](https://github.com/me2resh/apexyard/issues/47).

The ordering is deliberate: cheap local checks first, expensive remote checks (`gh pr checks`) last, so that a merge already blocked by Rex/CEO/design markers doesn't pay the network cost.

## Pre-existing Hooks

These were already in place before the enforcement layer and remain unchanged (except `validate-pr-create.sh` which was extended in GH-14 — see above). The newer hooks layer on top; nothing below is regressed.

| Hook | Event | Purpose |
|------|-------|---------|
| `block-git-add-all.sh` | PreToolUse / Bash | Blocks `git add -A / . / --all` |
| `block-main-push.sh` | PreToolUse / Bash | Blocks pushing to `main` / `master` |
| `validate-branch-name.sh` | PreToolUse / Bash | **Warns** on non-conforming branch names before push (warning-only; warning→blocker upgrade deferred to a follow-up ticket — breaking change) |
| `check-secrets.sh` | PreToolUse / Bash | Scans commits for hardcoded secrets |
| `block-onboarding-in-git.sh` | PreToolUse / Bash | Blocks committing a filled-in `onboarding.yaml` (placeholder-diff vs `onboarding.example.yaml`); env/marker escape hatch (#517) |
| `pre-push-gate.sh` | PreToolUse / Bash | Reminds to run lint / typecheck / test / build |
| `validate-pr-create.sh` | PreToolUse / Bash | **Blocks** on title format / glossary / branch ID (upgraded from warning in GH-20). Also **blocks** when the title's issue number doesn't exist in the tracker (extended in GH-14). |

## Session State Directory

`.claude/session/` is gitignored. It holds per-machine, per-clone state:

```
.claude/session/
├── onboarded                     # created by /onboard, read by onboarding-check
├── pending-reviews/<pr>          # created by auto-code-review, tracks PRs awaiting Rex
├── reviews/<owner>__<repo>__<pr>-rex.approved           # created by code-reviewer agent, read by merge-gate
├── reviews/<owner>__<repo>__<pr>-ceo.approved           # created by /approve-merge, read by merge-gate
├── reviews/<owner>__<repo>__<pr>-design.approved        # created by /approve-design, read by UI merge-gate
└── reviews/<owner>__<repo>__<pr>-architecture.approved  # created by /approve-architecture, Tariq, or the menu hook
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

### ORBIT records PRs

A ticket-free records PR uses `orbit/<initiative-id>-<description>` and
`docs(orbit/<initiative-id>): <description>`. The initiative ID is the Plan ID
without `plan-`. Resolve the longest existing ID prefix from Plan records on
the branch. Unknown IDs fail closed. The PR body and every commit carry
`Initiative: plan-<initiative-id>` instead of a ticket reference.
The body exception applies only after the branch and records-only diff qualify.
Remote trunk refs, one simple push, and the `docs/orbit/` boundary remain required.
Records lint checks initiative ownership and referenced Snapshots.
