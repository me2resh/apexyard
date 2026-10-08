---
id: AgDR-0222
timestamp: 2026-10-08T14:20:34Z
agent: platform-engineer
model: claude-sonnet-5-5
session: session_01KGvb2ba4gyT3TN8L2uMLTn
trigger: user-prompt
status: executed
category: security
---

# Store the ticket marker in each working tree's git dir

> In the context of parallel sessions on one project, I faced last-writer-wins ticket files and a lookup that git environment variables can redirect. I decided to keep one marker file per working tree in that tree's git dir. I find the git dir by reading git's own files, with no git process. During the move, the old markers stay readable and are still written. A tree whose marker is not trusted gets the old resolution, never a new block.

## Context

Today the active ticket lives in shared files under the ops fork:
`.claude/session/tickets/<project>/<branch>`, `.claude/session/tickets/<project>`
and `.claude/session/current-ticket`.

Three problems follow from that layout.

- Parallel sessions on one project overwrite each other's ticket (me2resh/apexyard#513).
- The lookup runs `git -C` with no `GIT_*` scrub. `GIT_DIR` or a git config override can redirect it.
- A spike ticket in one project can exempt a write in another project.

The spike me2resh/apexyard#1535 showed that hooks and sandboxed Bash can write `<gitdir>/apexyard-ticket`. Each tree then sees only its own marker. `git worktree remove` deletes the marker.

The marker is a process gate. Anyone with write access to the git dir can forge it. It is not an authorization boundary.

## Options Considered

Git-dir discovery:

| Option | Pros | Cons |
|--------|------|------|
| Read git's own files with shell builtins (chosen) | No environment or config influence. 0 forks and 0 execs per lookup once the context is filled. | The code re-implements two git checks. |
| One scrubbed `git rev-parse` per lookup | Git does the discovery. | The scrub list needs upkeep. Earlier review rounds found three gaps in it. Each lookup adds one exec. |
| `git rev-parse` plus an allowed-set cache | Fewer git calls on a hit. | Measured +22 to +49 % per Edit. Review found three cache-signature defects. |

Old-layout markers:

| Option | Pros | Cons |
|--------|------|------|
| Ignore them everywhere | Simplest. | Every project blocks once after `/update`. |
| Honour them in a main clone only (first choice, D1, reversed) | Main clones keep working. A linked worktree never reads one. | Real sessions broke. See "Backward compatibility". |
| Honour them wherever the old hooks did, and keep writing them (chosen) | No session that passed before is blocked. A rollback keeps working. | The old resolution, and its git calls, stays in the trust chain until the breaking release. |
| Convert old markers once, at SessionStart, into new markers (rejected) | One layout after the first session. | It must guess the tree for `current-ticket` and for a project with no clone. A rollback then finds no old marker for a ticket started later. |

## Decision

Chosen: **a marker file `apexyard-ticket` in the git dir of each working tree, found by reading files**.

### Discovery and validation

The lookup walks up from the target to the first directory that holds `.git`. It reads that `.git` entry and, for a linked worktree, `commondir` and `gitdir`. It runs no git process.

The lookup accepts a git dir only when all of these hold:

- The common dir is the ops fork's `.git`, or the `.git` of a registered clone. A registered clone is a direct child of the workspace dir with its registry name, or the `workspace:` path of its registry entry. A relative `workspace:` path is relative to the ops root.
- A linked worktree git dir sits under `<common>/worktrees`, and both back-pointers agree.
- The git dir has `HEAD`, and the common dir has `objects` and `refs`.
- The current user owns the git dir and the common dir (`[ -O ]`).
- No symlink sits between the target and the tree root. A `..` that follows a symlinked component is refused, because it would hide the link.
- A `.git` file holds one `gitdir:` line. A main `.git` directory has no `commondir` file.
- The marker's `repo=` is bound to the tree. A project clone takes only a repo of its own registry entry: `repo:`, any `repos:` item or `primary:`, without regard to case. The ops fork takes no repo of a registered project. The writer refuses an unbound marker, and the lookup does not trust one. The check reads the registry with builtins only.

The workspace root, each workspace entry and its `.git` must be real directories. The same holds for a `workspace:` path and its `.git`. `$OPS_ROOT` itself may be an alias, but `$OPS_ROOT/.git` must not be a link. A common dir that matches more than one root is refused as ambiguous. Examples are the ops fork plus an entry, or two entries.

When a tree fails any of these checks, only its `apexyard-ticket` file stops being trusted. The lookup then runs the old resolution, as described in "Backward compatibility".

### Security properties

| Property | Mechanism |
|----------|-----------|
| `GIT_*` variables and git config cannot redirect the lookup of a marker in a validated tree's git dir | No git process runs for that lookup. The old resolution keeps its old git calls until the breaking release. |
| `core.worktree` cannot move the tree | The tree is the directory that holds `.git`. |
| Only the ops fork or a registered clone has a trusted new marker | The common dir is matched on every call. |
| A planted `.git`, `gitdir` or `commondir` is refused | The common dir must be registered, and the back-pointers must agree. |
| The `.git` write exemption covers only the marker | `active_ticket_is_marker_target` accepts the exact marker and its temporary file. The exemption refuses a hard-linked target. |
| The library's own functions and state cannot be planted by a parent process | Functions are redefined on every source. The one-time state reset is guarded by the process id in an array element. The context names are internal and unexported. |
| A marker cannot carry one project's ticket into another tree | The writer and the lookup check that `repo=` is bound to the tree. |
| A failed check never trusts the new marker | Every failure discards the tree's `apexyard-ticket`. The old resolution then decides, as it did before the move. |

### Gap against git

The lookup checks that `HEAD` exists. It does not check that `HEAD` is a valid ref or object id, as git's `is_git_directory` does. The common dir must also be registered and owned by the user, and no git config is read or run. A repo that git accepts and this lookup refuses fails closed.

### Decisions inside this AgDR

- The ownership check replaces git's `safe.directory`. It is stricter, because the library never reads the git config override. A devcontainer or bind mount with another owner is blocked.
- D6 changed: the old resolution and the old-layout writer are removed only in an explicit breaking release. That release notes the change in the CHANGELOG upgrade notes. It is not the next release by default.
- Until then, the old resolution gives every pass that the old hooks gave, including a stale old file that passes a different ticket. A new marker in a validated tree overrides it.
- The sandbox allowlist may name only the exact marker and temporary file paths, never `.git/**`.
- Blocking a `cd <tree> && write` command is out of scope. A follow-up task tracks it (follow-up: to be filed).
- Submodules and nested repos are not trees for the new marker. Writes inside them use the old resolution, as before.
- An attacker who controls the hook process environment is out of scope. On bash 5.3 such an attacker can shadow `[`, `declare`, `builtin` or `git` with an inherited `BASH_FUNC_<name>%%` function. This applies to every hook. A possible hardening is to launch hooks as `bash -p <script>`.

This AgDR partly supersedes AgDR-0066 and AgDR-0141, and amends AgDR-0168 and AgDR-0017. It replaces the mechanism that the ticket names (`rev-parse`, `worktree list`, the `GIT_*` unset) with one that reaches the same outcome.

## Consequences

- Each working tree can have its own ticket. Removing a worktree removes its new marker.
- The fixes of this AgDR apply only in a tree with a trusted new marker. They are no last-writer-wins collision between parallel sessions, no `GIT_*` redirect of the lookup, and no cross-project wrong-ticket pass. A tree without one behaves as it did before the move.
- No target that passed the old hooks is blocked by the new ones. Every session keeps its ticket through `/update` and through a rollback. A marker path whose link count exceeds 1 or cannot be read is blocked even with an active ticket, without falling through to ticket lookup.
- Unregistered repos, submodules, nested repos, symlinked roots and repos owned by another user get no trusted new marker. They use the old resolution.
- Once the context is filled, a lookup that finds a new marker makes 0 forks. Without one, the old resolution keeps its old cost, including its git calls. The first lookup in a workspace clone may resolve the registry path once per process, and that step can fork. A test fails when a lookup function gains a command substitution, a pipe, a subshell or an external command.
- A hook-level test fails when a gated write makes more processes than before.

## Backward compatibility

On 2026-10-08 Nagy, the issue author, reversed D1 and chose full backward compatibility. The upstream maintainer confirmed this decision on 2026-10-08 on me2resh/apexyard#1576. A tree with a trusted new marker is strict; a tree without one falls back to the `dev` resolution. The old fallback is removed in v6.0.0, as an explicit breaking change with an upgrade note.

The first build replaced the old lookup instead of extending it, and real sessions broke. Linked worktrees, unregistered repos, nested repos and forks without the portfolio library lost their ticket.

The breakage had two kinds of cause.

- **A fixable defect.** The first build ignored a registry entry's `workspace:` path, so every clone outside the workspace dir was refused. This AgDR fixes it: such a clone is now a registered clone (see "Discovery and validation").
- **Costs that any move has.** After `/update`, sessions that still run the old hooks, or follow the old `/start-ticket` text, see only the old layout. A rollback sees only the old layout too. Dual read and dual write below carry these costs for the transition.

### Amended acceptance criteria

The decision amends four acceptance-criteria rows of me2resh/apexyard#1576. The issue author posted the amended rows on the issue. The upstream maintainer confirmed them on 2026-10-08. QA verifies against the amended rows.

| Original row | Amended row |
|---|---|
| Inside a linked worktree, no old-layout fallback is allowed. | A linked worktree with no new marker falls back to the old markers, as on `dev`. A new marker in the tree always wins. |
| An old-layout marker never gives a cross-project or cross-tree wrong-ticket pass. | A tree with a trusted new marker never gives a cross-project or cross-tree wrong-ticket pass. A tree without one can pass through the shared `current-ticket`, as on `dev`. |
| A Bash write whose target the gate cannot extract requires the marker in the git dir of the hook process's working directory. | Such a write passes with the marker in the git dir of the hook process's working directory, or with `current-ticket`, as on `dev`. |
| No file reads `session/tickets` or `current-ticket` outside the resolver. | The same rule, except that `status/briefing.sh` keeps `dev`'s display reader. It is on the grep test's allowlist. |

### Dual read

The lookup reads two layouts.

1. A regular `apexyard-ticket` in the git dir of a validated tree decides, when its `repo=` is bound to the tree. All the guarantees above hold for it.
2. Otherwise the lookup runs the old resolution, ported unchanged into `_lib-active-ticket.sh` (the `_atd_*` functions). It reads `tickets/<project>/<branch>` for a linked worktree, then `tickets/<project>`, then `current-ticket`. An empty target reads `current-ticket` only. A target that cannot be resolved, such as `~user/x`, reads no marker.

The invariant is that the gate passes whenever the old hooks passed, and blocks whenever they blocked. The one exception is a new marker in a validated tree, which decides. A failed validation is never a block on its own. The main-clone-only rule, the managed-project refusal for `current-ticket` and the repo-match refusal are removed, because the old hooks did not have them. The SessionStart notice and the legacy line of the block message only inform about the move. The notice lists only old files that no trusted new marker for the same tree shadows.

### Dual write

`/start-ticket` writes the new marker and the old-layout marker, in the place the old skill used. When the tree fails validation, it writes only the old marker, with a one-line note. `/fan-out` does the same for each writer worktree. A hook from before the move therefore sees every ticket that the new skill starts. This covers a rollback and a session that still runs the old hooks during `/update`.

Two cases are not covered. In both, a stale `<git dir>/apexyard-ticket` outranks a newer old-layout file.

1. After a rollback and a second `/update`, the marker from before the rollback is still there. The old hooks did not update it.
2. A session that follows the old `/start-ticket` text, for example one that has not reloaded its skills after `/update`, writes only the old marker. An older new marker in the same tree still decides.

The fix for both is to run `/start-ticket` again in each tree, or to delete the stale marker. The repo-binding check covers only part of this. It drops a stale marker of another project, so the old resolution decides there. It cannot tell a stale ticket of the same project from a current one. A follow-up task tracks a staleness check (follow-up: to be filed).

### Removal

The old resolution and the old-layout writer go away only in an explicit breaking release (D6). That release states it in the CHANGELOG upgrade notes. A follow-up task tracks the release (follow-up: to be filed).

The removal release can start when all of these conditions are true:

- At least one release after this one has shipped the dual read and the dual write.
- The upstream maintainer agrees to drop rollback support across the move.
- The removal task has a decision for each shape in the risk table below.

Removal brings back the break of the first build for every shape that cannot validate. The removal task must decide, for each shape, between a supported new-marker path and an explicit, documented block.

| Shape | Risk after removal |
|---|---|
| Unregistered repo outside the ops fork | It has no trusted new marker, so every gated write blocks. |
| Nested repo or submodule | It is not a tree for the new marker, so writes inside it block. |
| Symlinked root | Validation refuses the tree, so its writes block. |
| Repo owned by another user, such as a devcontainer or a bind mount | The ownership check refuses the tree, so its writes block. |
| Fork without the portfolio library | The registry path is unknown, so a workspace lookup fails closed. |
| Linked worktree with only an old per-branch marker | The tree loses its ticket until `/start-ticket` runs again in it. |
| Bash write whose target the gate cannot extract | `current-ticket` no longer counts, so the write needs a marker in the hook cwd's tree. |
| Session that follows the old `/start-ticket` text | It writes only the old marker, and no hook reads that marker. |

The removal release deletes these items:

- The `_atd_*` functions in `_lib-active-ticket.sh`, and the fallback call to them in `_at_lookup_inner`.
- `active_ticket_legacy_path`, `active_ticket_legacy_markers`, `active_ticket_legacy_fallback` and `active_ticket_write_legacy`.
- The old-layout part of `active_ticket_project_markers`.
- The old-layout write in `active_ticket_write_from_file`, in `prepare-worktree.sh` and in the `/start-ticket` and `/fan-out` skill text.
- The inline old-marker loop in `block-ambient-tracker-repo.sh`.
- The `status/briefing.sh` display reader and its entry on the allowlist of `test_ticket_marker_readers.sh`.
- `warn-legacy-ticket-markers.sh`. The release can change it into a notice that the old files can be deleted.
- `test_dev_compat_rows.sh`, and the old-layout cases of `test_legacy_ticket_markers.sh`.
- The four amended acceptance-criteria rows. The original rows apply again.

Two other follow-up tasks relate to the transition (follow-up: to be filed):

- Block a `cd <tree> && write` command (see "Decisions inside this AgDR").
- Check for a stale new marker (see "Dual write").

### Places where the new hooks differ from the old ones

- A write to `.git/apexyard-ticket` or its temporary file passes with no ticket. The old hooks blocked it. `/start-ticket` needs that write. The exemption refuses a hard-linked target.
- The spike exemption reads the marker that governs the tree, not any marker in the session dir. This is the cross-project spike-leak fix. An old `current-ticket` still exempts a project that has no marker of its own, as in the ticket gate.
- The ambient tracker guard reads every old marker, as before, and the new markers on top. It can block more than before, never less.
- `active_ticket_init` falls back to `resolve_ops_root "$PWD"` when the start directory has no ops root. The old spike exemption did not.
- The old resolution normalised a path with a newline in it line by line, through awk. The port normalises the whole string.
- `prepare-worktree.sh` keeps an existing session-level `current-ticket` and does not overwrite it.
- The `/status` briefing shows a new marker first. Without one, it shows what the old briefing showed.

### Proof

The one-time proof ran the unchanged test files of the `dev` merge base b312ca8 against the new hooks. The results are in the PR body. The frozen copies of those tests are not part of the suite, because `dev` keeps changing the behaviour that they pin.

- The only expected difference was the dispatcher test, which pins the list of SessionStart hooks.
- `test_dev_compat_rows.sh` stays in the suite. It runs one row per broken session shape, B1 to B9, against the current hooks. Each row has the fixed verdict that the old hooks gave for the same shape.
- Rows P1 and P2 show that a ticket written into the wrong tree does not pass.
- Rows B8 and B9 check the old-layout marker that the new `/start-ticket` writes. Its path and format are the ones that the old hooks read.

## Build notes

- The registry path and the workspace dir come from the portfolio library, and only when that library is loaded in the same process. An inherited `_PP_REG` or `_PP_WS` is never used. Without a trusted resolver the registry path stays unknown, and a workspace lookup fails closed.
- The registry is resolved on demand. A workspace clone or an old `current-ticket` file needs it. A Claude session reads the path from the session cache without a fork.
- The hook-level process count test needs `strace`. It fails on a Linux CI runner without it. Elsewhere it prints an `INFO:` line, because the suite runner treats a line that starts with `SKIP` as a failure. The limits are the counts of the `dev` merge base, measured on a developer machine. Confirm them on the CI ubuntu leg, and re-measure them after each merge of `dev`.
- `/fan-out` creates writer worktrees under `<ops>/.claude/worktrees/`. Since AgDR-0219 the ticket gates no longer exempt source writes there, so each writer needs its ticket. `prepare-worktree.sh` writes both markers for it.
- The process budget test scans the new-marker lookup for forks. The `_atd_*` functions keep the old cost and are not scanned. A test shows that a lookup that finds a new marker never runs them. Case 4b counts two targets that only an old marker covers.
- The repo-binding check needs the registry. A project clone without a readable registry binds nothing. For the ops fork, an unknown registry path falls back to `<ops>/apexyard.projects.yaml`, the single-fork default. When that file does not exist, no project is known and the ops marker counts.
- Every new test sources `_test-session-isolation.sh`. The compat rows model a real session with their own session id and pin file, because the isolation clears the inherited ones.
- The ambient tracker guard reads the marker of the tree that runs the command. From the ops fork it also reads the markers of registered workspace clones and their linked worktrees. The reason is that `/start-ticket` run at the ops root writes into the project clone.
- A tree that fails validation, such as a scratch clone outside the ops fork, has no marker of its own. When the session pin still resolves the ops root, the guard reads the ops fork's marker and every project marker. This keeps the old block for such a clone.

## Artifacts

- `.claude/hooks/_lib-active-ticket.sh`
- `.claude/hooks/_lib-portfolio-paths.sh` (`portfolio_resolve_into_vars`)
- `.claude/hooks/tests/test_active_ticket_resolver.sh`
- `.claude/hooks/tests/test_active_ticket_process_budget.sh`
- `.claude/hooks/tests/test_agdr_marker_supersession.sh`
- `.claude/hooks/tests/test_legacy_ticket_markers.sh`
- `.claude/hooks/tests/test_dev_compat_rows.sh`
- `.claude/hooks/tests/test_start_ticket_step5.sh`
- `.claude/hooks/tests/test_fan_out_marker.sh`
- `.claude/hooks/block-ambient-tracker-repo.sh` and `.claude/hooks/tests/test_block_ambient_tracker_repo.sh`
- `.claude/hooks/warn-legacy-ticket-markers.sh`
- `.claude/skills/start-ticket/SKILL.md`
- `.claude/skills/fan-out/prepare-worktree.sh`
- me2resh/apexyard#1576
