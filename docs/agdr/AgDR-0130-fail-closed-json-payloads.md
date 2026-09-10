# Fail-closed handling for unreadable hook payloads

## Context

Blocking hooks used `jq` to read tool payloads. When `jq` was unavailable or the payload was malformed, several hooks treated the empty result as an unrelated command and returned success. This silently disabled controls.

## Options Considered

| Option | Result |
|--------|--------|
| Exit 2 for every unreadable payload | Rejected; broad Bash matchers would block unrelated commands. |
| Keep returning 0 | Rejected; a matching operation could bypass its control. |
| Scan the raw payload for each hook's narrow trigger shape | Chosen; matching writes fail closed while unrelated payloads remain no-ops. |

## Decision

Use a shared jq-free raw-payload matcher. The first implementation covers secret scans, protected-branch pushes, public-repo leak checks, and active-ticket edits or Bash writes. A matching unreadable payload returns exit 2. An unrelated or read-only payload returns exit 0.

## Consequences

The controls remain available when `jq` cannot parse the envelope. Trigger patterns must stay narrow and receive regression tests for both blocking and no-op cases. Remaining blocking hooks will adopt the same pattern in separate slices.

## References

- me2resh/apexyard#1152
