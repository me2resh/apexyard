# Isolate tracker config reads

> In the context of tracker adapter selection, an inherited config reader can retain an earlier repository root. I decided to load the reader inside each tracker config read so later calls use their current context.

## Context

`_tracker_load_config_lib` sourced the config reader into its caller. It skipped loading when `config_get_or` already existed.

The reader keeps root and config caches in shell variables. A later tracker call could inherit those values and select the wrong adapter.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Isolate each tracker config read in a subshell and reload the reader | Contains reader state and replaces inherited state | Each read sources the library again. |
| Reload the reader in the caller | Replaces inherited state for tracker calls | Leaves the reader defined for later callers. |
| Document the shared-shell constraint | Avoids code changes | A later caller can still select the wrong adapter. |

## Decision

Chosen: **isolate each tracker config read in a subshell and reload the reader**. The helper sources the sibling library for every read.

Tracker functions call the helper instead of loading the reader into their caller. An inherited `config_get_or` cannot bypass the reload.

## Consequences

- Tracker calls cannot leave a config reader or its caches in their caller.
- Tracker calls ignore a config reader inherited from an earlier context.
- Each read pays the cost of sourcing the config library. The existing config cache still handles eligible cross-process reads.

## Artifacts

- Issue #1461
- `.claude/hooks/_lib-tracker.sh`
- `.claude/hooks/tests/test_tracker_config_scope.sh`
