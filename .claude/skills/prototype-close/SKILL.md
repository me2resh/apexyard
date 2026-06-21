---
name: prototype-close
description: Close a prototype via the disposition gate — `--promote` files a [Feature] follow-up, `--discard` writes a memo. Mirror of /spike-close for throwaway UX/demo prototypes.
argument-hint: "--promote | --discard [<prototype-ticket-number>]"
allowed-tools: Bash, Read, Write
---

# /prototype-close — Close a Prototype via the Disposition Gate

The disposition gate prevents the worst-of-both case: a prototype that "looked great in the demo" but never decides what to do with it, leaving a throwaway mockup that quietly gets promoted into production. Every prototype must close with one of two paths:

- **PROMOTE** — the direction was chosen; file a fresh `[Feature]` ticket so the real work goes through the full production SDLC. The prototype artifact is NOT lifted into production — the new feature re-implements based on the chosen direction.
- **DISCARD** — the direction was rejected (or "not now"); write a memo at `docs/prototype-memos/<slug>.md` so future-us doesn't re-explore the same ground.

This is the UX/demo sibling of `/spike-close` (technical exploration). Same gate, same two paths, different artifact directory (`docs/prototype-memos/` vs `docs/spike-memos/`).

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the ideas backlog via `portfolio_ideas_backlog` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
```

Defaults match today's single-fork layout. See `docs/multi-project.md`.

## Usage

```
/prototype-close --promote 142
/prototype-close --discard 142
/prototype-close --promote          # uses the active-ticket marker
/prototype-close --discard
```

## Process

### 1. Resolve the prototype ticket

Two paths:

- If `$ARGUMENTS` includes a number (e.g. `--promote 142` or `--discard owner/repo#142`), use that.
- Otherwise read the active-ticket marker (`.claude/session/current-ticket` or `.claude/session/tickets/<project>`) and use the ticket recorded there. If neither resolves, ask:

```
Which prototype are you closing? Pass --promote <number> or --discard <number>,
or run /start-ticket first.
```

### 2. Verify it really is a prototype

Run `gh issue view <number> --repo <owner/repo> --json title,labels,state,body`. The skill proceeds if:

- title starts with `[Prototype]`, OR
- labels include `prototype`

If the ticket is neither, refuse:

```
Issue {owner/repo}#{number} doesn't look like a prototype (no [Prototype]
prefix, no `prototype` label). /prototype-close is for prototype disposition
only — close production-shaped tickets via the normal QA → Done flow, and
technical spikes via /spike-close.
```

If the ticket is already CLOSED, warn and ask whether to continue (the user may want to retroactively record disposition):

```
{owner/repo}#{number} is already closed. Continue and (a) file the follow-
up artefact only, or (b) abort? (continue / abort)
```

### 3. Branch on `--promote` vs `--discard`

#### 3a. PROMOTE — three questions, then file a [Feature]

Ask one at a time:

**i) Production-shaped feature title**

```
The prototype chose a direction. What's the title of the production-shaped
feature ticket we're filing as the follow-up?
```

**ii) Production-shaped scope**

```
What's the scope for the production version? This is the user-facing
capability, not the prototype's exploration goal.
(One paragraph or bullets.)
```

**iii) What's NOT being carried over**

```
What did the prototype fake that's NOT being lifted into production? (e.g.
"the mockup used stubbed data; production needs the real API",
"the demo skipped error states and empty states — we'll design those in
the feature".)
```

Then preview the [Feature] ticket and confirm. The body MUST include a
"Prototype findings" section that links back to the prototype:

```
**[Feature] {title}**

## User Story
{prompted from the operator — same as /feature step 3a}

## Acceptance Criteria
- [ ] {prompted from the operator}

## Prototype findings
This feature was promoted from {owner/repo}#{prototype-number}.
The prototype chose the direction: {one-sentence summary of the look/feel decided}.

What is NOT being carried over from the prototype artifact:
- {item 1}
- {item 2}

## Out of Scope
{or "—"}
```

After confirmation, create the issue:

```bash
gh issue create --repo {owner/repo} \
  --title "[Feature] {title}" \
  --label "enhancement" \
  --body "{body}"
```

Capture the new issue number, then close the prototype with a cross-ref comment:

```bash
gh issue close {prototype-number} --repo {owner/repo} \
  --comment "Prototype disposition: PROMOTE. Follow-up filed as #{new-number} — {feature-title}. Prototype artifact is NOT being lifted into production; the new feature work re-implements the chosen direction recorded above."
```

Return both URLs:

```
Prototype closed: {owner/repo}#{prototype-number}
Follow-up:        {owner/repo}#{new-number} — {feature-title}
                  {url}
```

#### 3b. DISCARD — one question, then write a memo

```
What did we learn? One paragraph — enough that a future engineer who
asks the same UX/demo question (or revisits the same flow) finds this memo
and doesn't re-explore the same ground. Be concrete:
  - what direction were we exploring?
  - what did the prototype show?
  - why is the answer no / not this direction? (or "not now")
  - what would change the answer? (under what conditions might we revisit?)
```

Then derive a slug from the prototype title (lowercase, kebab-case, max 40
chars, stopwords trimmed) and write the memo:

```bash
mkdir -p docs/prototype-memos
cat > docs/prototype-memos/{slug}.md <<'EOF'
# Prototype memo: {title}

> **Disposition: DISCARD** — direction rejected; not pursuing further.

- **Prototype ticket**: {owner/repo}#{number}
- **Author**: {git config user.name}
- **Closed**: {ISO-8601 date}

## Direction Question (from the prototype ticket)

{direction question from the original ticket body}

## Findings

{the one-paragraph answer the operator wrote}

## Why we're not pursuing

{extracted from the operator's answer — the "answer is no / not this
direction" part}

## What would change the answer

{conditions under which we might revisit — extracted from the operator's
answer, or "—" if not specified}

## Artefacts

- Original prototype ticket: {owner/repo}#{number}
- Prototype branch: prototype/<TICKET-ID>-<slug> (delete after merge of this memo)
EOF
```

The memo is committed in a separate PR (the prototype's PR may or may not have merged — the memo PR is the disposition artefact, separate from any code).

After writing the memo, close the prototype with a cross-ref:

```bash
gh issue close {prototype-number} --repo {owner/repo} \
  --comment "Prototype disposition: DISCARD. Memo at docs/prototype-memos/{slug}.md (commit in follow-up PR). Prototype branch can be deleted; nothing is being lifted into production."
```

Return:

```
Prototype closed: {owner/repo}#{prototype-number}
Memo path:        docs/prototype-memos/{slug}.md

Next steps:
  1. Stage the memo:   git add docs/prototype-memos/{slug}.md
  2. Commit:           git commit -m "docs: prototype memo for #{prototype-number}"
  3. Push + PR — the memo is the disposition artefact.
  4. Delete the prototype branch once the memo PR merges.
```

## Rules

1. **Disposition is PROMOTE or DISCARD only.** No third path. The whole point of the gate is to forbid "decide later".
2. **PROMOTE files a fresh [Feature].** The prototype artifact is NOT lifted into production. Promotion creates a new ticket; the production work re-implements the chosen direction.
3. **DISCARD writes a memo.** Prototype-memo at `docs/prototype-memos/<slug>.md` is the artefact — no memo, no DISCARD.
4. **One question at a time.** Same conversational rule as `/prototype`, `/spike-close`, and `/feature`.
5. **No hard block on closing without /prototype-close.** The skill prompts; closure is ultimately the operator's call. The cost of forgetting is no record of what was learned, which is enough downside to motivate running the gate without needing a mechanical block.
6. **Cross-references both ways.** PROMOTE links the new feature back to the prototype; DISCARD links the memo back to the prototype. Future archaeology should always find the trail.

## Edge cases

- **Prototype PR didn't merge.** Fine — the memo / follow-up feature is the disposition artefact, not the prototype code itself. PROMOTE: file the new feature, close the prototype, abandon the branch. DISCARD: write the memo, close the prototype, abandon the branch.
- **Direction was partially chosen.** Treat the partial as PROMOTE — file the [Feature] for the parts you're keeping; cover the parts you're dropping in the "What is NOT being carried over" section.
- **A prototype that turned into a feasibility question.** If the exploration revealed the real open question is technical ("will this even work?"), file a `/spike` for that, and DISCARD the prototype with a memo pointing at the new spike.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
