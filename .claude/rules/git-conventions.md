# Git Conventions

## Branch Naming

Format: `{type}/{TICKET-ID}-{description}`

Examples:

- `feature/ABC-123-add-auth`
- `fix/GH-45-login-bug`
- `docs/ENG-99-update-readme`

**Types**: `feature`, `fix`, `refactor`, `chore`, `docs`, `test`, `spike`, `prototype`, `ci`, `build`, `perf`

The `TICKET-ID` should reference an issue in the project's tracker. Default format: `#58` or `GH-58` (GitHub Issues). The validators in `.claude/hooks/` source the regex from `.tracker.id_pattern` in `.claude/project-config.{defaults,}.json` — the default pattern also matches any uppercase tracker prefix (e.g. `ABC-123`) for teams using Linear, Jira, or similar. See `_lib-tracker.sh` and AgDR-0033 for how to swap the active tracker; ApexYard's out-of-the-box default is per-project GitHub Issues, with one repo's issues never crossing into another repo's PRs.

### ORBIT records branches

Use `orbit/<initiative-id>-<description>` without a ticket only when every changed file is under `docs/orbit/`.
Use lowercase kebab segments for the branch suffix.
The initiative ID is the Plan record ID without `plan-`. For `plan-apexyard-scaffold`, use `orbit/apexyard-scaffold-first-slice`.
The hook resolves the longest existing Plan ID prefix on the branch and blocks unknown initiatives.
Use the title `docs(orbit/<initiative-id>): <description>` for these records PRs.
The validators fail closed when they cannot verify the files or remote trunk base.
The PR body must contain the exact line `Initiative: plan-<initiative-id>` instead of a ticket reference.
Every commit carries the same `Initiative: plan-<initiative-id>` trailer.
Find all changes with `git log --grep "Initiative: plan-<initiative-id>"`.
Records lint rejects records from other initiatives. Snapshots require a reference from a changed Reconciliation.
Review gates, merge gates, and per-PR approval still apply.

## PR Title Format

Must match: `type(TICKET): description` or `type(TICKET)!: description` (breaking change)

Regex: `^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert|spike|prototype)\(<TICKET_ID_PATTERN>\)!?:`

`<TICKET_ID_PATTERN>` is sourced from `.tracker.id_pattern` so adopters get their own tracker's shape validation. Default matches `#123`, `GH-123`, or `[A-Z]{2,10}-[0-9]+` (Jira / Linear / similar).

- Use `docs(orbit/<initiative-id>): <description>` only for qualifying ORBIT records branches.
- One ticket ID per PR title — multi-ticket titles like `fix(ABC-1,2,3):` are rejected
- GitHub Issues use `#XX` format: `fix(#58): description`
- Breaking changes use `!` before the colon: `feat(#58)!: remove deprecated v1 endpoints`

## Commit Message Format

```
type: subject
type!: subject (breaking change)
type(scope)!: subject (breaking change with scope)

- Detailed change 1
- Detailed change 2

Closes #123
```

**Types**: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `style`, `perf`

## File Staging

**NEVER** use `git add -A`, `git add .`, or `git add --all`. Always add specific files:

```bash
git add src/specific-file.ts
```

This is enforced by the `block-git-add-all.sh` hook.

## No Direct Main

Every change must go through a PR. One operator action is the only exception. The operator makes the initial commit and push of the new, empty portfolio repository that `/setup` Step 2b creates. An agent never makes that commit or that push, and the gates still block it. No commits directly to `main`/`master`. Enforced at the git layer by `.githooks/pre-push` (terminal `git push`) and `.githooks/pre-commit` (terminal `git commit`) — both read git's own ground-truth ref/branch resolution, no command-text parsing (me2resh/apexyard#1086). `.claude/hooks/block-main-push.sh` is a blocking **backstop** on top: a Claude Code PreToolUse hook, so it stays effective against `--no-verify` (which structurally bypasses the two git-native hooks above) and on managed-project clones that haven't installed `core.hooksPath` (#1088). See [AgDR-0114](../../docs/agdr/AgDR-0114-block-main-push-honest-naming-blocking-backstop.md) for the full control-vs-backstop rationale.

Resolve command targets from payload cwd, the cd chain, each `-C`, then `--git-dir` and `--work-tree`. Follow literal leading `cd` commands before `&&`, `;`, or a newline. Support `cd X || exit N` and `cd X || return N` tails. Block missing, unresolvable, or non-leading directory commands. Commit gates use the same target rule.

Git aliases that reach push or commit block. Run the real verb so the gates can
check it. Shell aliases block; run the alias body directly. The dispatcher and
each block-mode gate use the resolver in [AgDR-0253](../../docs/agdr/AgDR-0253-git-alias-resolution-gates.md).
Its “Block messages” table gives the exact messages for config channels,
unreadable inline config, opaque verbs, candidate and target limits,
definition evidence, conditional includes, autocorrect and config read failures.

## No Hardcoded Secrets

No API keys, passwords, tokens, or credentials in code. Use environment variables. Patterns to avoid:

- `api_key=`, `password=`, `secret=`, `token=`
- Cloud account IDs and ARNs
- Database connection strings
- Private keys or certificates

Enforced by the `check-secrets.sh` hook.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
