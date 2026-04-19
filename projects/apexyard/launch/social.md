# ApexYard v1.0 — launch social drafts

Paired with the launch blog post at `me2resh.com/blog/apexyard-where-projects-get-forged` (tracked in `me2resh/me2resh.com#56`). Publish these only after that post goes live — the link is dormant until then.

---

## Twitter thread (6 tweets)

### 1 / opening hook

> Shipped 5 products alone with Claude Code. Here's what I learned: prompting doesn't scale.
>
> I said "never merge without code review". The agent agreed. Then merged anyway, inferring approval from a plan-level "go".
>
> Rules need to be shell hooks, not markdown.

### 2 / merge gate

> The merge gate.
>
> Every `gh pr merge` is blocked unless two files exist on disk:
>
> - `<pr>-rex.approved` (code review)
> - `<pr>-ceo.approved` (explicit per-PR nod)
>
> Both contain the current HEAD SHA. New commits invalidate both. The agent cannot infer CEO approval.

### 3 / migration gate

> The migration gate.
>
> Editing migration files (`prisma/schema.prisma`, `alembic/versions/*`, etc.) is blocked at the Edit tool call unless:
>
> 1. Active ticket has the `migration` label
> 2. Its body references a rollback AgDR
>
> You articulate rollback BEFORE you break prod.

### 4 / ticket-vocabulary rule

> The ticket-vocabulary rule.
>
> The agent kept generating "Ticket 1: X, blocked by #2" — fake GitHub issues that looked real. A CTO friend thought they existed.
>
> Now `Ticket` + `#N` are reserved for real issues. Fake `Closes #N` in commits is refused by a hook.

### 5 / what changes in practice

> Six months in:
>
> • one inbox across 5 repos
> • zero accidental merges — the gate has blocked 4 I half-approved
> • every arch decision has an AgDR — 47 so far
> • the agent stopped fabricating tracker state
>
> The rules are in the filesystem now.

### 6 / CTA

> ApexYard v1.0 is MIT, plain markdown + shell, Claude Code native.
>
> Fork, register one project, run `/inbox`.
>
> Blog: https://me2resh.com/blog/apexyard-where-projects-get-forged
> Landing: https://yard.apexscript.com
> GitHub: https://github.com/me2resh/apexyard

---

## Character counts (manual check)

| Tweet | Characters (URLs count as 23) |
|-------|-------------------------------|
| 1 | ~260 |
| 2 | ~260 |
| 3 | ~275 |
| 4 | ~275 |
| 5 | ~265 |
| 6 | ~220 (text 150 + 3 URLs × 23) |

All under 280. Re-count before posting via a Twitter composer; long dashes and smart quotes can add a few chars in some counters.

---

## LinkedIn post (~340 words)

> Six months ago I started shipping multiple products alone with Claude Code. Two landing pages, a Chrome extension, a content-moderation backend, a macOS Swift app. One engineer, one AI, five repos.
>
> Here is what I learned: prompting does not scale.
>
> I could tell the agent "never merge without code review". The agent would agree. Then, half an hour later, deep in a 6-step plan where step 3 happened to be a merge, I would say "go" to approve the plan — and the agent would execute all six steps, because my "go" technically covered it.
>
> That is not an agent failure. That is me relying on the agent to police itself against rules written in prose. The fix is not a better prompt. The fix is a shell script that blocks the command.
>
> That is what ApexYard is.
>
> It is an open-source stack (MIT, plain markdown and shell, Claude Code native) that turns the SDLC into runnable artefacts. 19 role definitions. 33 slash commands. 18 shell hooks wired to `PreToolUse` and `PostToolUse` events.
>
> Three concrete gates in it:
>
> • The merge gate requires two SHA-bound approval markers on disk before `gh pr merge` is allowed — plan-level "go" is not merge approval.
>
> • The migration gate blocks Edit tool calls on migration-path files unless the active ticket has a `migration` label and its body references a rollback AgDR.
>
> • The ticket-vocabulary rule forbids the agent from generating fake GitHub issue numbers in chat plans — and a commit-message hook refuses `Closes #N` pointing at issues that do not exist.
>
> Six months in: one inbox across 5 repos. Zero accidental merges. Every architecture decision documented as an AgDR. No more fabricated tracker state.
>
> Full writeup: https://me2resh.com/blog/apexyard-where-projects-get-forged
>
> Fork it, register one project, run `/inbox`. If after a week you're not using it, delete the fork.
>
> github.com/me2resh/apexyard · yard.apexscript.com

---

## Publishing sequence

1. Merge the blog post PR (`me2resh/me2resh.com#57`) so the URL is live.
2. Verify `https://me2resh.com/blog/apexyard-where-projects-get-forged` resolves (200, renders, meta tags sane).
3. Paste the Twitter thread into the composer one tweet at a time; verify each tweet's char count under 280.
4. Paste the LinkedIn post as a single update.
5. Cross-link: reply to tweet 6 with "Mirror on LinkedIn: [URL]" once the LinkedIn post is live.
