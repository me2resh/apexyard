# Dispatcher-level fail-closed rule for merge gates

> In the context of Bash PreToolUse dispatch (AgDR-0157), facing a merge gate that exits non-zero for a reason other than BLOCKED, I decided to make `dispatch-bash.sh` treat any such exit as a block. This closes a fail-open path when a merge gate cannot run its own check. A merge gate that later adds a new failure mode inherits this rule for free.

## Status

Accepted

## Context

Issue me2resh/apexyard#1403 reported that the four merge-gate hooks
(`block-unreviewed-merge.sh`, `require-design-review-for-ui.sh`,
`block-merge-on-red-ci.sh`, `require-architecture-review.sh`) fail open
in POSIX mode.

Each hook sources `_lib-extract-pr.sh` with a bare `.` command and no
`[ -f ... ]` guard. In POSIX mode (`POSIXLY_CORRECT=1` or `bash --posix`),
sourcing a missing file is a fatal error for the special builtin `.`. The
shell exits 1 immediately. The hook's own gate logic never runs.

`dispatch-bash.sh`'s `run_hook` only blocks the tool call on exit 2. Any
other non-zero exit prints a WARN and lets the remaining gates run. A
merge gate that dies with exit 1 before it decides PASS or BLOCK is
treated the same as an unrelated advisory hook failing for an unrelated
reason. The merge proceeds unreviewed.

A normal Claude Code session does not set `POSIXLY_CORRECT`. Other
harnesses and CI shells may. The security review of issue #1390's fix
(PR #1397, the design gate's own fix) found this exposure in
`require-design-review-for-ui.sh` first. The same unguarded source line
sits at the top of the other three merge gates on `dev`.

This is a trust-chain control. Parent record: AgDR-0157.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Guard each `.` with `[ -f "<lib>" ]` and exit 2 inside every merge-gate hook | Fixes the exact reported line | Four files to touch and keep in sync. `require-design-review-for-ui.sh` has an open PR (#1397) touching it. Misses any OTHER unguarded source line in the same hooks, present now or added later |
| Make `dispatch-bash.sh` treat any non-zero, non-2 exit from a merge-gate hook as a block | One change point. Covers the reported line and every future failure mode in the same four hooks, without editing them | Loses hook-specific detail in the block message (the dispatcher only knows the exit code, not why) |
| Wrap each merge-gate hook's own `set -e` around the whole script | Turns any internal error into a shell exit, which `run_hook` still treats as advisory unless the hook maps it to exit 2 itself | Does not change `run_hook`'s advisory treatment of a non-2 exit. Same fail-open gap, one layer down |

## Decision

Chosen: **make `dispatch-bash.sh` fail closed for the four merge gates**,
because the dispatcher already runs each one through a captured exit
code, and the fix at that single point closes the reported line and
every other way a merge gate can die before reaching its own BLOCK/PASS
decision.

A new `run_merge_gate_hook` wrapper runs the hook, exits 2 immediately on
a real exit 2 (unchanged), and now also prints a BLOCKED message and
exits 2 on any OTHER non-zero exit. `run_merge_gates` calls this wrapper
for the four merge gates instead of the advisory `run_hook`. Every other
hook keeps `run_hook`'s existing warn-and-continue behavior. Advisory
hooks are unaffected.

This closes the gap in `dispatch-bash.sh` without editing
`require-design-review-for-ui.sh`, `block-unreviewed-merge.sh`,
`block-merge-on-red-ci.sh`, or `require-architecture-review.sh`. It does
not fix the individual hooks' own unguarded source lines. A hook run
directly, outside the dispatcher, keeps the pre-existing exposure. The
dispatcher is the only place every merge attempt is proven to pass
through (both merge shapes, per AgDR-0157 and AgDR-0162), so it is the
right single point for this rule.

## Consequences

- A merge-gate hook that exits non-zero for ANY reason other than a
  deliberate exit 2 now blocks the merge, with a message naming the
  script and its exit code.
- The four merge gates are the only hooks under this rule. Adding a
  fifth merge gate later means adding it to `run_merge_gates`, which
  already gets the fail-closed behavior for free.
- `test_dispatch_bash.sh` covers each of the four merge gates failing
  under POSIX mode with a missing library, and confirms the block.
- A merge gate's own internal fix (e.g. guarding its `.` sources) stays
  independently valuable. Its exit code changes from an unplanned 1 to a
  planned, hook-specific 2. This dispatcher fix is the backstop for
  every hook that has not yet done that internal work, and for any new
  failure mode the internal work does not anticipate.

## Artifacts

- Issue: me2resh/apexyard#1403
- Parent: docs/agdr/AgDR-0157-bash-pretooluse-dispatcher.md
- Related: docs/agdr/AgDR-0162-dispatch-merge-gates-inside-wrappers.md
