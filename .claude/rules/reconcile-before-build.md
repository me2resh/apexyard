# Reconcile Before Build — Check Existing State Before Spawning

Before spawning a build agent — a single `Agent` call, a `/fan-out` batch, or a `Workflow` stage — for a ticket, the agent's brief must include a step to **reconcile the ticket against already-shipped state first**. This rule is the **trigger heuristic**, the sibling of [`agent-role-selection.md`](agent-role-selection.md) (which picks *who* builds) — this one asks whether building is still needed *at all*.

A ticket describes work that was true when it was filed. By the time an agent is briefed from it, the work may already be done — merged in a prior session, shipped as part of a different ticket, or duplicated in a sibling repo. An agent that reads only the ticket body and starts building has no way to know that. The cost isn't hypothetical: in one session this exact pattern produced three wasted-or-near-wasted builds — a board-automation feature that had already shipped for free as a side effect of other work, a distribution epic whose walking skeleton had already merged, and a release-changelog fix that was already in `main`. One of the three agent briefs even described the design that had been *explicitly rejected* in the ticket's own history. All three were caught only by ad-hoc reconciliation, not by anything the workflow forced.

## Why OPEN ≠ undone

The instinct is to trust the tracker: an OPEN issue reads as "not built yet." Two things about this framework's own conventions make that instinct wrong:

- **`Refs #N` merges don't auto-close.** The QA gate (workflow-gates.md Gate 6) requires merge → QA verification → Done as separate steps. A PR merges with `Refs #N` specifically so the issue stays open until QA signs off — the code can be fully shipped while the ticket still reads OPEN.
- **The release-cut branch model keeps issues open across a release window.** Dev-merged work sits OPEN until the next `/release` cuts `main` (see `docs/release-process.md`, AgDR-0007). A ticket can be merged, deployed, and *live* for days while its issue still shows OPEN in `gh issue list`.

Both are working-as-designed apexyard conventions, not bugs — but they mean **"OPEN" is not a proxy for "not built."** The only way to know whether a ticket's work exists is to check the actual repo state, not the issue's status field.

## The concrete checks (do these before writing the brief)

Run all four before spawning — they're cheap relative to a wasted build:

- **Grep the repo for the feature.** Search for the ticket's key nouns (`mcp__apexyard-search__search_code` first per this repo's MCP-first convention, `grep`/`Explore` as fallback) — does the described behavior already exist in the codebase?
- **Search merged PRs for the ticket number.** `gh pr list --search "<N> in:title,body" --state merged --repo <owner>/<repo>` — a PR title or body referencing the ticket number, merged, is the strongest possible signal, even while the issue itself still reads OPEN.
- **Read the issue's own comments.** `gh issue view <N> --repo <owner>/<repo>` — has anyone already noted "shipped in #X" or reversed a design decision the ticket describes? A stale ticket sometimes carries its own answer.
- **Check for a sibling-repo duplicate.** In a multi-repo portfolio (framework vs. premium fork, or two managed projects sharing a feature area), the same work sometimes ships in the *other* repo first. A quick `gh pr list --search "<keyword>" --state merged --repo <sibling>` catches this before the brief goes out.

If any of these turn up a hit, stop before spawning — report the finding back and confirm with the user whether the ticket should close as already-done, or whether the residual work is narrower than the ticket implies.

## When NOT to bother

- **A genuinely fresh greenfield ticket with no plausible prior art** — a brand-new feature area, first PR in a new repo, or a ticket the user just finished writing in the same conversation. There's nothing to reconcile against.
- **The ticket was created and is being built in the same session**, with no gap where independent work could have landed underneath it.

## Self-check before spawning

Before emitting an `Agent` tool call (or a `/fan-out` task list) briefed from a tracker ticket, scan for:

```
[ ] Did I grep/search the repo for the feature the ticket describes?
[ ] Did I check `gh pr list --search "<N> in:title,body" --state merged` for this ticket number?
[ ] Did I read the issue's own comments for a "shipped in #X" or reversed-decision note?
[ ] If a sibling repo could plausibly hold the same feature, did I check there too?
[ ] Is this a genuinely fresh greenfield ticket where none of the above applies?
```

If the first four boxes are unchecked and the fifth doesn't apply, reconcile before spawning — not after the agent reports back having rebuilt something that already existed.

## Backstop

This rule is **primarily self-discipline** — the same shape as [`agent-role-selection.md`](agent-role-selection.md) and [`parallel-work.md`](parallel-work.md). Mechanical enforcement isn't viable: no shell hook can see "the agent should have reconciled" inside a spawn prompt — the `Agent`/`Task` tool call carries no structured field a `PreToolUse` matcher could inspect for "did you check first," and the check itself (grep, `gh pr list`, reading comments) requires judgment about what counts as a hit, not a pattern match.

The cost of running the four checks before spawning is a few tool calls. The cost of skipping them is a full build agent's worth of wasted work — plus, in the worst case, an agent confidently re-implementing a design the ticket's own history already rejected.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
