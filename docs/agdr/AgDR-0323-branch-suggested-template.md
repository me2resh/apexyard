---
id: AgDR-0323
timestamp: 2026-11-24T12:00:00Z
agent: platform-engineer
model: claude-sonnet-5-5
session: n/a
trigger: user-prompt
status: executed
category: tooling
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# A configurable template builds the suggested branch name

> In the context of `/start-ticket` suggesting a branch name that differs from the name a tracker such as Jira creates (issue #2083), facing a name builder that lived in prose and in two shell programs, I decided to add one shared helper and an optional `.branch.suggested_template` key, to let adopters get tracker-native names without a fork, accepting a new config contract that is hard to change once adopters use it.

## Context

`/start-ticket` suggested `<type>/<TICKET-ID>-<slug>` with the slug capped at 40 characters.
Jira's **Create branch** action names a branch `<KEY>-<number>-<summary-slug>`, and that name keeps the branch linked to the ticket.
An adopter had no way to make `/start-ticket` suggest that name.
Three places built a name: the skill prose, `bin/apexyard-start-ticket`, and `bin/apexyard start`.
Two of them gave different types for the same title.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep prose and add a second prose rule | No new code | Not testable. The agent assembles the name by hand. The headless route would not follow it |
| Per-tracker built-in shapes | No config for the adopter | Each new tracker needs a framework release |
| One helper with an optional template key | One tested builder. Any tracker shape. Default unchanged | A new config contract with a token grammar |

## Decision

Chosen: **one helper with an optional template key**, because it is the only option that is testable and works for every tracker.

- `.claude/hooks/_lib-branch-suggest.sh` holds `branch_suggest <id> <title> [type]`.
- `bin/apexyard-start-ticket` calls it with the title it already holds. The title never goes on a command line.
- `.branch.suggested_template` is empty by default. An empty key returns `<type>/<TICKET-ID>-<slug>` with a 40-character slug cap.
- Tokens are `{type}`, `{id}` and `{title_slug}`. `{title_slug}` has no length cap, because the point of a tracker-native name is to match the tracker's own slug.
- An unknown token, or a rendered name that is not a valid git ref, writes a warning to stderr and returns the built-in shape. The suggestion is not a gate, so a typo must not stop a ticket from starting.
- The type map grows from four prefixes to ten, and the stopword list is wider. Some titles now give a different name than before (`[Bug]` gives `fix`, `[Refactor]` gives `refactor`).

## Consequences

- A template that makes a tracker-native name needs a matching `.branch.extra_patterns` entry, or `validate-branch-name.sh` blocks the push (issue #2083, part 1).
- `bin/apexyard start` still has its own builder. A follow-up ticket moves it to the helper.
- Adopters who set the key own the result. The framework checks only that the name is a valid ref.

## Artifacts

- Issue me2resh/apexyard#2083
- PR me2resh/apexyard#2126
