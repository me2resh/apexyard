# Git Conventions

## Branch Naming

Format: `{type}/{TICKET-ID}-{description}`

Examples:

- `feature/ABC-123-add-auth`
- `fix/GH-45-login-bug`
- `docs/ENG-99-update-readme`

**Types**: `feature`, `fix`, `refactor`, `chore`, `docs`, `test`, `spike`, `ci`, `build`, `perf`

The `TICKET-ID` should reference an issue in the project's tracker. Default format: `#58` or `GH-58` (GitHub Issues). The validators in `.claude/hooks/` source the regex from `.tracker.id_pattern` in `.claude/project-config.{defaults,}.json` — the default pattern also matches any uppercase tracker prefix (e.g. `ABC-123`) for teams using Linear, Jira, or similar. See `_lib-tracker.sh` and AgDR-0033 for how to swap the active tracker; ApexYard's out-of-the-box default is per-project GitHub Issues, with one repo's issues never crossing into another repo's PRs.

## PR Title Format

Must match: `type(TICKET): description` or `type(TICKET)!: description` (breaking change)

Regex: `^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert|spike)\(<TICKET_ID_PATTERN>\)!?:`

`<TICKET_ID_PATTERN>` is sourced from `.tracker.id_pattern` so adopters get their own tracker's shape validation. Default matches `#123`, `GH-123`, or `[A-Z]{2,10}-[0-9]+` (Jira / Linear / similar).

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

Every change must go through a PR. Zero exceptions. No commits directly to `main`/`master`. Enforced by the `block-main-push.sh` hook.

## No Hardcoded Secrets

No API keys, passwords, tokens, or credentials in code. Use environment variables. Patterns to avoid:

- `api_key=`, `password=`, `secret=`, `token=`
- Cloud account IDs and ARNs
- Database connection strings
- Private keys or certificates

Enforced by the `check-secrets.sh` hook.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
