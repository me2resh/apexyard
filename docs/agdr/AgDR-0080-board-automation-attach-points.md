# AgDR-0080 — Board automation: CLI attach-points with graceful-degrade vs GitHub Actions vs GitHub-native Workflows

> In the context of surfacing the SDLC lifecycle on a GitHub Projects (v2) board automatically,
> facing the choice of where and how to trigger card moves,
> I decided to use three framework attach-points (skills + hook) calling `gh project item-edit` directly,
> with full graceful degrade and an opt-in default,
> to achieve zero-friction board updates without requiring adopters to configure external Actions or bots,
> accepting the limitation that `gh project` scope must be present in the auth token.

## Context

ApexYard already fires at precise SDLC moments: `/start-ticket` (ticket activated),
`auto-code-review.sh` PostToolUse (PR created), and `/approve-merge` (PR merged).
Writing a board `Status` field at those moments gives a live board view for free.

Three implementation shapes were evaluated:

1. **Framework hook/skill calling `gh project item-edit`** — the CLI already exists,
   no extra workflow files needed, no GitHub App required, and the hook machinery
   (PostToolUse, skill steps) is exactly where these lifecycle events already fire.
2. **GitHub Actions workflow** — event-driven (issue_event, pull_request, etc.),
   lives in `.github/workflows/`, requires each managed project to configure secrets
   and install the workflow. Adds per-project boilerplate for what is fundamentally
   a portfolio-level concern.
3. **GitHub Projects built-in Workflows** — free, no code needed, but only cover
   three events (item added, item closed, PR merged). They handle the "Done" hop
   (closed → Done, merged → Done) well, but cannot fire on "ticket activated" or
   "PR created" because those are apexyard-specific lifecycle concepts, not GitHub
   primitive events.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Framework CLI attach-points (chosen)** | No extra files; hooks already own these moments; opt-in is one config key; graceful degrade keeps the feature safe by default; composable with GitHub-native Workflows for remaining hops | Requires `project` scope in `gh` auth; `gh project item-list` has a default page limit; card moves happen in-process (slight overhead) |
| GitHub Actions workflow | Event-driven, decoupled, idiomatic GitHub | Per-project boilerplate (secrets, workflow file); doesn't map to apexyard lifecycle concepts natively; adds CI dependency for a UX feature |
| GitHub-native Workflows only | Zero code, free | Only three events; cannot fire on apexyard's "ticket activated" or "PR created" concepts; no config-driven status mapping |

## Decision

Chosen: **Framework CLI attach-points** via `_lib-project-board.sh`, with the
following design constraints:

- **Opt-in**: `enable_auto_moves` defaults `false`. Adopters without a board are
  byte-for-byte unaffected.
- **Graceful degrade everywhere**: any failure (project/field/item not found,
  no `project` gh scope, misconfigured owner) warns to stderr and exits 0.
  The helper never exits non-zero and never blocks the lifecycle action.
- **Pin-first ops-root**: config is resolved via `resolve_ops_root()` from
  `_lib-ops-root.sh`, not plain `git rev-parse`, so split-portfolio adopters
  running inside `workspace/<project>/` see the ops-fork config.
- **Composable with GitHub-native Workflows**: the docs note encourages adopters
  to enable the "PR merged → Done" and "Item closed → Done" built-in Workflows
  for the transitions not covered by the three attach-points.

## Consequences

- Board card moves happen synchronously inside the hook/skill turn. On very large
  boards (>100 items), `gh project item-list` may be slow or miss items beyond
  the default page limit (mitigated by passing `--limit 200` to `item-list`).
- The `project` OAuth scope is required. Adopters using a fine-grained PAT without
  that scope will see graceful-degrade warnings until they re-auth.
- Future: a `--limit` config key under `github_projects` could let adopters tune
  the pagination ceiling without framework changes.

## Artifacts

- Implementation: `.claude/hooks/_lib-project-board.sh`
- Config: `.claude/project-config.defaults.json` → `github_projects`
- Docs: `docs/project-config.md` § "GitHub Projects board auto-move"
- Closes: me2resh/apexyard#725
- Cross-ref: me2resh/apexyard-premium#363
