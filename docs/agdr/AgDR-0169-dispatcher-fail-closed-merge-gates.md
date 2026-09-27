# Dispatcher-level fail-closed rule for merge gates

> In the context of Bash PreToolUse dispatch (AgDR-0157), facing a merge
> gate that exits non-zero for a reason other than BLOCKED, I decided to
> make `dispatch-bash.sh` treat any such exit as a block. This closes a
> fail-open path when a merge gate cannot run its own check. A merge
> gate that later adds a new failure mode inherits this rule for free.

## Status

Accepted

## Context

Issue me2resh/apexyard#1403 reported that the four merge-gate hooks
(`block-unreviewed-merge.sh`, `require-design-review-for-ui.sh`,
`block-merge-on-red-ci.sh`, `require-architecture-review.sh`) fail open
in POSIX mode.

Each hook sources `_lib-extract-pr.sh` with a bare `.` command and no
`[ -f ... ]` guard. Under `POSIXLY_CORRECT=1`, sourcing a missing file
is a fatal error for the special builtin `.`. The shell exits 1
immediately. The hook's own gate logic never runs.

`dispatch-bash.sh`'s `run_hook` only blocks the tool call on exit 2. Any
other non-zero exit prints a WARN and lets the remaining gates run. A
merge gate that dies with exit 1 before it decides PASS or BLOCK gets
treated the same as an unrelated advisory hook. The merge proceeds
unreviewed.

A normal Claude Code session does not set `POSIXLY_CORRECT`. Other
harnesses and CI shells may. The security review of issue #1390's fix
(PR #1397, the design gate's own fix) found this exposure in
`require-design-review-for-ui.sh` first. The same unguarded source line
sits at the top of the other three merge gates on `dev`.

This is a trust-chain control. Parent record: AgDR-0157.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Guard each `.` with `[ -f "<lib>" ]` and exit 2 inside every merge-gate hook | Fixes the exact reported line | Four files to touch and keep in sync. `require-design-review-for-ui.sh` has an open PR (#1397) touching it. Misses any other unguarded source line in the same hooks, present now or added later |
| Make `dispatch-bash.sh` treat any non-zero, non-2 exit from a merge-gate hook as a block | One change point. Covers the reported line and every future failure mode in the same four hooks, without editing them | Loses hook-specific detail in the block message. The dispatcher only knows the exit code, not why |
| Wrap each merge-gate hook's own `set -e` around the whole script | Turns any internal error into a shell exit | Does not change `run_hook`'s advisory treatment of a non-2 exit. Same fail-open gap, one layer down |

## Decision

Chosen: make `dispatch-bash.sh` fail closed for the four merge gates.
The dispatcher already runs each one through a captured exit code. One
change at that point closes the reported line. It also closes every
other way a merge gate can die with a visible non-zero, non-2 exit.

A new `run_merge_gate_hook` wrapper runs the hook. It exits 2 on a real
exit 2, unchanged. It now also prints a BLOCKED message and exits 2 on
any other non-zero exit. `run_merge_gates` calls this wrapper for the
four merge gates instead of the advisory `run_hook`. Every other hook
keeps `run_hook`'s existing warn-and-continue behavior. Advisory hooks
are unaffected.

This closes the gap in `dispatch-bash.sh`. It does not edit
`require-design-review-for-ui.sh`, `block-unreviewed-merge.sh`,
`block-merge-on-red-ci.sh`, or `require-architecture-review.sh`. It does
not fix the individual hooks' own unguarded source lines. A hook run
directly, outside the dispatcher, keeps the pre-existing exposure. The
dispatcher is the only place every merge attempt is proven to pass
through, per AgDR-0157 and AgDR-0162. It is the right single point for
this rule.

## Consequences

- A merge-gate hook that exits non-zero for any reason other than a
  deliberate exit 2 now blocks the merge. The block message names the
  script and its exit code.
- The four merge gates are the only hooks under this rule. Adding a
  fifth merge gate later means adding it to `run_merge_gates`. That
  gate gets the fail-closed behavior for free.
- `test_dispatch_bash.sh` covers each of the four merge gates dying
  under four distinct failure modes. It confirms the dispatcher blocks
  each one. See "Test coverage" below for the exact modes and shell
  settings.
- A merge gate's own internal fix stays independently valuable. One
  example is guarding its own `.` sources. Its exit code changes from
  an unplanned 1 to a planned, hook-specific 2. This dispatcher fix is
  the backstop for every hook that has not done that internal work yet.
  It is also the backstop for any new failure mode that internal work
  does not anticipate.

## Addendum — the dispatcher fix alone did not close the default-bash case (me2resh/apexyard#1405 second review, Hakim H2)

The Decision above claims the dispatcher fix closes every other way a
merge gate can die. That claim is too broad. Hakim's second review
found one failure mode the dispatcher structurally cannot see: a
missing `_lib-extract-pr.sh` in default, non-POSIX bash.

In default bash, a missing-file source returns 1. It does not end the
script. Each gate's next line is `if ! is_merge_command "$COMMAND";
then exit 0; fi`. The missing library leaves `is_merge_command`
undefined. Calling it prints "command not found" and returns 127. The
negated check reads that as "not a merge command." The gate then calls
`exit 0` on purpose, by its own normal logic. This is not a crash. It
is the gate's ordinary "nothing to do here" path, reached for the wrong
reason. `run_merge_gate_hook` reclassifies a non-zero, non-2 exit as
BLOCKED. An exit 0 gives it nothing to reclassify. The signal is
identical to a legitimate pass.

**Fix:** each of the four merge gates now guards its own required
library sources with a shared `_require_lib` function. The guard
checks readability with `[ -r ]` before it calls `.`. It prints a
BLOCKED message and exits 2 when a required library is missing or
fails to load. The readability check runs first. The guard never calls
`.` on a path it has not confirmed is readable.

That check order matters under `POSIXLY_CORRECT=1` too. A missing-file
source failure ends a non-interactive POSIX-mode shell immediately.
This happens even inside an `if` or `||` guard placed around the
failing `.` call itself. See "Test coverage" below for the empirical
confirmation. Checking readability first avoids that fatal case in
both shell modes, because the guard never reaches the `.` call at all.

## Addendum 2 — the exact library each gate guards, and #1403's two follow-up comment items (Adel, me2resh/apexyard#1403 split from #1405)

The first addendum said each gate guards `_lib-review-markers.sh`. That
statement was wrong for one gate. This addendum states the exact set,
gate by gate. It also closes two gaps a later review round found in
the first round's fix.

| Gate | Required, hard-guarded | Required, restructured guard | Optional, unchanged |
|------|------------------------|-------------------------------|----------------------|
| `block-unreviewed-merge.sh` | `_lib-extract-pr.sh`, `_lib-review-markers.sh` | — | `_lib-pr-repo.sh` (`if [ -f ]`), `_lib-read-config.sh` (readability-checked, see below) |
| `block-merge-on-red-ci.sh` | `_lib-extract-pr.sh` | — | `_lib-pr-repo.sh` (`if [ -f ]`) |
| `require-design-review-for-ui.sh` | `_lib-extract-pr.sh`, `_lib-review-markers.sh`, `_lib-pr-repo.sh` | `_lib-ui-paths.sh` | — |
| `require-architecture-review.sh` | `_lib-extract-pr.sh`, `_lib-review-markers.sh`, `_lib-pr-repo.sh` | — | — |

`block-merge-on-red-ci.sh` decides on CI status, not on approval
markers. It never sources `_lib-review-markers.sh`. This corrects the
first addendum.

**Follow-up 1 — `_lib-pr-repo.sh` was unguarded in two gates.** Hakim's
review of #1405 found that `require-architecture-review.sh` and
`require-design-review-for-ui.sh` source `_lib-pr-repo.sh` with a bare
`.`. Neither file guarded it at all. A missing file there silently
continues in default bash. It loses the cd-target repo recovery from
issues #687 and #1151. In POSIX mode it dies the same way the original
report described for `_lib-extract-pr.sh`. Both gates already treat
`_lib-pr-repo.sh` as required. This differs from the other two gates,
which treat it as optional behind an `if [ -f ]` check. The fix keeps
that required semantic. It applies the same `_require_lib` guard used
for the other two libraries in both files.

**Follow-up 2 — `_lib-ui-paths.sh`'s existing guard was not
POSIX-safe.** `require-design-review-for-ui.sh` already had a
fail-closed guard for `_lib-ui-paths.sh` from #1397:

```
if ! . "$HOOK_DIR/_lib-ui-paths.sh" 2>/dev/null \
   || ! command -v ui_effective_globs >/dev/null 2>&1; then
  echo "BLOCKED: ..." >&2
  exit 2
fi
```

That guard closed the default-bash case. It did not close the POSIX
case. The fatal source failure happens mid-evaluation of the `if`
condition. Bash never reaches the BLOCKED branch inside it. The whole
script still died with a raw, uninformative exit 1. The fix adds a
`[ ! -r "$HOOK_DIR/_lib-ui-paths.sh" ]` check as the first term of the
same `||` chain. `||` short-circuits. A missing file never reaches the
`.` call. The BLOCKED branch now runs in both shell modes.

**`_lib-read-config.sh` stays optional, by design, in
`block-unreviewed-merge.sh`.** This library backs two independent
reads. The `human_approver_title` read is a display-only convenience
with a "CEO" default. It correctly falls through when the library is
absent. The `require_posted_review` read already had its own explicit
BLOCKED branch, present before this PR, for when `config_get_or` is
undefined. That branch does not assume the check is off just because
it cannot read the setting. Neither read needed a `_require_lib`-style
hard block. Both needed the same readability check the other guards
use. A missing file never reaches the `.` call, so the script survives
in POSIX mode and reaches that pre-existing BLOCKED branch.

**Status of Hakim's four flagged POSIX-only cases.** Hakim's review
matrix named four cases that exited 1 under `POSIXLY_CORRECT=1`. Each
one was caught only by the dispatcher wrapper, not by the gate itself:

- `block-unreviewed-merge.sh` without `_lib-read-config.sh`
- `require-architecture-review.sh` without `_lib-pr-repo.sh`
- `require-design-review-for-ui.sh` without `_lib-pr-repo.sh`
- `require-design-review-for-ui.sh` without `_lib-ui-paths.sh`

After the two follow-ups above, all four now block by themselves. Each
one prints a clean BLOCKED message. This holds in both default and
POSIX-mode bash. The dispatcher wrapper stays in place. It remains the
backstop for a failure mode a per-hook guard has not anticipated yet.

**Two comment items on #1403 remain deferred, not addressed here.**

- A static check that fails when a POSIX-sourced library contains
  `< <(`. The issue's comments raised this because a later bash version
  may allow process substitution in POSIX mode on Linux CI.
- A pre-existing dash gap at `_lib-read-config.sh` line 35
  (`${BASH_SOURCE[0]:-}`).

Neither item is fixed in this change. Both stay tracked as follow-up
work on #1403. Neither is silently dropped.

## Test coverage

`test_dispatch_bash.sh` reproduces four ways a merge-gate hook can die
with a visible non-zero, non-2 exit. It confirms the dispatcher blocks
each one at the merge-gate boundary:

- exit 1
- exit 127 (an undefined command inside the hook)
- a bash syntax error (bash itself reports exit 2 for this one)
- a process killed by `SIGTERM`

It also reproduces the original report. Each of the four merge gates,
stubbed to source a missing library, blocked under
`POSIXLY_CORRECT=1`.

Each of the four hooks' own test files additionally removes each
required library the hook sources, one at a time. Each removal expects
a BLOCKED exit 2. Every one of these per-hook cases runs twice: once
with no shell mode override, and once with `POSIXLY_CORRECT=1` set on
the invocation.

Neither this AgDR nor the test files invoke `bash --posix` directly.
Both settings put bash in the same POSIX mode. This is a difference in
how the tests state the setting, not in what mode bash runs under.

## Artifacts

- Issue: me2resh/apexyard#1403
- Parent: docs/agdr/AgDR-0157-bash-pretooluse-dispatcher.md
- Related: docs/agdr/AgDR-0162-dispatch-merge-gates-inside-wrappers.md
- Round 2 review: me2resh/apexyard#1405 (Hakim H2)

### This record's scope

me2resh/apexyard#1405 batched this fix with a second, unrelated fix for
issue #1366 (`pre-push-gate.sh` running checks against the wrong repo).
The maintainer split the batch. Only the #1403 fix documented here
shipped in this PR.

The #1366 fix tried to recover a push target from command text. It
moves to a git-native pre-push hook design instead. Reviewers of #1405
(Rex B1/B2, Hakim H1/H3) found two problems with the command-text
approach:

- It could not reliably tell a real push from a grep pattern, a
  comment, or a commit message that merely mentions one.
- It could not safely resolve which repository a `cd` or `-C` target
  named.

AgDR-0104 already established that a command-text matcher cannot be
made sound for this class of decision. Git's own pre-push hook sees the
real ref and remote directly, with no text parsing involved. That is
where the #1366 fix belongs.
