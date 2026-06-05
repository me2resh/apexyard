# Suggest MCP reindex after a workspace clone is pulled/updated

> In the context of the MCP search index going silently stale when a managed-project
> workspace clone is updated via git, facing the choice of *which event* should fire the
> reindex reminder, I decided to fire a non-blocking advisory hook on a git HEAD-move
> inside a `workspace/<name>/` clone (pull / merge / checkout / reset) — scoped to the
> changed project — to achieve fresh `search_code` / `search_docs` results without nagging,
> accepting that over-firing a cheap advisory is preferable to under-firing.

## Context

`suggest-mcp-reindex-after-clone.sh` (#475) closed the post-*clone* staleness gap: when
`/handover` clones a repo into `workspace/<name>/`, the hook reminds the agent to reindex
that project so the deep-dive phases can use semantic search instead of grep + Read.

The companion gap (#478) is the post-*update* case. After the initial clone, an agent often
pulls new commits into a workspace clone (`git pull`, `git fetch && merge`, a branch
`checkout`, a `reset --hard`). Nothing reindexes the project after that drift, so
`search_code` returns stale or `not_indexed` excerpts and the agent silently falls back to
grep — the exact failure mode #475 set out to remove, reintroduced on the second and every
subsequent visit to the clone.

The hook is advisory (exit 0 always, stderr banner) like its clone sibling and
`check-upstream-drift.sh` — it cannot force a reindex, only remove the "I forgot the index
went stale" failure mode.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Fire on every Edit/Write in a workspace clone** | Catches all drift, including local edits | Far too noisy — one banner per file save; a single edited file barely moves the index, so the signal-to-noise ratio is terrible. Explicitly ruled out by the issue. |
| **Fire on a git HEAD-move in a workspace clone (chosen)** | High-signal — a pull can rewrite the whole tree in one step, which is exactly when the index goes meaningfully stale; coarse-grained, so low banner volume | Misses purely-local edits that never pass through git (acceptable — those barely move the index, and the agent is editing them so it already knows they changed) |
| **Block the agent until it reindexes** | Guarantees a fresh index | Wrong shape entirely — reindex is best-effort and the MCP server may be unavailable; a blocking gate on an advisory concern would be hostile and break offline work |
| **Always reindex the whole portfolio on any workspace git op** | Simplest detection | Wasteful — only one project changed; portfolio-wide reindex is slow and burns tokens for no benefit. Scope to the changed project. |

## Decision

Chosen: **fire a non-blocking advisory hook on a git HEAD-move inside a `workspace/<name>/`
clone, scoped to the changed project**, because it matches the coarse, high-signal moment the
index actually goes stale while keeping banner volume low and respecting the best-effort,
offline-tolerant nature of MCP reindexing.

Sub-decisions:

- **Trigger granularity — HEAD-move, not per-edit.** The hook matches `git pull|merge|checkout|reset`
  at a command boundary. Per-file Edit/Write is explicitly out of scope (noise). A bare
  `git fetch` is not matched (it does not move HEAD); a `git fetch && git merge` compound is
  caught by the `merge` token.
- **Debounce on "Already up to date."** When the tool output shows the pull changed nothing,
  the hook stays silent. When the output isn't available (or the change came via
  merge/checkout/reset with no such marker), the hook fires anyway. **Tradeoff:** over-firing a
  cheap advisory is acceptable; under-firing defeats the purpose — a real drift that goes
  un-reindexed produces silent stale results, the precise failure #478 exists to prevent.
- **Project detection — cwd first, path-arg fallback.** A `git pull` is normally run from
  *inside* the clone (cwd = `workspace/<name>`), so the hook reads `.cwd` / `.tool_input.cwd`
  from the PostToolUse payload first, then falls back to an explicit `-C <path>`, a `cd <path> &&`
  prefix, or any bare `workspace/<name>` token in the command. cwd-based detection depends on
  the harness populating cwd in the payload; the path-arg fallbacks cover the cases where it
  doesn't.
- **Scope to the changed project only** — the banner names
  `reindex(scope="project", project="<name>")`, never a portfolio-wide reindex.
- **Skip on failed command** (`tool_response.exit_code != 0`) — no point reindexing after a
  pull that errored.

## Consequences

- A new advisory hook `suggest-mcp-reindex-after-pull.sh` (hook count 37 → 38; site counts and
  `CLAUDE.md` updated accordingly).
- Wired as a PostToolUse Bash hook with `if: "Bash(git *)"` so all direct-git HEAD-move shapes
  reach it; the hook's internal command-boundary match keeps it a fast no-op on
  `git push`/`commit`/`add`/`clone` and on non-workspace pulls.
- The `cd workspace/<name> && git pull` shape is best-effort: the settings `if` glob is
  prefix-anchored on `git *`, so a `cd …`-led compound only reaches the hook when the harness
  also surfaces cwd in the payload (the dominant case). The hook still handles the `cd` prefix
  internally for the shapes that do reach it.
- Behaviour mirrors the clone sibling and `check-upstream-drift.sh`: non-blocking, exit 0
  always, graceful when the MCP server is unavailable.

## Artifacts

- Hook: `.claude/hooks/suggest-mcp-reindex-after-pull.sh`
- Test: `.claude/hooks/tests/test_suggest_mcp_reindex_after_pull.sh`
- Wiring: `.claude/settings.json` (PostToolUse → Bash)
- Issue: me2resh/apexyard#478 (companion to #475)
