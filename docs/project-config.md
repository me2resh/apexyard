# Project Config

`.claude/project-config.defaults.json` ships the framework defaults. Each fork optionally creates `.claude/project-config.json` to override specific top-level keys. Both files live inside `.claude/`, so edits are exempt from the ticket-first hook (per `.claude/rules/workflow-gates.md`).

Related: apexyard#109 introduced this scheme; apexyard#107, #111, #112, #113, #114, #115 all read from it.

## Files

| File | Who maintains | Purpose |
| --- | --- | --- |
| `.claude/project-config.defaults.json` | apexyard upstream | Shipped defaults. Do not edit in a fork — upstream syncs via `/update`. |
| `.claude/project-config.json` | fork owner | Overrides. Optional. Commit or gitignore per the fork's preference. |

## Merge semantics

**Shallow** at the top level. If the override file defines `"ticket": {...}`, that entire subtree replaces the default `ticket` subtree. To extend rather than replace, copy the default fields and add new ones. This keeps the merge behaviour predictable without requiring deep-merge semantics in shell scripts.

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
