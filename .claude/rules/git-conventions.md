# Git Conventions

## Branch Naming

Format: `{type}/{TICKET-ID}-{description}`

Examples:

- `feature/ABC-123-add-auth`
- `fix/GH-45-login-bug`
- `docs/ENG-99-update-readme`

**Types**: `feature`, `fix`, `refactor`, `chore`, `docs`, `test`, `spike`, `prototype`, `ci`, `build`, `perf`

The `TICKET-ID` should reference an issue in the project's tracker. Default format: `#58` or `GH-58` (GitHub Issues). The validators in `.claude/hooks/` source the regex from `.tracker.id_pattern` in `.claude/project-config.{defaults,}.json`. The default pattern also matches any uppercase tracker prefix (e.g. `ABC-123`) for teams using Linear, Jira, or similar. See `_lib-tracker.sh` and AgDR-0033 for how to swap the active tracker. ApexYard's out-of-the-box default is per-project GitHub Issues, with one repo's issues never crossing into another repo's PRs.

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

`<TICKET_ID_PATTERN>` comes from `.tracker.id_pattern` so adopters get their own tracker's shape validation. Default matches `#123`, `GH-123`, or `[A-Z]{2,10}-[0-9]+` (Jira / Linear / similar).

- Use `docs(orbit/<initiative-id>): <description>` only for qualifying ORBIT records branches.
- One ticket ID per PR title: validators reject multi-ticket titles like `fix(ABC-1,2,3):`
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

Verified: tests
```

**Types**: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `style`, `perf`

### Verification trailer

Add one `Verified:` trailer to the final trailer block of each commit message.
Use `e2e`, `tests`, `ci-only`, or `none`.
These values mean end-to-end checks, other tests, CI checks only, or no verification.
The commit-format hook warns for missing or invalid values. These warnings never block.

The hook checks readable `-m`, `-F`, and supported cat-heredoc messages.
Interactive messages retain their existing validation limits.
List the latest 50 commits by value with `bash bin/verified-commits.sh`.
Pass a positive commit count to change the limit.
The report includes `missing` and `invalid` groups.

### Modes for new gates

Existing gates always enforce their checks. Config cannot change their modes.
Only new gates can use `.claude/hooks/_lib-gate-mode.sh`.
Add each new gate name to the library's literal allowlist before calling it.
The allowlist starts empty. Config alone cannot register a gate.

Declare the gate name and its default mode in the new gate's code.
The default is `enforce` unless the new gate declares `observe`.
Set `.gates.<name>.mode` to `off`, `observe`, or `enforce` in project config.
Invalid modes use `enforce`. Unregistered gates refuse mode resolution and block.

Call `gate_would_block NAME DEFAULT EVENT_CODE OPS_ROOT` only when the new check would block.
Exit with its return code: `0` allows the action and `2` blocks it.
Use a fixed event identifier. Never log command text or secrets.

`off` allows without logging. `enforce` blocks. `observe` appends one JSON line and allows.
The log is `.claude/session/gate-observe.log`. The session directory is already gitignored.
Logging failures warn and allow in observe mode.

`/status --briefing` appends the event count to its role line when the log contains entries.
The count covers the retained log. Remove the local log to reset the count.

## File Staging

**NEVER** use `git add -A`, `git add .`, or `git add --all`. Always add specific files:

```bash
git add src/specific-file.ts
```

The `block-git-add-all.sh` hook enforces this.

## No Direct Main

Every change must go through a PR. One operator action is the only exception. The operator makes the initial commit and push of the new, empty portfolio repository that `/setup` Step 2b creates. An agent never makes that commit or that push, and the gates still block it. No commits directly to `main`/`master`. Enforced at the git layer by `.githooks/pre-push` (terminal `git push`) and `.githooks/pre-commit` (terminal `git commit`). Both read git's own ground-truth ref/branch resolution, no command-text parsing (me2resh/apexyard#1086). `.claude/hooks/block-main-push.sh` is a blocking **backstop** on top: a Claude Code PreToolUse hook. Thus it stays effective against `--no-verify` (which structurally bypasses the two git-native hooks above). It also stays effective on managed-project clones that have not installed `core.hooksPath` (#1088). See [AgDR-0114](../../docs/agdr/AgDR-0114-block-main-push-honest-naming-blocking-backstop.md) for the full control-vs-backstop rationale.

Resolve command targets from payload cwd, the cd chain, each `-C`, then `--git-dir` and `--work-tree`. Follow literal leading `cd` commands before `&&`, `;`, or a newline. Support `cd X || exit N` and `cd X || return N` tails. Block missing, unresolvable, or non-leading directory commands. Commit gates use the same target rule.

Git aliases that reach push or commit block. Run the real verb so the gates can
check it. Shell aliases block; run the alias body directly. The dispatcher and
each block-mode gate use the resolver in [AgDR-0253](../../docs/agdr/AgDR-0253-git-alias-resolution-gates.md).
Its “Block messages” table gives the exact messages for config channels,
unreadable inline config, opaque verbs, and candidate and target limits.
It also gives the exact messages for definition evidence, conditional includes,
autocorrect and config read failures.

## No Hardcoded Secrets

No API keys, passwords, tokens, or credentials in code. Use environment variables. Patterns to avoid:

- `api_key=`, `password=`, `secret=`, `token=`
- Cloud account IDs and ARNs
- Database connection strings
- Private keys or certificates

Enforced by the `check-secrets.sh` hook.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*
