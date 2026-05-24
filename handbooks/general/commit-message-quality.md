# Handbook: Commit Message Quality

**Scope:** all PRs (handbook lives under `general/` — Rex always loads it).
**Enforcement:** advisory.

## The rule

Commit messages explain **WHY**, not WHAT. The diff already shows what changed; the message is the only place the *reasoning* lives — and the only place future-readers (including future-you) can recover the context that motivated the change.

| Required element | Detail |
|---|---|
| Subject line | `type(#TICKET): description` per `.claude/rules/git-conventions.md` (e.g. `feat(#218): add audit-history shared lib`). Imperative mood ("add", not "added"). Under 70 chars. No trailing period. |
| Body | Present for any non-trivial change. Explains the WHY: what problem the change addresses, what alternatives were considered (briefly), what risks remain. Wrap at 72 cols. |
| Ticket reference | `Closes #N` or `Refs #N` near the bottom of the body, single occurrence (the framework's hook blocks multi-Closes). |
| Co-authorship | When pair-programming or AI-assisted, include `Co-Authored-By:` lines. |

## Why

Six months from now, someone will `git blame` the line you're about to write and read your commit message to understand WHY. The diff tells them what changed. The message is your only chance to tell them why.

Commit messages that say "fixed bug", "update", or just `chore: cleanup` waste that opportunity. The reader has to dig through the PR (which may have been deleted), the linked ticket (which may have been closed and re-purposed), or the author's memory (which has moved on).

A good commit message turns a 30-minute git-archaeology session into a 30-second read.

## What Rex flags

When reviewing a PR, surface a finding when:

1. The PR has a commit whose subject is fewer than 10 characters of meaningful text after the `type(#N):` prefix (e.g. `chore(#42): fix`, `feat(#42): wip`, `refactor(#42): cleanup`).
2. The PR has a commit with no body AND the diff is >50 lines (small fixes can get away with subject-only; substantive changes deserve a body).
3. The commit body is a one-liner restating the subject (e.g. subject `feat(#42): add user export`, body `Adds user export.`). This is the WHAT-not-WHY pattern.
4. The commit message contains placeholder text — `<description>`, `TODO`, `XXX`, `[fill in]`, etc.

## Sample findings

> **Commit-message quality** — Commit `abc1234` has subject `chore(#42): fix` and no body. The diff is 180 lines across 6 files. Add a body explaining what the fix addresses, what was tried before, and any follow-up considerations.
>
> **Commit-message quality** — Commit `def5678` body says only `Adds user export feature.` — restating the subject line. Replace with the WHY: what user need does the export serve, what format / scope was chosen and why, what alternatives were considered.

## What's NOT a violation

- A trivial typo fix or a single-line docs change can ship as subject-only — the diff is self-evident.
- A revert commit (`Revert "..."`) follows git's convention and doesn't need a hand-written body if the original had one.
- A merge commit on a feature branch (rare with the framework's squash-merge default, but valid for stacked PRs).

## Recipe — what a good body looks like

The body has three rough sections:

1. **What** — one sentence summary (yes, even though we said "WHY not WHAT" — this anchors the reader before the WHY).
2. **Why** — the load-bearing paragraph. What problem does this solve? What was the trigger? Was there an incident, a metric, an AgDR, a customer ask?
3. **Trade-offs** — anything notable. What this *doesn't* fix. Known limitations. Follow-up work that's filed as a separate ticket.

Example:

```
fix(#218): handle empty findings array in audit_run_persist

The lib's stats-derivation jq passed an empty findings array to
`reduce` with no fallback, causing the persist to silently emit an
empty stats object on first runs (no findings yet logged).

A first-run with zero findings is the common case for a new project's
first /threat-model invocation. The frontmatter would render with all
severity buckets at 0, which is the right semantic but only by
accident — the stats object should be present even when findings[]
is empty.

Fix: pre-seed the reduce accumulator with explicit zero buckets.

Trade-off: the JSON file now always has a stats key even on first
runs, slightly larger than before. The trend renderer was already
defensive about a missing stats key; the change is forward-compatible.

Refs #218
```

The diff alone wouldn't tell you why this matters. The message does.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
