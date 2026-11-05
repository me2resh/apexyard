# AgDR-0285: Report linked worktrees without changing state

## Decision

For #1940, add `.claude/skills/status/worktree-report.sh` to the full `/status` report.
Run it once per local project and once for the ops repository. Keep briefing mode unchanged.
Print a header and one tab-separated row per linked worktree, excluding the main working tree.
The columns are Path, Branch, Owner, Work, and Ticket.

## Design

Read owners only through AgDR-0284's `worktree_owner_status` API.
Preserve `alive`, `dead`, `unknown`, `none`, and `released`. Missing `jq` or owner library produces `unknown`.
Read validated ticket fields through `active_ticket_read_field` from the checkout's git-dir `apexyard-ticket` marker.

Paths containing tabs or newlines skip checkout identity, owner, ticket, and work lookups.
Command substitution can strip trailing newlines during checkout and ticket resolution, even though the owner library rejects these paths.
Replace displayed tabs and newlines with `?`. These paths report unknown owner, `unknown:unprintable path`, and ticket `-`.

| Work state | Local evidence |
|------------|----------------|
| `dirty` | Nonempty porcelain status, including untracked `owner.json` |
| `unpushed` | Clean checkout with a positive `rev-list --count HEAD --not --remotes` count |
| `preserved` | Clean checkout with a zero count, including branches without an upstream |
| `unknown:path unavailable` | Missing directory, prunable registration, or checkout identity mismatch |
| `unknown:filters configured` | Effective configuration defines a clean or process filter |
| `unknown:partial clone` | `extensions.partialClone` exists or any `remote.*.promisor` value is true |
| `unknown:split index` | `core.splitIndex` is true or a Git directory contains `sharedindex.*` |
| `unknown:checkout unknown` | Status fails or effective configuration cannot be read |
| `unknown:commits unknown` | Revision count fails or returns nonnumeric text |
| `unknown:unprintable path` | Path or branch contains a tab or newline |
| `unknown:metadata unavailable` | Legacy inventory cannot read administrative metadata |

Use NUL-delimited porcelain, available since Git 2.36. If it fails, try legacy porcelain.
Legacy paths can contain forged record fields. Recover exact paths from administrative `gitdir` backpointers and confirm their listing membership.

Read legacy branch names from administrative HEAD files.
Both parsers match paths against registered backpointers, including prunable rows.
Use absolute backpointers as stored, because Git prints them as stored.
Resolve relative backpointers against the administrative directory.
Follow symlinks in an existing relative target. Normalize a missing relative target lexically.

The metadata-unavailable row prints `-` in the Branch column.

For printable paths, require the checkout's absolute git dir to match its registered administrative directory through `-ef`.
Failed identity checks retain the listed path and branch, with unknown owner, unavailable work, and ticket `-`.
Successful listings return 0 with no stderr, including unknown rows. Complete listing failure returns 2 with a stderr reason.

Every Git call, including library calls, disables optional locks, lazy fetching, and FSMonitor.
Inspect effective configuration before content. Skip status and revision counts for configured filters and partial clones.
Do not override filter commands. Older Git can ignore `GIT_NO_LAZY_FETCH`, so partial clones always require this guard.

Also skip status and revision counts when `core.splitIndex` is true or shared-index files exist.
Read directory entries under the checkout's absolute Git directory and common directory, resolved through `rev-parse`.
These path queries do not read the index. Never use `--shared-index-path`, which updates shared-index modification times.
Stale shared-index files can conservatively leave work unknown.

Status uses `--porcelain --untracked-files=normal --ignore-submodules=all`.
Never persist index refreshes, start FSMonitor, fetch refs, create temporary files, or mutate or lock owner state.

## Alternatives

A separate registry adds synchronization and recovery state. Existing Git metadata and owner records already supply the required evidence.
Forge queries could identify merged PRs, but add network access and dependencies. Defer that evidence to a later cleanup change.

## Residual risks

Each printable, available checkout needs metadata reads, at most one status call, and one revision count only when clean.
Local remote-tracking refs can be stale. Rows are successive observations, rather than an atomic snapshot.

Submodule changes are omitted. Filters, partial clones, split indexes, missing tools, and unreadable metadata can leave evidence unknown.
Dead or absent owners with dirty or unpushed work require a human decision.
Branch names, lease expiry, and missing owner records never authorize cleanup. This report never removes, releases, or relaunches worktrees.
Modern mode omits registrations whose `gitdir` file is empty or unreadable because Git drops them from its listing.
