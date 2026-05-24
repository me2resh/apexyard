# apexyard/safety-hooks

**Production-grade safety hooks for Claude Code.** Drop this `.claude/` into any project and get seven shell hooks that mechanically prevent the most common git foot-guns: leaked secrets, direct pushes to main, `git add -A` over the whole tree, pushes without local lint/test, commits referencing non-existent issues, malformed PR titles, malformed branch names.

> One tooth of the [ApexYard](https://github.com/me2resh/apexyard) governance comb — extracted as a standalone marketplace plugin for individual engineers who want the safety net without forking the full framework. Read on for what's included, the 30-second quickstart, and the graduation path to the full ApexYard fork.

---

## What's included

**Seven hooks, all `PreToolUse` on `Bash`:**

| Hook | What it catches |
|------|-----------------|
| `check-secrets.sh` | API keys, passwords, tokens, AWS credentials, JWT secrets, private keys in staged diff at `git commit` time |
| `block-main-push.sh` | Direct `git push` to `main` / `master` (configurable). Every change must go through a PR. |
| `block-git-add-all.sh` | `git add -A` / `git add .` / `git add --all` — forces specific-file staging so sensitive files (`.env`, credentials.json) and large binaries don't get hoovered up |
| `pre-push-gate.sh` | Reminds you to run lint / typecheck / tests / build BEFORE pushing — prevents wasted CI minutes on broken pushes |
| `verify-commit-refs.sh` | Commit messages with `Closes #N` / `Refs #N` / `Fixes #N` pointing at issues that don't exist in your tracker. Catches typo + fabricated references. |
| `validate-pr-create.sh` | PR titles that don't match `type(TICKET): description` format, reference non-existent issues, or skip the ticket ID |
| `validate-branch-name.sh` | Branch names that don't match `{type}/{TICKET-ID}-{description}` — keeps git history scannable |

**Supporting libs (extracted from upstream):**

- `_lib-tracker.sh` — **tracker-agnostic** existence check. Default `gh` (GitHub Issues); configure `linear` / `jira` / `asana` / `custom` via `.claude/project-config.json`. Pluggable per AgDR-0033.
- `_lib-read-config.sh` — config reader (post-#310 ops-root fix; falls back gracefully outside an apexyard fork)
- `_lib-ops-root.sh` — ops-fork anchor resolver (walks up looking for `.apexyard-fork` v2 marker or legacy v1 anchor pair; falls back to `git rev-parse --show-toplevel` outside a fork)
- `_lib-extract-pr.sh` — extracts PR number from `gh pr ...` / `gh api .../pulls/<N>/...` command shapes

**Recommended wiring:**

See `.claude/settings.snippet.json` — copy the relevant `PreToolUse` entries into your project's `.claude/settings.json`.

## 30-second quickstart

1. Install via the Claude Code marketplace:

   ```text
   /plugin install apexyard/safety-hooks
   ```

2. Merge the `PreToolUse` entries from `.claude/settings.snippet.json` into your `.claude/settings.json` (your file already exists; you're appending to its `hooks.PreToolUse` array).

3. Start your next Claude Code session. From this point:

   - A staged secret in a `git commit -m` blocks at the shell level.
   - A `git push origin main` blocks at the shell level.
   - A PR title `feat: add CSV export` (missing ticket ID) blocks `gh pr create`.

Optional: configure your tracker by adding a `tracker` block to `.claude/project-config.json` if you're on Linear / Jira / Asana — see the [tracker config](#tracker-configuration) section below.

That's it. No portfolio setup, no fork, no registry.

## What's NOT included

Honest list of what stays in the full framework:

- **The two-marker merge gate** (`block-unreviewed-merge.sh`) — requires the Rex code-reviewer agent + the per-PR CEO approval pattern. Both depend on framework session-state at `.claude/session/reviews/` that doesn't make sense as a standalone hook.
- **The migration gate** (`require-migration-ticket.sh`) — requires a labelled tracker issue + AgDR pattern that depends on the framework's `/migration` skill and AgDR memory.
- **The active-ticket gate** (`require-active-ticket.sh`) — requires the framework's `/start-ticket` flow and the per-session current-ticket marker.
- **Leak protection** (`block-private-refs-in-public-repos.sh`) — requires the portfolio registry (`apexyard.projects.yaml`) to know what counts as "private project name".
- **Audit hooks family** — see the sibling `apexyard/audit-pack` plugin.

If any of that list resonates, the next step is [the full framework](#graduation-path-the-full-framework).

## Tracker configuration

By default, hooks call `gh issue view <N>` against your repo's `origin`. To use a different tracker, drop a `tracker` block into `.claude/project-config.json`:

```json
{
  "tracker": {
    "kind": "linear",
    "view_command": "linear issue view {id} --json",
    "id_pattern": "^[A-Z]+-[0-9]+$"
  }
}
```

Supported kinds: `gh` (default), `linear`, `jira`, `asana`, `custom`, `none`. See AgDR-0033 in the upstream repo for the full schema and per-kind examples.

If your tracker has no CLI, use `kind: "custom"` with a `view_command` that calls `curl` and a `normalise_jq` filter. If you want to skip existence verification entirely (rare), set `kind: "none"` — the hooks fall back to shape-only validation via `tracker.id_pattern`.

## Graduation path: the full framework

This sub-pack is one tooth of the ApexYard governance comb. The full framework includes everything above PLUS the two-marker merge gate, the migration gate, the active-ticket gate, leak protection, the Rex code-reviewer agent, AgDR memory, 19 role definitions, and a portfolio registry — and is delivered by **forking** the upstream repo into your own ops repo (it's not a plugin; the framework IS the ops repo).

If your scope grows past "I want the safety hooks" into "I want governed SDLC across a portfolio of repos", graduate to the full framework:

- **Upstream**: <https://github.com/me2resh/apexyard>
- **Landing site**: <https://yard.apexscript.com>
- **Setup guide**: `docs/multi-project.md` in the upstream repo (5 minutes from fork to first `/projects`)

The funnel direction is one-way: the marketplace plugin points at the framework, the framework doesn't push back. Use this sub-pack as long as it fits your scope; graduate when it doesn't.

## Maintenance contract — generated, not forked

This sub-pack is **extracted from upstream HEAD on every framework release tag**, not separately maintained. The framework remains the single source of truth; the sub-pack is a packaging artefact.

What this means for you:

- **Bug fixes flow automatically.** A fix on upstream lands here on the next release.
- **No drift.** The same files serve both distribution channels. The hook running via the plugin is byte-identical to the one running inside an ApexYard fork.
- **Versioning matches upstream.** `EXTRACTION_MANIFEST.json` in this dir records the exact upstream commit SHA this release was extracted from.

## License

Same as upstream: see `LICENSE` in <https://github.com/me2resh/apexyard>.

## See also

- `apexyard/audit-pack` — sibling sub-pack with the framework's audit suite (`/launch-check` + 8 deep-dives). Same funnel shape.
- AgDR-0033 — tracker-agnostic hook design rationale.
- AgDR-0049 — the strategic rationale for why these two sub-packs ship as a funnel rather than as the full framework.
