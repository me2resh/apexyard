# AgDR-0285: Report linked worktrees without changing state

## Context

Issue #1940 requires `/status` to show linked worktrees and their owners.
AgDR-0284 defines owner records and the public `worktree_owner_status` reader.
Operators also need evidence of local changes and commits before deciding what to preserve.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Read Git worktree metadata and existing markers | Reuses Git's inventory and the owner reader | Requires local filesystem and Git access |
| Add a separate registry | Supports additional lifecycle metadata | Adds state, synchronization, and recovery rules |
| Include forge queries in each report | Can identify merged PRs | Adds network access and forge dependencies |

## Decision

Add `.claude/skills/status/worktree-report.sh` as a report-only command.
Run it once per locally cloned project and once for the ops repo.
Keep briefing mode unchanged.
Print a header and one tab-separated row for each linked worktree.
Omit the main working tree.
Show Path, Branch, Owner, Work, and Ticket columns in the full report.

Use only `worktree_owner_status` from the owner library.
Preserve its `alive`, `dead`, `unknown`, `none`, and `released` values.
Use `unknown` when the library or `jq` is unavailable.
Read ticket fields with `active_ticket_read_field` from the worktree git dir's `apexyard-ticket` marker.
Paths containing a newline or tab skip every lookup, including checkout identity, owner, ticket, and work checks.
A trailing newline can collapse two paths into one during resolution.
Retain the sanitized path and branch with `owner=unknown`, `work=unknown:unprintable path`, and `ticket=-`.

Determine work state from local evidence:

| State | Source |
|-------|--------|
| `dirty` | Any output from `git status --porcelain --untracked-files=normal --ignore-submodules=all`, including an untracked `owner.json` |
| `unpushed` | Clean worktree with a positive `git rev-list --count HEAD --not --remotes` count |
| `preserved` | Clean worktree with a zero count, including branches without an upstream |
| `unknown:path unavailable` | Missing directory, prunable registration, or checkout identity mismatch |
| `unknown:filters configured` | Effective worktree configuration defines a clean or process filter |
| `unknown:partial clone` | `extensions.partialClone` is set or any `remote.*.promisor` value is true |
| `unknown:checkout unknown` | Failed status command or unreadable effective configuration |
| `unknown:commits unknown` | Failed revision count or a non-numeric result |
| `unknown:unprintable path` | A tab or newline in the path or branch |
| `unknown:metadata unavailable` | The fallback cannot read Git's administrative metadata |

Use `git worktree list --porcelain -z`, available in Git 2.36 and later.
If that command fails, attempt the older `--porcelain` format.
Legacy porcelain can contain literal newlines that resemble record fields.
Read exact linked paths from Git's existing administrative `gitdir` backpointers.
Confirm each recovered path occurs in the successful listing.
Read the administrative HEAD for its branch.
In both parser modes, match every checkout path against the registered `gitdir` backpointers, including prunable rows.
Resolve existing backpointer paths physically, following symlinks before resolving parent-directory components.
Use lexical normalization only when the backpointer path does not exist.
For printable paths, resolve the checkout's absolute git dir before reading owner, ticket, or work evidence.
Require that directory to identify the same filesystem object as its registered administrative directory.
Use `-ef` to compare the resolved directories.
Treat a failed identity check as an unavailable path.
Retain the listed path and branch, with `owner=unknown`, `work=unknown:path unavailable`, and `ticket=-`.
Replace tabs and newlines with `?` in displayed paths and branches.
Return 0 after a successful listing, including unknown rows.
Return 2 with a stderr reason when neither listing succeeds.
Produce no other stderr output.

Wrap every Git invocation, including owner-library calls, with `GIT_OPTIONAL_LOCKS=0`, `GIT_NO_LAZY_FETCH=1`, and `-c core.fsmonitor=false`.
Before inspecting work, read the worktree's effective configuration.
Skip status when any clean or process filter is configured.
Do not replace filter commands with empty overrides.
Run status with `--ignore-submodules=all` to avoid inspecting submodule repositories.
Submodule changes are not reported.
Older Git versions can ignore `GIT_NO_LAZY_FETCH`.
Skip status and revision counts for partial clones, regardless of Git version.
Never persist an index refresh, start FSMonitor, fetch refs, or create temporary files.
Never write, remove, renew, release, or lock owner state.
A `dead` or `none` owner with `dirty` or `unpushed` work requires a human decision.
The status section never removes, releases, or relaunches worktrees.

## Consequences

The report adds at most one status command and one revision-count command per printable, available worktree.
Dirty worktrees need no revision count.
Configuration checks, owner checks, and ticket git-dir resolution add metadata reads.
Both parsers read Git's administrative backpointers and resolve each printable, available checkout's git dir.
Local remote-tracking refs can be stale because the report does not fetch.
Rows describe successive observations, rather than an atomic snapshot across all worktrees.

A merged-PR column would require forge calls.
That column remains outside this report-only change.
A later cleanup PR can treat merged work as preserved after verifying the forge evidence.
This report makes no cleanup decision from branch names, lease expiry, or missing owner records.

## Artifacts

- Refs #1940
- `.claude/skills/status/worktree-report.sh`
- `.claude/skills/status/SKILL.md`
- `.claude/hooks/tests/test_status_worktree_report.sh`
