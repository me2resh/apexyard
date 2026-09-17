# Bash PreToolUse dispatcher

## Status

Accepted

## Context

The framework registers 54 Bash PreToolUse commands in `.claude/settings.json`.
Each command repeats the same ops-root discovery wrapper. The configuration
also carries command predicates beside the hook command, which other harness
adapters must compile because those predicates are not portable hook fields.
This creates unnecessary process fan-out and makes the Bash gate list harder
to audit.

## Decision

Register one Bash PreToolUse command that resolves the ops root once and
executes `.claude/hooks/dispatch-bash.sh`. The dispatcher reads the Bash
command from the hook payload, runs the unconditional safety hooks, and then
executes each matching existing hook at most once. Unknown commands receive
the unconditional safety checks and no command-specific gate. Existing hook
scripts remain the source of truth, including their exit codes and special
environment variables. The dispatcher does not keep the previous
settings-list order. Unconditional safety hooks always run before
command-specific gates.

## Options considered

| Option | Result |
| --- | --- |
| One dispatcher over the existing Bash hooks | Accepted. It removes repeated wrappers and preserves one gate implementation. |
| Copy each gate into a dispatcher implementation | Rejected. It would duplicate policy and drift from the audited scripts. |
| Keep the 54 entries and optimize individual hooks | Rejected. It leaves the configuration fan-out and repeated root discovery in place. |

## Consequences

The dispatcher must be updated when a Bash hook is added or its command
predicate changes. Its regression test checks unconditional calls, command
selection, deduplication, non-blocking hook failures, and blocking exit-code
propagation. Hooks now share one dispatcher process, so an unexpected hook
failure must be collected and reported while later hooks continue to run;
only exit code 2 stops dispatch. The dispatcher also owns the propagation of
`APEXYARD_OPS_SCOPE_GUARD` and `APEXYARD_REVIEW_OPS_ROOT`, which previously
lived in settings wrappers and therefore requires dispatcher-level regression
coverage.

The previous 54-entry list ran some unconditional hooks after
command-specific gates. The dispatcher always runs the nine unconditional
hooks first. Allow and block outcomes stay the same when one gate exits 2.
The first blocking reason a user sees can change when two gates would both
exit 2. That trade-off is accepted to keep one routing table.

`test_hook_exec_bits.sh` must include the dispatcher table. Settings.json
no longer lists the delegated Bash gates. A lost execute bit on those
scripts now warns and continues. The exec-bit control is then the remaining
guard against a silent fail-open.

The dispatcher must not abort on a missing or broken `jq`. Claude Code
only blocks exit 2. If command parse fails, the dispatcher still runs the
four merge gates so their raw-payload fallback can block (T13).

On the same worktree, three sequential `true` calls measured about 10.24
seconds through the old 54-entry list (about 3.41 seconds per call) and 1.43
seconds through the dispatcher (about 0.48 seconds per call). The original
measurement did not record a machine class; future comparisons must record
that context and use the same three-call method.

## References

- Issue #1317
- Closed issue #1013
