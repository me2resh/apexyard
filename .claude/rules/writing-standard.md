# Controlled Technical Writing Profile

Use this rule when you create or change a durable artifact. This rule applies to
tickets, PR bodies, review comments, AgDRs, designs, audits, runbooks, and
project documents. It applies in the framework and in every project that
ApexYard manages.

Use this controlled technical writing profile. The profile makes technical text
easy to read and hard to misunderstand. It does not apply to conversation or
marketing copy.

This profile uses clear technical-writing rules. It does not implement or claim
compliance with a third-party controlled-language standard or dictionary. Use
the project's approved technical terms.

## Required profile

1. Use one term for one item or action. Define a technical term before its
   first use.
2. Use short, complete sentences. Use no more than 20 words for an instruction
   and 25 words for descriptive text.
3. Give one instruction in each sentence.
4. Use active voice. Use passive voice only when the actor is unknown or does
   not matter.
5. Use a verb for an action. Do not use noun forms of verbs when a verb is
   available.
6. Do not use a phrasal verb when one clear verb is available.
7. Do not use a semicolon.
8. Use a list for a sequence, condition set, or complex group.
9. Keep each paragraph on one topic. Use no more than six sentences in a
   paragraph.
10. State the outcome first. State the reason, decision, and next action when
    they exist.
11. Keep facts, limits, uncertainty, numbers, versions, identifiers, and
    modality. Clear text must not change the evidence.
12. Delete empty conditional sections. Remove placeholders before you file an
    artifact.

Use the project's approved terms for product names, API names, code identifiers,
and other technical names. Add a short glossary when a reader can misunderstand
a technical term.

## Artifact checks

Before you file an artifact, check each item:

    [ ] Is each sentence complete and within the word limit?
    [ ] Does each sentence state one action or one fact?
    [ ] Does each term have one meaning?
    [ ] Does the artifact use active voice where the actor matters?
    [ ] Does the opening state the outcome and next action?
    [ ] Did the rewrite retain all evidence and uncertainty?
    [ ] Did you remove empty sections and placeholders?

A reviewer must request changes when an artifact does not meet this profile.
The review must name the failed rule and show a clear replacement.

## Review and test scope

Artifact producers must load this rule before they write. Review skills must
check this rule before they approve. Regression cases test the producer and
reviewer wiring. Static checks cannot prove vocabulary, meaning, or voice.

## What this rule does not change

This rule does not rewrite existing artifacts. It applies when an agent creates
or changes an artifact after this rule takes effect. This rule does not apply
to chat messages unless the user asks for it.
