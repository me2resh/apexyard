# AgDR-0219: Match ticket-gate path exemptions to the file's own worktree top

> For issue #1531, I chose to match `.claude/` and `docs/` exemptions against the edited file's own git toplevel so linked-worktree source stays gated after AgDR-0141 rewrites `REPO_ROOT` to the main clone.

## Context

`require-active-ticket.sh` rewrites `REPO_ROOT` to the main checkout for linked worktrees (AgDR-0141). That keeps ops-root and marker lookup correct.

The same rewritten root built `REL_PATH` for path exemptions. A write to `<repo>/.claude/worktrees/feat-x/src/a.ts` became `.claude/worktrees/feat-x/src/a.ts`, matched `.claude/*`, and returned 0 with no ticket.

`require-migration-ticket.sh` used absolute `*/.claude/*` and `*/docs/*` arms on the raw path. That wrongly allowed the same linked-worktree paths.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Stop the AgDR-0141 main-root rewrite | Removes the bad strip source | Breaks ops-root and marker resolution for linked worktrees |
| Match exemptions to the file's own toplevel | Keeps AgDR-0141 and fixes the false allow | Needs a shared helper and careful absolute-arm rules |
| Blacklist `.claude/worktrees/` in the exemption case | Small patch | Misses out-of-tree linked worktrees and is path-fragile |

## Decision

Chosen: **match exemptions to the file's own toplevel**. AgDR-0141 must stay for ops-root and markers. The exemption question is about the tree that owns the file.

Shared helper: `_lib-ticket-path-exemptions.sh` (`ticket_path_is_meta_exempt`).

Rules:

1. Canonicalize the write target (resolve relative paths against CWD, follow directory links with `_resolve_real_path` / `pwd -P`). This keeps `/var` and `/private/var` prefixes aligned on macOS.
2. Resolve own top with `git -C <file dir> rev-parse --show-toplevel`. Do not rewrite to the main clone.
3. When the path strips against that top, match only relative forms (`.claude/*`, `docs/*`, `*/docs/*` for `projects/*/docs/`, `*.md`).
4. Apply absolute `*/.claude/*` and `*/docs/*` only when the path was not stripped. That keeps out-of-repo meta paths.
5. Keep main-root normalisation only for ops-root and marker resolution (AgDR-0141).

## Consequences

- Worktree source under `.claude/worktrees/<name>/` needs a ticket again.
- Relative and absolute spellings of the same worktree source both block.
- A worktree's own `.claude/` and `docs/` stay exempt.
- Ops `.claude/`, `projects/*/docs/`, and `*.md` stay exempt.
- Both ticket-first hooks share one helper, so they cannot drift.
- A path table of 17 rows asserts each expected exit code. Only the linked-worktree source row differs from the pre-fix gate. The test needs no git remote; the pre-fix comparison is recorded in the PR.
- If the helper library is missing, the gates do not path-exempt anything (fail closed).

## Known limits

From the code review (Rex) and security review (Hakim) of PR #1573. None blocks the fix.

- **Symlinks are judged by their target.** A `.claude/` or `docs/` path that is a symlink to source is gated, which closes a hole that was open before. A side effect: a script reached through a symlinked `.claude/skills/<name>/` directory (a split-portfolio custom skill) needs a ticket. Its `SKILL.md` stays exempt, and the same file by its real path already needed one.
- **A missing helper library blocks every path-exempt write.** If `_lib-ticket-path-exemptions.sh` is missing, the gates exempt nothing. This is the safe direction, but `/start-ticket` cannot write its marker either. To recover, restore the file from git in a shell outside the session (`git checkout -- .claude/hooks/_lib-ticket-path-exemptions.sh`). No normal adopter flow ships the gates without the helper: `/update` and the harness adapters copy the whole tree.
- **A missing `_lib-path-resolve.sh` uses a local resolver.** It resolves the deepest existing directory and keeps the components below it, including ones that do not exist yet. It does not resolve a symlink in the final component.
- **Git environment variables.** `GIT_DIR`, `GIT_WORK_TREE` and `GIT_CEILING_DIRECTORIES` in the hook's environment change what `git rev-parse --show-toplevel` reports. Only the operator can set them for the hook process.
- **Cost.** The helper adds about 15–20 ms per write target (one `git rev-parse` and one path resolution).

## Architecture evolution

### Before

AgDR-0141 rewrote `REPO_ROOT` for linked worktrees. Exemption logic reused that root. Relative strip turned worktree source into a `.claude/...` path and skipped the ticket gate. The migration gate's absolute `*/.claude/*` arm did the same on the unstripped path.

### After

Ops-root and markers still use the AgDR-0141 main-root rewrite. Path exemptions use the file's own worktree top through `_lib-ticket-path-exemptions.sh`. Absolute meta arms apply only when strip did not run. Relative write targets resolve against CWD before the own-top strip so they cannot keep a `.claude/worktrees/...` prefix.

## Artifacts

- Issue: https://github.com/me2resh/apexyard/issues/1531
- Related: [AgDR-0141](AgDR-0141-normalize-linked-worktree-ops-root.md)
- Helper: `.claude/hooks/_lib-ticket-path-exemptions.sh`
- Hooks: `require-active-ticket.sh`, `require-migration-ticket.sh`
- Tests: `.claude/hooks/tests/test_require_active_ticket_worktree_exemptions.sh`
