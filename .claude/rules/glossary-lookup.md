# Glossary Lookup — Answer "What's a `<term>`?" in Any Session

ApexYard ships a plain-language glossary at `docs/onboarding/glossary.md`, five core SDLC terms (issue/ticket, PR, merge, branch, CI) explained in one to three jargon-free sentences each. Increment 2's teach-in-context asides (see [`workflows/sdlc.md`](../../workflows/sdlc.md) and `docs/technical-designs/onboarding-increment-2.md` § D3) surface these terms *proactively*, the first time a guided-mode adopter meets one, inside `/onboard`. This rule is the **reactive sibling**: an adopter can ask about a term at any point, in any session, regardless of which skill (if any) is running, and get the same plain-language answer.

This rule is the **on-demand lookup** described in the technical design § D4 (FR-8). This "any session, any active skill" affordance cannot come from a named `/glossary` command, because a command has to be invoked. This needs to fire on a plain-language question dropped mid-conversation.

## The rule

**When an adopter asks the meaning of one of the five core terms, use this rule. Questions include "what's a `<term>`?", "what does `<term>` mean?", "what is a `<term>`?" The terms are `issue`/`ticket`, `PR`/`pull request`, `merge`, `branch`, or `CI`/`continuous integration`. Resolve the term from `docs/onboarding/glossary.md`. Answer in plain language, in the current depth mode's verbosity, then resume whatever was happening before the question.**

Concretely:

1. **Locate the term.** Read `docs/onboarding/glossary.md` and slice the section whose `<!-- term: ... -->` key comment matches the asked-about word. Comma-separated surface spellings map to one entry: "issue" and "ticket" both resolve to the same section.
2. **Answer from that entry, not from memory.** The glossary is the single source of truth for three surfaces: `/onboard`'s asides, `/tutorial`'s full render, and this rule. Do not paraphrase the concept from general knowledge; use the file's own wording so the three surfaces never drift apart or contradict each other.
3. **Respect the current depth mode's verbosity, but never withhold the answer.** If `.claude/session/onboarding-depth-mode` is set (see `_lib-onboarding-depth-mode.sh`), a terse-mode adopter gets the compact definition; a guided-mode adopter gets the same definition plus the entry's "why this matters" framing if present. This is a **solicited** question. The adopter asked, so depth mode only tunes tone. It never suppresses the answer the way it gates the *unsolicited* asides in `/onboard`.
4. **Resume where the conversation was.** Answer the question, then continue whatever skill or task was in progress. Do not treat the lookup as a mode switch or a detour that needs its own wrap-up.
5. **If the term is not one of the five**, answer normally from general knowledge (or say you are not sure). This rule only governs the five terms the shared glossary defines; it does not block answering other questions.

## When to apply this (proactively)

Heuristic: apply this rule any time an adopter's message reads as a definitional question about one of the five terms. Examples include "what's a merge?", "what does PR mean?", "I don't know what a branch is", regardless of:

- **Which skill is active**: mid-`/handover`, mid-`/setup`, mid-nothing-at-all. The whole point of an ambient rule (versus a `/glossary` command) is that it does not need the adopter to know a command exists.
- **Whether onboarding has run at all**: a fork that never ran `/onboard` still has `docs/onboarding/glossary.md`. The lookup does not depend on any session marker being set.

## When NOT to apply this

- **The adopter is asking about a term outside the five** ("what's a webhook?", "what's a rebase?"): answer normally. This rule's read-contract only covers the glossary's five entries. Do not force an answer that is not in the file.
- **The adopter is asking a deeper "how does X actually work" question, not "what does X mean"**. For example, "walk me through how the merge gate checks approvals" wants the real mechanism (`.claude/rules/pr-workflow.md`), not the one-paragraph glossary gloss. Answer from the real mechanism; the glossary is a vocabulary primer, not documentation.
- **A `/tutorial` run is already rendering the full glossary**: that is the solicited full-render path (design § D5), not a single-term lookup. Do not duplicate the render mid-`/tutorial`.

## Self-check before responding

Before answering a question in any session, scan it for:

```
[ ] Does the question ask "what's a <term>?" / "what does <term> mean?" for one of the five glossary terms?
[ ] Did I answer from docs/onboarding/glossary.md's own wording, not from memory?
[ ] Did I respect depth mode's verbosity without withholding the answer (solicited ≠ gated)?
[ ] Did I resume the prior context afterward instead of treating this as a mode switch?
```

If the first box is checked and the second isn't, re-answer from the file before responding.

## Backstop

This rule is **advisory self-discipline only**, the same enforcement shape as [`reporting-style.md`](reporting-style.md) and [`plan-mode.md`](plan-mode.md). A shell hook cannot see a plain-language question inside assistant prose and cannot inject an inline aside into the response. See the technical design § D3's rejection of a hook-based approach for the same reason. Thus, there is no mechanical gate here, by design. The honest limit is stated in the technical design itself (§ D4): "enforcement is self-discipline (advisory), the same shape as the framework's other prose-behaviour rules." A `/glossary <term>` skill was considered and rejected (see the design's Open Questions) precisely because a command is the wrong ergonomics for a lookup that should fire the instant the question is asked, without the adopter needing to know a command exists.

The cost of checking the five-term list before answering is a glance at one file. The cost of silently reasoning through a definition from memory is a guided-mode adopter getting an answer that quietly diverges from what `/onboard`'s asides and `/tutorial`'s full render already told them.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*
