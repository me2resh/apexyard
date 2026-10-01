# Project Config

`.claude/project-config.defaults.json` contains the framework defaults. A fork
can create `.claude/project-config.json` to override selected keys. Both files
live in `.claude/`, so the ticket-first hook does not block these edits. See
`.claude/rules/workflow-gates.md` for the exemption.

Related: apexyard#109 introduced this scheme; apexyard#107, #111, #112, #113, #114, #115 all read from it.

## Files

| File | Who maintains | Purpose |
| --- | --- | --- |
| `.claude/project-config.defaults.json` | apexyard upstream | Shipped defaults. Do not edit in a fork — upstream syncs via `/update`. |
| `.claude/project-config.example.json` | apexyard upstream | Tracked template. Copy it to `project-config.json` to activate. Carries the framework repo's own pre-push dog-fooding as a worked example. |
| `.claude/project-config.json` | fork owner | Overrides. Optional. **Gitignored and untracked upstream** — keep it that way. |

### Why the real file is untracked (apexyard#1031)

This follows the `onboarding.example.yaml` and `onboarding.yaml` pattern. The
example is tracked so upstream can improve it. The real file stays local.

Before #1031, the framework tracked `project-config.json` and listed it in
`.gitignore`. Git does not ignore a file that is already tracked. A checkout
could therefore overwrite a fork's local configuration. For a split portfolio,
that could remove the `portfolio` block and break path resolution. The private
content was not in git, so the file could not be restored from history.

**If you have an existing fork that committed this file**, run `git rm --cached .claude/project-config.json` once. It leaves the file on disk and lets the ignore entry finally apply. Back the file up first if it holds a `portfolio` block: it is not recoverable from git.

#### Resolving the `/update` conflict — use `--cached`, or you lose the file

If you sync before doing the above, the merge hits a modify/delete conflict, because upstream deleted the file while your fork modified it:

```
CONFLICT (modify/delete): .claude/project-config.json deleted in upstream
and modified in HEAD. Version HEAD of .claude/project-config.json left in tree.
```

Git leaves your version on disk, so **nothing is lost yet**. The trap is the resolution. "Accept upstream's deletion" is the natural reading, and the obvious command for it destroys your config:

| Resolution | Effect |
|---|---|
| `git rm .claude/project-config.json` | ❌ removes it from the index **and from disk** — your `portfolio` block is gone, and it was never in git to restore from |
| `git rm --cached .claude/project-config.json` | ✅ removes it from the index only; the file stays on disk and the ignore entry now applies |

Always use `--cached` here. Back the file up first regardless — this is the same unrecoverable loss described above, reached by a different route.

### Why the framework's own `pre_push` is in the example, not the defaults

The defaults file would be the obvious home, and it is the wrong one. `_lib-read-config.sh` merges with `jq -s '.[0] * .[1]'`, so an adopter who defines no `pre_push` of their own **inherits whatever the defaults file ships** — which would mean every fork running apexyard's repo-specific commands on push, including its own `test_subpack_extraction.sh`. `pre_push.commands` in the defaults therefore stays `[]`, and `.claude/hooks/tests/test_project_config_untracked.sh` guards that it stays that way.

## Merge semantics

Objects merge recursively. Override values win scalar conflicts. Arrays replace
the inherited array as a whole. An override containing only
`"portfolio": {"registry": "custom"}` keeps other object members such as
`portfolio.stale_days`. An override of `ticket.bootstrap_skills` replaces that
array. The shared config reader gets this behavior from `jq -s '.[0] * .[1]'`.

**A warning names the entries that an array override drops (#1369).**
An override array that omits entries the matching default array carries
merges exactly as documented above. The override still wins, unchanged.
`_lib-read-config.sh` also prints one advisory `WARN:` line to stderr. The
line names the key and every dropped entry, the first time that override is
read in a session. Without a session ID, the cross-process cache has no key
to read or write, so the warning prints again in every new process. This
never blocks and never changes the merged value. It only makes an
otherwise-silent drop visible. It applies only to a key that has a default
array in `.claude/project-config.defaults.json`.
`migration_paths`, `migration_label`, `ui_paths`, `ui_paths_exclude`,
`design_paths`, `design_paths_exclude`, and `architecture_paths` have no
entry in `.claude/project-config.defaults.json` at all — their hook holds
the built-in default in code, not JSON. A drop against one of those produces
no warning today. See AgDR-0167 for why, and #1401 for the follow-up that
tracks closing this gap for those seven keys.

## Schema (v1)

```json
{
  "_schema_version": 1,

  "ticket": {
    "prefix_whitelist": ["Feature", "Bug", "Chore", "Refactor", "Testing", "CI", "Docs"],
    "label_priority_scheme": "P0,P1,P2,P3"
  },

  "branch": {
    "type_whitelist": ["feature", "fix", "refactor", "chore", "docs", "test", "spike", "ci", "build", "perf"]
  },

  "commit": {
    "type_whitelist": ["feat", "fix", "refactor", "test", "docs", "chore", "style", "perf", "build", "ci", "revert"]
  },

  "pr": {
    "title_type_whitelist": ["feat", "fix", "docs", "style", "refactor", "perf", "test", "build", "ci", "chore", "revert"]
  },

  "qa": {
    "pre_merge_offer": "ask"
  }
}
```

### Key meanings

| Key | Used by | Purpose |
| --- | --- | --- |
| `ticket.prefix_whitelist` | `/feature`, `/task`, `/bug`, (future) validate-issue-structure.sh | Bracketed title prefixes accepted for tickets (`[Feature]`, `[Chore]`, …). |
| `ticket.label_priority_scheme` | `/feature`, `/bug`, `/task`, (future) batch skill | Comma-separated priority label scheme. Teams using `P0/P1/P2/P3` vs. `priority-p0/priority-p1/…` configure here. |
| `branch.type_whitelist` | `validate-branch-name.sh` | Acceptable branch-name prefixes (`feature/`, `fix/`, …). |
| `commit.type_whitelist` | `validate-commit-format.sh` | Conventional-commit types for commit subjects. |
| `pr.title_type_whitelist` | `validate-pr-create.sh`, `pr-title-check.yml` (CI) | Conventional-commit types for PR titles. |
| `build.isolation` | `.claude/rules/isolated-builds.md`, `/fan-out`, build agents | Selects build isolation for the whole ops fork. Default: `worktree`. See [Build isolation](#build-isolation-buildisolation) and [AgDR-0210](agdr/AgDR-0210-build-isolation-setting.md). |
| `qa.pre_merge_offer` | `/code-review` | Controls the advisory pre-merge QA offer after Rex approves. Default: `ask`. |
| `leak_protection.public_framework_repos` | `check-private-refs-*.sh`, `block-private-refs-in-public-repos.sh` | Known-public `owner/repo` slugs. Origin identity is exempt when origin matches an entry. |
| `leak_protection.origin_verified_public` | `check-private-refs-staged.sh`, `check-private-refs-runtime.sh` | Exact origin `owner/repo` slug recorded by `/setup` or `/update` after `gh` confirms visibility is PUBLIC. Hooks stay offline and fail closed when this key is missing or does not match origin. See AgDR-0190. |

### Pre-merge QA offer

Set `qa.pre_merge_offer` in `.claude/project-config.json` to one of these values:

| Value | After Rex approves |
| --- | --- |
| `ask` | Ask whether Salim should verify the PR before merge. This is the default. |
| `always` | Run Salim on the PR branch before requesting merge approval. |
| `never` | Skip the offer. Run QA after merge through the existing `qa` label. |

With `ask`, a `no` answer keeps the existing post-merge QA flow. An invalid value falls back to `ask`.
With `always`, a ticket with no acceptance criteria produces INCOMPLETE and stops before merge approval.
A Rex re-review after a branch update offers QA again according to this setting.

The offer does not grant merge approval or create a merge gate. Only the human-invoked `/approve-merge` records approval and merges.
Salim posts a SHA-stamped result on the PR with evidence for every acceptance criterion.

Reuse a complete pre-merge QA PASS only when its stamped SHA matches the merged PR's final head SHA.
This is the PR head commit when it merged (the MR head SHA on GitLab).
A PASS stamped with an earlier head does not count.
Accept reports only from the repository owner, a member or a collaborator, or the account that posted the Rex review.
On GitHub, verify `author_association` of `OWNER`, `MEMBER` or `COLLABORATOR`, or the Rex account match.
Otherwise, run post-merge QA as usual.

## Build isolation (`build.isolation`)

The setting applies to the whole ops fork, not per project.
`worktree` creates `.claude/worktrees/<type>-<ticket>-<short-slug>` or uses the harness worktree.
`branch` creates a ticket branch in the local copy.
A managed project's `workspace/<name>` clone counts as the local copy for that project.

Any value other than `branch`, including an empty result, means `worktree`.
An empty result can occur when the config library cannot load from inside a `workspace/<name>` clone.

`branch` mode applies only to a foreground build spawn when no other writer is active on that checkout.
A background build spawn always uses a worktree, regardless of `build.isolation`.
Any build spawn while another writer is active on that checkout uses a worktree, regardless of `build.isolation`.
Parallel means overlapping writers, including a build agent still working from an earlier spawn.
The orchestrator decides the mode at spawn time and tells the agent which mode to use.
Work in another repository and risky destructive git also require a worktree.

In `branch` mode, run `git status --porcelain --untracked-files=no` before switching branches.
Dirty means tracked files with uncommitted changes or staged changes. Untracked files do not count.
Refuse to switch branches when dirty and say why.
Before each commit in `branch` mode, check that HEAD is still your ticket branch with `git branch --show-current`.
Stop if HEAD is no longer your ticket branch.
After merge in `branch` mode, return to the base branch and delete the local ticket branch.
Always tell the user the branch name.

## Extending the defaults

### Add a new ticket prefix (e.g. `[Security]`)

```json
{
  "ticket": {
    "prefix_whitelist": ["Feature", "Bug", "Chore", "Refactor", "Testing", "CI", "Docs", "Security"],
    "label_priority_scheme": "P0,P1,P2,P3"
  }
}
```

Every consumer (skills + validator) picks this up on next invocation — no framework edits needed.

### Use a different priority label scheme

```json
{
  "ticket": {
    "prefix_whitelist": ["Feature", "Bug", "Chore", "Refactor", "Testing", "CI", "Docs"],
    "label_priority_scheme": "priority-p0,priority-p1,priority-p2"
  }
}
```

## Reading the config from a hook

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
. "$REPO_ROOT/.claude/hooks/_lib-read-config.sh"

# Get a list of values
types=$(config_get '.branch.type_whitelist[]' | paste -sd'|' -)

# Get a single value with a fallback
scheme=$(config_get_or '.ticket.label_priority_scheme' 'P0,P1,P2,P3')
```

The reader uses `jq` for merging and path lookups. If `jq` is unavailable, the reader emits `{}` (quiet fallback) and prints a one-time warning on stderr — callers should apply their own safety nets.

## GitHub Projects board auto-move (opt-in, `github_projects`)

ApexYard can auto-move board cards at three SDLC lifecycle moments:

| Trigger | Status key | Default option label |
|---------|------------|----------------------|
| `/start-ticket` | `in_progress` | "In progress" |
| `gh pr create` (auto-code-review hook) | `review` | "In review" |
| `/approve-merge` | `measurement` | "Measurement" |

This is **opt-in** — the default config has `enable_auto_moves: false`. To enable:

```json
{
  "github_projects": {
    "owner": "my-org",
    "board_number": 3,
    "enable_auto_moves": true,
    "status_field_name": "Status",
    "status_map": {
      "in_progress": "In progress",
      "review":      "In review",
      "measurement": "Measurement"
    }
  }
}
```

- `owner` — GitHub organisation or user that owns the board.
- `board_number` — the numeric ID shown in the board URL (`/projects/<N>`).
- `status_field_name` — the name of the single-select field on your board. Default: `"Status"`.
- `status_map` — maps the three SDLC keys to the exact option label strings on your board. Adjust these to match your board's column names if they differ from the defaults.

### Graceful degrade

Any failure (board not found, item not on the board, missing `project` scope in `gh` auth, misconfigured owner/number) emits a `WARN` to stderr and returns 0. The lifecycle action that triggered the move — starting a ticket, creating a PR, merging — is never blocked.

### GitHub-native Workflows for the remaining transitions

For the "closed → Done" and "merged → Done" hops that happen outside the three
attach-points above, use GitHub Projects' built-in **Workflows** (open your board →
Settings → Workflows):

- **"Item added to project"** — auto-add issues/PRs when they are opened.
- **"Item closed"** — move a card to Done when its linked issue is closed.
- **"Pull request merged"** — move a card to Done when the linked PR is merged.

These are free, built-in, and require no configuration here. Enable them in the
GitHub UI and your board will reflect the full lifecycle without additional hook wiring.

The lib that implements board moves lives at `.claude/hooks/_lib-project-board.sh`.

## Backward compatibility

`validate-commit-format.sh` previously read a flat `commit_types` top-level key from `.claude/project-config.json`. That reader is still honoured as a fallback, so forks that customised commit types before apexyard#109 keep working without edits. New customisations should use the nested `commit.type_whitelist` form.
