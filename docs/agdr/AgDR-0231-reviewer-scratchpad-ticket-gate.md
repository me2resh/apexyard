# Allow Reviewer Writes in the Session Scratchpad

> In the context of a sanctioned PR review, I allow writes under this session's scratchpad without a ticket. The ticket gate still protects the ops fork and every registered workspace.

## Context

A reviewer exports the PR head with `git archive <ref> | tar -x -C <dir>`. That extraction is an unextractable write. The non-git exemption never sees its directory, so the export still needs a ticket. The reviewer lock then blocks creating a scratch clone. The reviewer cannot build the copy it needs.

Claude Code v2.1.257 and later sends `scratchpad_dir` on hook stdin. The captured fixtures in this repo do not include that field. When the field is absent, the hook cannot know the harness directory by name.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep the ticket requirement for the export | No new exception | Leaves the export unusable during a review |
| Exempt every temp path while any review marker exists | Easy to implement | Lets one session use another session's marker, and lets a path leave the scratchpad |
| Exempt only this session's scratchpad while this session's marker exists | Matches the export the reviewer runs | Needs a path rule the hook can check without trusting the command |

## Decision

Chosen: **exempt only this session's scratchpad while this session's marker exists**.

The hook reads `scratchpad_dir` when the harness sends it. The directory must contain this session id as its own path segment. It must sit under `/tmp`, `/var/tmp`, `TMPDIR`, or `CLAUDE_CODE_TMPDIR`. It must not be the ops fork or a registered workspace, and it must not contain either tree. A `..` segment or a symlink keeps the gate closed. The target must be that directory or a path under it.

When `scratchpad_dir` is absent or null, only a path under those temp roots that contains this session id as a path segment qualifies. A present value that is empty, not a string, or fails a check does not use that wider rule.

The export is recognized only as the literal command `git archive <ref> | tar -x -C <absolute-path>`. A shell variable, a second command, or an absolute-name tar flag stays gated. The write detector is unchanged.

A typed build agent stays denied. Another session's marker does not count. A missing or mismatched ops-root pin keeps the gate closed.

## Consequences

- A sanctioned reviewer can export into this session's scratchpad without a ticket.
- A write outside that scratchpad still needs a ticket when the harness names the directory.
- The ops fork and registered workspaces still need a ticket.
- A `..` segment or a symlink never receives the exemption.
- A present `scratchpad_dir` that fails a check does not widen into the temp-path rule.
- Build agents gain no exemption.

## Artifacts

- Issue #1417
- `.claude/hooks/require-active-ticket.sh`
- `.claude/hooks/_lib-active-ticket.sh`
- `.claude/hooks/tests/test_require_active_ticket_review_scratchpad.sh`
- `.claude/agents/code-reviewer.md`
