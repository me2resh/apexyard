# Writing Standard — Human-First Artifacts, Plain Machine Text

ApexYard writes three kinds of text. An operator reads status updates in the thread. People read durable artifacts: tickets, PR bodies, AgDRs, PRDs, technical designs, audits, and reports. Agents and hooks read machine-consumed text: hook messages, skill process steps, spawn briefs, and handoff reports. Each kind has a reader, and each reader needs something different.

[`reporting-style.md`](reporting-style.md) already covers the first kind. This rule covers the other two. It is the writing-side sibling of [`evidence-grounding.md`](evidence-grounding.md) (what a claim can say) and [`right-size-ceremony.md`](right-size-ceremony.md) (whether an artifact should exist at all). It never overrides either: clearer wording must not create a stronger claim, and a cleaner template must not become a reason to file a document nobody needs.

## The two modes

| Text class | Examples | Mode |
|------------|----------|------|
| In-thread status | "here's where we landed", blockers, decisions needed | [`reporting-style.md`](reporting-style.md) — unchanged |
| Durable artifacts | tickets, PR bodies, AgDRs, PRDs, technical designs, audits, runbooks, docs | **Flavored** — clear, short, and precise, with voice and uncertainty kept |
| Machine-consumed text | hook block and warn messages, skill process steps, agent spawn briefs, handoff reports, error output | **Strict** — one instruction per sentence, no ambiguity |
| Conversation, creative writing, marketing copy | chat replies, channel scripts, landing pages | Neither. Out of scope. |

Both modes borrow from ASD-STE100 (Simplified Technical English): short sentences, one idea per sentence, active voice, one term for one meaning, and an imperative for each instruction. The framework does not claim certified STE compliance and does not ship or reproduce the STE dictionary. The principles are the tool; the standard itself is not the target.

## Rule 1 — Open with what the reader needs

A durable artifact opens with the four things a reader acts on, before any template body:

| Element | Answers | Example |
|---------|---------|---------|
| **Outcome** | What is true now, or what this delivers | "The merge gate now reads the forge's HEAD, not the local one." |
| **Reason** | Why it matters | "A local file write could no longer fake an approval." |
| **Decision** | What was chosen, when there was a choice | "Chosen: one universal rule instead of per-agent prompt edits." |
| **Next action** | What the reader must do | "Run `/approve-merge 1167` when you are happy with it." |

Write only the elements that exist. A ticket with no decision has no "Decision:" line. Do not write "Decision: none". The opening is prose or a short list, two to five sentences, and it stands on its own for a reader who reads nothing else. The AgDR summary line, a PR's first Summary bullet, an audit's verdict paragraph, and a PRD's Summary section are all this opening.

## Rule 2 — Small required core, conditional sections

The five core templates annotated by this milestone (`prd.md`, `technical-design.md`, and the feature, bug, and task ticket templates) mark each section **Required** or **Conditional** in a guidance comment at the top of the file. Other templates keep their existing guidance until a later change adds this convention. A completed artifact follows three rules:

1. **Required sections are always present.** If a required value is unknown, write `TBD` (per [`evidence-grounding.md`](evidence-grounding.md) § Durable artifacts). Never invent a value to fill the slot.
2. **Conditional sections appear only with real content.** Delete a conditional section that has nothing to say. Do not write "N/A", "None", or leave an empty table.
3. **No placeholder survives.** `[...]`, `{{...}}`, `YYYY-MM-DD`, and the template's guidance comment are all removed or replaced before the artifact is filed.

The reader of a finished artifact sees only sections that carry information. Every heading they scroll past should have been worth the scroll.

## Rule 3 — Strict mode for machine-consumed text

Text that an agent or a hook acts on has no room for interpretation. When you write or change a hook message, a skill process step, a spawn brief, a handoff report, or an agent-file instruction:

1. **One instruction per sentence.** Split "Run the tests and then push if they pass" into two sentences with the condition stated.
2. **Twenty words or fewer per sentence.** Descriptive sentences can reach twenty-five.
3. **Imperative for every instruction.** "Run `/code-review 1167`." Not "The review should be run."
4. **Active voice, present tense.** "The hook blocks the merge." Not "The merge will be blocked by the hook."
5. **One term, one meaning.** Call the approval file "the marker" throughout, not "the marker", "the file", and "the approval" in turn.
6. **Condition before instruction.** "If the marker is missing, run `/code-review`." Not "Run `/code-review` if the marker is missing."
7. **Exact modality.** `must` for a requirement, `must not` for a prohibition, `can` for a possibility. Do not use `should` or `may` in an instruction; the reader cannot tell whether it is optional.
8. **No idioms, contractions, humour, or rhetorical questions.**
9. **Identifiers verbatim.** Paths, SHAs, flags, and command names appear exactly as the reader must type or match them.

A block or warn message follows one order: what was blocked or found, in one line; why, in one sentence; what to do, as imperative steps; where to read more, as a path. Existing machine text is not rewritten in bulk. It migrates to this mode when it is next touched, and production text under `.claude/hooks/*.sh` still takes the Heavy path when it is.

## Rule 4 — Flavored mode for durable artifacts

Durable artifacts are read by people who need clarity and also need the author's judgment. Flavored mode keeps the short-sentence discipline and drops the restrictions that would remove meaning:

**Keep from Strict:** short sentences, one idea per sentence, active voice, plain words over jargon, acronyms expanded on first use, headings that name their content, `must` / `should` / `may` used with their ordinary requirement meanings.

**Do not remove:** hedges that carry evidence state (`may`, `likely`, `unknown`, `reported`), exact names, numbers, versions, and SHAs, the rationale prose in an AgDR's Context and Consequences, and the author's voice in explanation. A rewrite that shortens a sentence and drops its `may` has changed a fact, not a style.

The test for Flavored mode: a domain reader can find the outcome and the next action in the opening, read each section once, and never meet a heading with nothing under it.

## What this rule does not ask for

- It does not ask for Strict mode in conversation, chat replies, commit messages, or marketing copy.
- It does not ask for evidence labels on every sentence.
- It does not ask for a rewrite of the existing hook messages or agent files. New and changed text follows the mode; the backlog migrates when touched.
- It does not ask for a longer template. A template that needs a new section must name the reader who needs it.

If Strict mode removes useful nuance or precision from a human-facing document, the document was in the wrong mode. Move it to Flavored. That is the milestone's own kill criterion, applied per artifact (me2resh/apexyard#1164).

## Self-check before filing a durable artifact or writing machine text

```text
[ ] Does the opening state the outcome and the next action, plus the reason and decision when they exist?
[ ] Is every required section present, and every conditional section either filled or deleted?
[ ] Did any placeholder, "N/A", empty table, or template comment survive?
[ ] For machine-consumed text: one instruction per sentence, imperative, condition first, exact modality?
[ ] For a durable artifact: did shortening a sentence drop a hedge, a number, or a name?
```

## Backstop

This rule is behavioral, the same enforcement shape as `reporting-style.md` and `evidence-grounding.md`. A shell hook cannot tell a clear sentence from an unclear one, and a length or word-list lint would block valid precision and pass empty clarity. Regression cases live at `.claude/rules/tests/fixtures/human-friendly-cases.md`; a static test pins that this rule, its wiring, the template guidance comments, and those cases stay present. It does not score model behavior. Cross-harness evaluation is me2resh/apexyard#1165.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
