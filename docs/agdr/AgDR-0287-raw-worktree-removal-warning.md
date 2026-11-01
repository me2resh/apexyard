# AgDR-0287: Warn about raw worktree removal

## Context

Issue #1940 adds owner and preservation checks to the `/approve-merge` cleanup helper.
A raw removal directly invokes `git worktree remove` instead of that helper.
It bypasses both checks.
A live or unknown owner may still be writing.
The worktree may contain uncommitted or unpushed work.

AgDR-0173 explains why command text cannot reliably identify Git operations or their target repositories.
An advisory can name a risk without claiming complete detection.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Block raw removal commands | Enforces the helper for detected commands | Requires unreliable shell interpretation and can block legitimate work |
| Warn on a literal command shape | Gives focused cleanup advice | Deliberately misses other invocation shapes |
| Add no warning | Adds no hook overhead | Leaves direct removal without cleanup advice |

## Decision

The owner chose an advisory warning only.
The hook always exits 0, including malformed input and commands that produce a warning.
It prints advice to stderr and never runs Git.

The hook accepts only a Bash tool payload with one string command.
After trimming surrounding whitespace, it matches the entire command against this literal shape:

```text
git [-C <path>] worktree remove [options] <path>
```

Paths use literal, unquoted characters without shell expansions.
Options are dash-prefixed words before the final path.
The hook uses one anchored pattern on the raw string.
It does not tokenize, unquote, or emulate shell parsing.
This boundary follows the command-text limits in AgDR-0173.

The pattern excludes command separators, pipelines, internal newlines, substitutions, backticks, redirections, and heredocs.
It ignores quoted commands and text that merely mentions removal.
The cleanup helper is exempt because its invocation does not match the literal Git command shape.
The helper already checks ownership and preservation.

The warning names both checks and directs the operator to `/approve-merge` cleanup or `remove-worktree.sh`.
The Bash dispatcher registers the hook in its wildcard registry and always-on loop.
The hook follows `warn-isolated-build-risk.sh` and uses the default `run_hook` branch.
This fail-open advisory path permits non-blocking failures and continues to later hooks.
The dispatcher never routes this hook through `run_fail_closed_hook`.
The existing single Bash settings entry remains unchanged.

## Consequences

The warning does not prevent removal or guarantee preservation.
It does not catch compound commands, aliases, scripts, quoted paths, expansions, or other harnesses' tools.
It does not inspect owner records or worktree contents.
Missing or invalid JSON input produces no warning.
An unavailable JSON reader also produces no warning.

## Artifacts

- Refs #1940
- `.claude/hooks/warn-raw-worktree-removal.sh`
- `.claude/hooks/tests/test_warn_raw_worktree_removal.sh`
- `.claude/hooks/dispatch-bash.sh`
- `.claude/hooks/tests/test_dispatch_bash.sh`
