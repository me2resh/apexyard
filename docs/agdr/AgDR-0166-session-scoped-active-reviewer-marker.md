---
id: AgDR-0166
timestamp: 2026-09-26T00:00:00Z
agent: platform-engineer
model: claude-sonnet-5
session: session_01KGvb2ba4gyT3TN8L2uMLTn
trigger: hook
status: executed
category: security
---

<!-- Uses the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Key the active-reviewer marker on the Claude Code session id

> In the context of the review-lock trust chain, facing one fixed marker
> path shared by every Claude Code session on an ops fork, I decided to key
> the marker filename on `CLAUDE_CODE_SESSION_ID` to achieve per-session
> isolation, accepting a documented fallback for callers with no session id.

## Context

Three hooks read or write `.claude/session/active-reviewer`:
`block-reviewer-repo-mutation.sh`, `warn-review-marker-write.sh`, and the
`clear-active-reviewer-marker.sh` SessionStart sweep. The review skills
(`/code-review`, `/security-review`, `/design-review`) write the marker
before spawning a reviewer. Each skill removes the marker after the review
posts.

Before this decision, the marker lived at one fixed path. Every session and
worktree on the same ops fork read and wrote that same file. A review
running in session B set the marker. `block-reviewer-repo-mutation.sh` then
read it in session A too. It blocked an unrelated `git commit` in session A
that had no part in that review. A SessionStart sweep in a fresh session C
removed the same file. That sweep could clear a marker a still-running
session B's review depended on. Two concurrent reviews could overwrite or
delete each other's marker outright.

me2resh/apexyard#1376 reports this failure. The failure is about session
identity, not about PR or repo identity. The marker content already
carries `<owner>/<repo>#<pr>:<kind>`. The missing key is which session
wrote the file.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep one fixed path. Add a file lock around each read and write. | Small diff | Does not fix cross-session leakage. A lock serializes access to shared state. It does not separate one session's review from another's. |
| Move the marker into a directory keyed on session id (`active-reviewer/<sid>`) | Clean separation | Changes the marker from a file to a directory-plus-file shape. Every reader and writer needs a directory check and a file check, for no gain over a suffixed filename. |
| Key the marker filename on `CLAUDE_CODE_SESSION_ID` through a resolver function, with a documented fallback to the pre-existing fixed path when no session id is set | Minimal diff per caller. One function, `active_reviewer_marker_path`, is the single source of truth. It preserves the exact pre-existing behavior for a caller with no session id, such as a git-native hook, CI, or a bare test-harness invocation. | Every writer and reader must switch from a literal path to the resolver function. A caller that hardcodes the literal path silently regresses to the shared-path bug. |

## Decision

Chosen: **key the marker filename on `CLAUDE_CODE_SESSION_ID`**, because it
isolates concurrent sessions with the smallest change. Its fallback
preserves every existing session-less caller unchanged.

A new `active_reviewer_marker_path` function lives in
`_lib-review-markers.sh`. It takes an optional marker home and an optional
session id. It resolves the session id from the explicit argument first,
then from `$CLAUDE_CODE_SESSION_ID`. When the resolved session id is empty,
it returns the pre-existing fixed path,
`<marker_home>/.claude/session/active-reviewer`. Otherwise it returns that
same path with a `.<safe_sid>` suffix. `<safe_sid>` collapses every
character outside `[A-Za-z0-9._-]` to `_`. A hostile or malformed session
id can never introduce a path separator through this function.

Every writer and reader now resolves the path through this function
instead of the literal string:

- `/code-review`, `/security-review`, `/design-review` (SKILL.md, step 0) —
  write the marker at skill entry, remove it at skill exit.
- `block-reviewer-repo-mutation.sh` — reads the marker to decide whether a
  Bash git mutation is blocked.
- `warn-review-marker-write.sh` — reads the marker to decide whether a
  `*-rex.approved` / `*-security.approved` / `*-architecture.approved` write
  is the sanctioned reviewer's own write.
- `clear-active-reviewer-marker.sh` — the SessionStart sweep. It now
  clears only the marker this session's own id would have written. It
  never clears a different session's live marker.

## Consequences

- A review in one session can grant or block repository mutations only in
  that same session. It can never grant or block mutations in a different
  session or worktree on the same ops fork.
- A SessionStart sweep clears only a stale marker left by an earlier,
  interrupted run of the same session id. It cannot clear a different,
  concurrently-running session's live marker.
- A caller with no session id keeps the exact pre-existing fixed-path
  behavior. Examples are a git-native hook, CI, and a bare test-harness
  invocation. This decision does not require every caller to adopt a
  session id.
- Every future writer or reader of this marker must resolve its path
  through `active_reviewer_marker_path`. It must never use the literal
  `.claude/session/active-reviewer` string. A literal-path caller silently
  reopens the cross-session leak this decision closes.
- Three test files pin the fix: `test_warn_review_marker_write.sh`,
  `test_block_reviewer_repo_mutation.sh`, and
  `test_clear_active_reviewer_marker.sh`. The fix-pinning cases in each
  file fail against the pre-decision hooks and pass after the fix. The
  regression-guard cases in each file pass against both the pre-decision
  and the post-decision hooks — they pin pre-existing behavior the fix
  must not disturb, not the new session-scoping behavior itself.

## Artifacts

- me2resh/apexyard#1376
- PR: fix(#1376): scope the active-reviewer marker per session and stop
  owner-name leak false blocks (branch
  `fix/GH-1376-per-session-reviewer-marker`)
