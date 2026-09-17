# Split-portfolio adapter anchor and link validation

## Status

Accepted

## Context

Project-local Codex, pi, and opencode adapters run from managed workspaces.
Those workspaces are below the private portfolio repository. The canonical
hooks and settings remain in the framework repository. A plain ancestor walk
therefore cannot find the framework hooks.

## Decision

Adapter installation establishes a portfolio ops-root anchor and creates
relative links for `.claude/hooks` and `.claude/settings.json` to the canonical
framework checkout. The installer verifies both links resolve to those exact
targets before reporting the portfolio current. It reports drift for missing,
non-link, or unrelated targets. It uses a relative link so generated adapter
files do not contain a machine-specific absolute path.

## Options considered

| Option | Result |
| --- | --- |
| Add a portfolio anchor and exact relative links | Accepted. It preserves one hook source and works from managed workspaces. |
| Teach every hook and adapter to discover a sibling framework repository | Rejected. It duplicates split-portfolio path logic across runtimes. |
| Embed an absolute framework path in generated adapter commands | Rejected. It breaks when the portfolio moves and exposes machine-specific paths. |

## Consequences

The private portfolio root owns the runtime anchor and links. The framework
installer requires Python to calculate relative paths. The regression suite
executes a generated Codex hook from a managed workspace and rejects an
unrelated symlink target. That assertion unsets the session pin so the fixture
anchor is the one that runs. Resolution from a common parent remains governed by
the existing nested-ops-root precedence tests.

## References

- Issue #1315
- [AgDR-0155](AgDR-0155-portfolio-harness-adapters.md)
