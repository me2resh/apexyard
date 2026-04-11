# Ticket Vocabulary — Reserved Terms

Tracker vocabulary is **reserved for real GitHub issues**, never for in-conversation planning. This rule exists to prevent the "vocabulary collision" failure mode where Claude's internal plan decomposition wears tracker clothing and the user reasonably reads it as tracker state.

## The rule

**`Ticket`, `#N`, and dependency notation (`blocked by #N`, `depends on #N`, `refs #N`, `closes #N`) refer ONLY to real GitHub issues that exist in a tracker and can be fetched with `gh issue view`.**

Do not use any of these terms for:

- Plan items you just thought of
- Work breakdowns presented in conversation
- Proposed decompositions that the user hasn't agreed to ship to a tracker yet
- Examples, hypotheticals, or design sketches

When you need to decompose work *in conversation* without committing it to a tracker, use one of these **safe vocabularies** instead:

| Safe | Why it's safe |
|------|---------------|
| `Step 1`, `Step 2`, … | Obviously sequential prose, not a tracker unit |
| `Item A`, `Item B`, … | Lettered, clearly a list convention |
| `Task 1`, `Task 2`, … | Generic work unit, not tracker-specific |
| Plain bullets or numbered lists | Zero tracker semantics |
| `Phase 1 — X`, `Phase 2 — Y`, … | Sequencing language |

**Never:**

- `Ticket 1: X` / `Ticket 2: Y`
- `#1`, `#2`, … (when referring to plan items, not real issues)
- `blocked by #1` (when #1 is a plan item, not a real issue)

The problem is not the number 1. The problem is the combination of the word "Ticket" *and* the `#N` notation *and* dependency arrows, which together paint tracker state on top of prose. Any one of those alone is usually fine; together they fabricate a tracker view.

## The boundary-crossing rule

If your plan includes items that need **tracker properties** — blocking relationships that persist across sessions, assignment to a specific owner, QA state transitions, cross-session tracking, merge-time auto-closing — then that's the moment to **stop planning in prose and call `gh issue create` for each**.

You cannot present a plan as a tracker view of work that is not in the tracker. Call the tool or call it planning. There is no middle ground.

### The checkpoint

Any time you catch yourself about to type `Ticket N:` or `#N` or `blocked by #N` in a plan response, STOP and ask:

1. **Does this reference an issue that already exists in a tracker?** If yes, you already fetched or created it — fine to use tracker notation. Otherwise:
2. **Does this plan item need tracker properties?** If yes, run `gh issue create` now for each item that needs one, collect the real numbers, and use those in your response. Otherwise:
3. **Rewrite with safe vocabulary** (`Step N`, `Item A`, plain bullets).

The cost of asking the user "do you want me to create these as real issues first?" is one message. The cost of a fabricated tracker view that the user takes as real is much higher — they act on it, assign people, plan sprints, and only discover later that none of the tickets exist.

## Anti-pattern (2026-04-11 incident)

This is the exact output shape that triggered this rule. A friend of the CEO ran ApexStack on an email-processor backlog and saw:

```
Ticket 1: Test Infrastructure Setup
Ticket 2: Replace Email Processor Stubs › blocked by #1
Ticket 3: Email Scheduler Tests › blocked by #1, #2
Ticket 4: Fix Email Sender Stubs › blocked by #1
Ticket 5: CSV Importer Integration Tests › blocked by #1
Ticket 6: CI Pipeline › blocked by #1
Ticket 7: Webhook + Cron Route Tests › blocked by #1, #5
Ticket 8: Public API Route Tests › blocked by #1, #5
Ticket 9: Phone + Background Processor Tests › blocked by #1
Ticket 10: AI Mock Tests for CI › blocked by #1
```

The user reasonably assumed these were real GitHub issues and asked "where did it create them?" The agent admitted: nowhere. They didn't exist. It was the agent's internal plan decomposition wearing tracker vocabulary. Even when the user said "follow SDLC", the agent kept regenerating similar output because it had no separate dialect for "plan" vs "tracker view".

### Corrected version (same content, safe vocabulary)

```
Here's a proposed breakdown for the email-processor backlog. **None of
these exist as GitHub issues yet** — tell me which ones to create as
real tickets and I'll run `gh issue create` for each.

Step 1 — Test Infrastructure Setup (foundation for everything below)
Step 2 — Replace Email Processor Stubs (needs Step 1 done first)
Step 3 — Email Scheduler Tests (needs Steps 1 and 2)
Step 4 — Fix Email Sender Stubs (needs Step 1)
Step 5 — CSV Importer Integration Tests (needs Step 1)
Step 6 — CI Pipeline (needs Step 1)
Step 7 — Webhook + Cron Route Tests (needs Steps 1 and 5)
Step 8 — Public API Route Tests (needs Steps 1 and 5)
Step 9 — Phone + Background Processor Tests (needs Step 1)
Step 10 — AI Mock Tests for CI (needs Step 1)

Want me to create GitHub issues for all 10, or only a subset? Once I
have real issue numbers, I'll re-post the plan using #N notation so you
can link and track.
```

Differences from the anti-pattern:

1. `Step N` instead of `Ticket N` — clearly a prose decomposition, not a tracker list
2. "needs Step N" instead of "blocked by #N" — prose dependency, not tracker semantics
3. **Explicit disclaimer** at the top: "None of these exist as GitHub issues yet"
4. **Explicit checkpoint** at the bottom: asks the user whether to cross the boundary into real issues
5. **Commits to re-posting with real `#N`** once the tickets exist

The corrected version is slightly longer but removes the ambiguity entirely. The user cannot mistake it for tracker state.

## Backstop enforcement

This rule is primarily self-discipline. It is also backed up by two mechanical hooks that catch the downstream symptoms if the rule fails:

| Hook | Event | What it catches |
|------|-------|-----------------|
| `validate-pr-create.sh` | `PreToolUse` on `gh pr create` | PR titles that reference an issue number which doesn't exist in the tracker repo |
| `verify-commit-refs.sh` | `PreToolUse` on `git commit -m / -F` | Commit messages with `Closes #N` / `Refs #N` / `Fixes #N` / `Resolves #N` pointing at issues that don't exist |

Both hooks block at the moment the fabricated reference would be committed to a durable artifact (PR title, commit message). They cannot see conversation prose — that's why the rule comes first and the hooks are labeled **backstops**, not the primary fix.

## Why not lint Claude's prose output?

Considered and rejected. Hooks run on tool calls, not on assistant text output. The only way to catch a fabricated `#N` in prose would be a self-discipline check Claude runs at the end of every response — which is exactly the failure mode this rule is trying to prevent. If Claude could reliably remember to check itself, the vocabulary collision wouldn't happen in the first place.

For adversarial trust beyond self-discipline, rely on GitHub branch protection, CODEOWNERS, and required status checks — those are a separate layer this rule does not replace.
