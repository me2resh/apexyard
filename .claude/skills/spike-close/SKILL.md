---
name: spike-close
description: Close a spike via the disposition gate — `--promote` files a [Feature] follow-up, `--discard` writes a memo.
argument-hint: "--promote | --discard [<spike-ticket-number>]"
allowed-tools: Bash, Read, Write
---

# /spike-close — Close a Spike via the Disposition Gate

The disposition gate prevents the worst-of-both case: a spike that "succeeded" but never decides what to do with the code, leaving half-shipped exploration in main. Every spike must close with one of two paths:

- **PROMOTE** — the hypothesis was confirmed; file a fresh `[Feature]` ticket so the work goes through the full production SDLC. The spike branch itself is NOT lifted into production — the new feature work re-implements based on the spike's findings.
- **DISCARD** — the hypothesis was rejected (or the answer is "we shouldn't do this"); delete the spike branch and write a memo at `docs/spike-memos/<slug>.md` so future-us doesn't re-explore the same ground.

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
/spike-close --promote 142
/spike-close --discard 142
/spike-close --promote          # uses the active-ticket marker
/spike-close --discard
```

## Process

### 1. Resolve the spike ticket

Two paths:

- If `$ARGUMENTS` includes a number (e.g. `--promote 142` or `--discard owner/repo#142`), use that.
- Otherwise read the active-ticket marker (`.claude/session/current-ticket` or `.claude/session/tickets/<project>`) and use the ticket recorded there. If neither resolves, ask:

```
Which spike are you closing? Pass --promote <number> or --discard <number>,
or run /start-ticket first.
```

### 2. Verify it really is a spike

Run `gh issue view <number> --repo <owner/repo> --json title,labels,state,body`. The skill proceeds if:

- title starts with `[Spike]`, OR
- labels include `spike`

If the ticket is neither, refuse:

```
Issue {owner/repo}#{number} doesn't look like a spike (no [Spike] prefix,
no `spike` label). /spike-close is for spike disposition only — close
production-shaped tickets via the normal QA → Done flow.
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
The spike confirmed the hypothesis. What's the title of the production-
shaped feature ticket we're filing as the follow-up?
```

**ii) Production-shaped scope**

```
What's the scope for the production version? This is the user-facing
capability, not the spike's exploration goal.
(One paragraph or bullets.)
```

**iii) What's NOT being carried over**

```
What did the spike try that's NOT being lifted into production? (e.g.
"the prototype used in-memory storage; production needs Postgres",
"the spike skipped error handling — we'll add it in the feature".)
```

Then preview the [Feature] ticket and confirm. The body MUST include a
"Spike findings" section that links back to the spike:

```
**[Feature] {title}**

## User Story
{prompted from the operator — same as /feature step 3a}

## Acceptance Criteria
- [ ] {prompted from the operator}

## Spike findings
This feature was promoted from {owner/repo}#{spike-number}.
The spike confirmed: {one-sentence summary of what the spike proved}.

What is NOT being carried over from the spike branch:
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

Capture the new issue number, then close the spike with a cross-ref comment:

```bash
gh issue close {spike-number} --repo {owner/repo} \
  --comment "Spike disposition: PROMOTE. Follow-up filed as #{new-number} — {feature-title}. Spike branch is NOT being lifted into production; the new feature work re-implements based on the findings recorded above."
```

Return both URLs:

```
Spike closed: {owner/repo}#{spike-number}
Follow-up:    {owner/repo}#{new-number} — {feature-title}
              {url}
```

#### 3b. DISCARD — one question, then write a memo

```
What did we learn? One paragraph — enough that a future engineer who
asks the same question (or revisits the same library / approach) finds
this memo and doesn't re-explore the same ground. Be concrete:
  - what was the hypothesis?
  - what did the experiment show?
  - why is the answer no? (or "we shouldn't do this", or "X first")
  - what would change the answer? (under what conditions might we revisit?)
```

Then derive a slug from the spike title (lowercase, kebab-case, max 40 chars,
stopwords trimmed) and write the memo:

```bash
mkdir -p docs/spike-memos
cat > docs/spike-memos/{slug}.md <<'EOF'
# Spike memo: {title}

> **Disposition: DISCARD** — hypothesis rejected; not pursuing further.

- **Spike ticket**: {owner/repo}#{number}
- **Author**: {git config user.name}
- **Closed**: {ISO-8601 date}

## Hypothesis (from the spike ticket)

{hypothesis from the original ticket body}

## Findings

{the one-paragraph answer the operator wrote}

## Why we're not pursuing

{extracted from the operator's answer — the "answer is no" part}

## What would change the answer

{conditions under which we might revisit — extracted from the operator's
answer, or "—" if not specified}

## Artefacts

- Original spike ticket: {owner/repo}#{number}
- Spike branch: spike/<TICKET-ID>-<slug> (delete after merge of this memo)
EOF
```

The memo is committed in a separate PR (the spike's PR may or may not have merged — the memo PR is the disposition artefact, separate from any code).

After writing the memo, close the spike with a cross-ref:

```bash
gh issue close {spike-number} --repo {owner/repo} \
  --comment "Spike disposition: DISCARD. Memo at docs/spike-memos/{slug}.md (commit in follow-up PR). Spike branch can be deleted; nothing is being lifted into production."
```

Return:

```
Spike closed: {owner/repo}#{spike-number}
Memo path:    docs/spike-memos/{slug}.md

Next steps:
  1. Stage the memo:   git add docs/spike-memos/{slug}.md
  2. Commit:           git commit -m "docs: spike memo for #{spike-number}"
  3. Push + PR — the memo is the disposition artefact.
  4. Delete the spike branch once the memo PR merges.
```

## Rules

1. **Disposition is PROMOTE or DISCARD only.** No third path. The whole point of the gate is to forbid "decide later".
2. **PROMOTE files a fresh [Feature].** The spike branch is NOT lifted into production. Promotion creates a new ticket; the production work re-implements based on the findings.
3. **DISCARD writes a memo.** Spike-memo at `docs/spike-memos/<slug>.md` is the artefact — no memo, no DISCARD.
4. **One question at a time.** Same conversational rule as `/spike` and `/feature`.
5. **No hard block on closing without /spike-close.** The skill prompts; closure is ultimately the operator's call. The cost of forgetting is no record of what was learned, which is enough downside to motivate running the gate without needing a mechanical block.
6. **Cross-references both ways.** PROMOTE links the new feature back to the spike; DISCARD links the memo back to the spike. Future archaeology should always find the trail.

## Edge cases

- **Spike PR didn't merge.** Fine — the memo / follow-up feature is the disposition artefact, not the spike code itself. PROMOTE: file the new feature, close the spike, abandon the branch. DISCARD: write the memo, close the spike, abandon the branch.
- **Spike's hypothesis was partially confirmed.** Treat the partial confirmation as PROMOTE — file the [Feature] for the part that worked; cover the part that didn't in the "What is NOT being carried over" section. Don't try to split the disposition.
- **Multiple spikes feeding one feature.** PROMOTE each spike individually with the same target [Feature] title; the feature ticket's body lists all promoting spikes in the "Spike findings" section.
