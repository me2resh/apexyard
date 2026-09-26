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
before spawning a reviewer and remove it after the review posts.

Before this decision, the marker lived at one fixed path. Every session and
worktree on the same ops fork read and wrote that same file. A review
running in session B set the marker; `block-reviewer-repo-mutation.sh` then
read it in session A too, and blocked an unrelated `git commit` that had no
part in that review. A SessionStart sweep in a fresh session C removed the
same file, which could clear a marker a still-running session B's review
depended on. Two concurrent reviews could overwrite or delete each other's
marker outright.

me2resh/apexyard#1376 reports this failure. The report ties it to session
isolation, not to PR or repo identity — the existing marker content already
carries `<owner>/<repo>#<pr>:<kind>`, so the missing key is which session
wrote the file.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep one fixed path; add a file lock around read/write | Small diff | Does not fix cross-session leakage — a lock serializes access to the same shared state, it does not separate one session's review from another's |
| Move the marker into a directory keyed on session id (`active-reviewer/<sid>`) | Clean separation | Changes the marker from a file to a directory-plus-file shape; every reader/writer needs a directory-existence check in addition to a file check, for no gain over a suffixed filename |
| Key the marker FILENAME on `CLAUDE_CODE_SESSION_ID` via a resolver function, with a documented fallback to the pre-existing fixed path when no session id is set | Minimal diff per caller; one function, `active_reviewer_marker_path`, is the single source of truth; preserves the exact pre-existing behavior for a git-native hook, CI, or a bare test-harness invocation, none of which set the env var | Requires every writer and reader to switch from a literal path to the resolver function; a caller that hardcodes the literal path silently regresses to the shared-path bug |

## Decision

Chosen: **key the marker filename on `CLAUDE_CODE_SESSION_ID`**, through a
new `active_reviewer_marker_path` function in `_lib-review-markers.sh`,
because it isolates concurrent sessions with the smallest change, and its
fallback preserves every existing session-less caller unchanged.

`active_reviewer_marker_path [marker_home] [session_id]` returns
`<marker_home>/.claude/session/active-reviewer` when the session id (the
explicit argument, or `$CLAUDE_CODE_SESSION_ID` when the argument is empty)
is empty, and `<marker_home>/.claude/session/active-reviewer.<safe_sid>`
otherwise. `<safe_sid>` collapses every character outside
`[A-Za-z0-9._-]` to `_`, so a hostile or malformed session id can never
introduce a path separator and escape the `.claude/session/` directory.

Every writer and reader now resolves the path through this function instead
of the literal string:

- `/code-review`, `/security-review`, `/design-review` (SKILL.md, step 0) —
  write the marker at skill entry, remove it at skill exit.
- `block-reviewer-repo-mutation.sh` — reads the marker to decide whether a
  Bash git mutation is blocked.
- `warn-review-marker-write.sh` — reads the marker to decide whether a
  `*-rex.approved` / `*-security.approved` / `*-architecture.approved` write
  is the sanctioned reviewer's own write.
- `clear-active-reviewer-marker.sh` — the SessionStart sweep, now clears
  only the marker `CLAUDE_CODE_SESSION_ID` for THIS session would have
  written, never a different session's live marker.

## Consequences

- A review in one session can grant or block repository mutations only in
  that same session — never in a different session or worktree on the same
  ops fork.
- A SessionStart sweep clears only a stale marker left by an earlier,
  interrupted run of the SAME session id. It cannot clear a different,
  concurrently-running session's live marker.
- A caller with no session id (a git-native hook, CI, or a bare
  test-harness invocation) keeps the exact pre-existing fixed-path
  behavior — this decision does not require every caller to adopt a
  session id.
- Every future writer or reader of this marker MUST resolve its path
  through `active_reviewer_marker_path`, never a literal
  `.claude/session/active-reviewer` string, or it silently reopens the
  cross-session leak this decision closes.
- Regression tests in `test_warn_review_marker_write.sh`,
  `test_block_reviewer_repo_mutation.sh`, and
  `test_clear_active_reviewer_marker.sh` pin same-session suppression,
  cross-session non-suppression, and the no-session-id fallback, each
  proven to fail against the pre-decision hooks.

## Artifacts

- me2resh/apexyard#1376
- PR: fix(#1376): scope the active-reviewer marker per session and stop
  owner-name leak false blocks (branch
  `fix/GH-1376-per-session-reviewer-marker`)
