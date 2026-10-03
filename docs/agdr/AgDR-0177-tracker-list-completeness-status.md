# Report tracker_list completeness through a status variable

> Context: skills list issues from a tracker. Concern: a short or failed read looks like a complete
> one. Decision: report a completeness status from `tracker_list`, and pass an explicit default
> limit. Goal: a caller can tell a complete read from a partial one. Trade-off: a new caller
> contract, and an explicit default limit on the `gh` and `glab` adapters.

## Context

`tracker_list` returns a JSON array. It prints `[]` and returns non-zero when the call fails. A caller that ignores the return code reads a failure as an empty set and reports zero items.

Two more short-read paths exist. When a caller passes no `limit`, each CLI applies its own default of 30. The GitLab adapter maps `limit` to `--per-page`, and GitLab caps a page at 100.

`/inbox` and `/tasks` both call `tracker_list` with a fixed limit and no completeness check.

This is the reusable half of the `/duty` proposal in #1360. The premise check on #1361 recommended extracting it.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Document the return code, change no code | No new contract | The failure path stays easy to ignore, and neither short-read path is addressed |
| Return a wrapper object `{items, status}` | One value carries both facts | Breaking change for every existing caller |
| Set a status variable beside the array | No change to the returned JSON. Callers opt in | A shell variable is a weaker contract than a return value, and a subshell does not propagate it |
| Paginate inside `tracker_list` | Callers need no completeness logic | Each adapter pages differently, and an unbounded internal loop hides cost from the caller |

## Decision

Chosen: **set `TRACKER_LIST_STATUS` beside the returned array, and ship `tracker_list_to` for a command substitution.** Together they add the missing fact. Neither changes the JSON that current callers parse.

`tracker_list_to <outfile> <repo> [filters]` writes the array to a file and echoes the verdict on stdout, so `status=$(tracker_list_to …)` returns it. Review found that the variable alone is not enough: the natural caller shape is `items=$(tracker_list …)`, and a subshell cannot pass a variable back. Both reviewers reproduced a failed read reporting `COMPLETE` through a stale value, which is the exact failure this change exists to remove.

- `tracker_fetch_status <rc> <count> <limit> [repo] [kind]` returns `COMPLETE`, `TRUNCATED`, or `UNKNOWN`. It is pure, so a caller can also use it on its own reads. A caller that already resolved the kind passes it, which saves a second registry read.
- `tracker_page_cap <repo>` reports the adapter's maximum page size. GitLab is 100, and every other adapter is 0, which means no cap.
- `tracker_list` sets `TRACKER_LIST_STATUS` on every exit path, and sets `UNKNOWN` before any work so an early return cannot leave a stale value.
- `tracker_list` passes an explicit limit, from `tracker.list_default_limit` (default 30), when the caller gives none. The `custom` adapter is excluded, because it passes the value through `TRACKER_LIMIT`, which was empty for a no-limit call. An operator's `list_command` may read empty as "no limit", so defaulting it would change the returned set.
- The status reads the count the server returned, before the client-side `since` filter, so a filtered-down array does not read as `COMPLETE`. Only a raw JSON array is counted. A custom adapter's other shapes report `UNKNOWN`, because `list_normalise_jq` may select rows, and counting its output would count the operator's selection rather than the server page.

The config read runs inside a subshell, because the load leaks out of the function otherwise. `_tracker_load_config_lib` sources `_lib-read-config.sh` into its caller's shell and short-circuits on `command -v config_get_or`. Sourcing it inside `tracker_list` leaves that definition in the caller's shell and in every subshell the caller later spawns. A later `tracker_issue_kind` then short-circuits its own load. It keeps reading through a config reader anchored to wherever the first load happened, so the tracker kind can resolve wrongly. Review measured this twice: `test_tracker_list.sh`'s two stderr-passthrough cases fail that way, with the dispatch reading `kind=gh` where the project configures `glab` or `custom`. The blast radius is the caller's shell and its later calls, not the rest of the current call. Two earlier versions of this record described the mechanism wrongly.

## Consequences

- A caller that reads `TRACKER_LIST_STATUS` inside a command substitution does not see it, because a subshell does not export back. Callers run `tracker_list` in the current shell, or call `tracker_list_to`. The skill guidance uses `tracker_list_to`, and a regression test covers the substitution shape.
- The `gh` and `glab` adapters now always receive a limit. The value matches each CLI's own previous default of 30, so the returned set does not change. The `custom` adapter is unchanged, and a custom call with no caller limit reports `UNKNOWN` rather than a verdict against a limit nobody chose.
- A caller that passes a non-numeric `limit` now gets the default instead of an adapter error. That caller bug is quieter than before.
- A caller that sees `TRUNCATED` raises the limit and reads again, then reports "at least N" if the second read is still truncated. `/inbox` and `/tasks` both show that retry. `/stakeholder-update` states the same rule in prose.
- `UNKNOWN` carries two meanings, separated by the exit status. A non-zero status is a failed read. A zero status is a successful read whose completeness the library cannot judge, which is what a custom adapter with no caller limit returns. Caller guidance must split on the status, or it reports a healthy read as a failure.
- A `glab` read that returns 100 items stays `TRUNCATED` at any requested limit. This was inferred from the adapter code and was not run against GitLab.
- `/inbox` and `/tasks` still need their own retry loop. This change gives them the signal, not the loop.

## Artifacts

- me2resh/apexyard#1441
- `.claude/hooks/_lib-tracker.sh`, `.claude/hooks/tests/test_tracker_fetch_status.sh`
