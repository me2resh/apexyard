# Controlled Technical Writing Profile

> ApexYard will require one controlled technical writing profile for each new
> or changed durable artifact. Reviewers will reject artifacts that fail the
> profile. The framework will not rewrite existing artifacts or claim standard
> compliance.

## Context

ApexYard used two writing modes. Durable artifacts used a permissive mode.
That mode allowed long and dense prose in tickets, PR bodies, reviews, designs,
and AgDRs.

The operator requires clear technical writing for all new artifacts. The
requirement also applies when ApexYard writes an artifact for a managed project.

A complete controlled-language standard can include a protected dictionary and
formal certification terms. ApexYard does not ship a third-party dictionary or
checker. The framework must use a neutral profile and avoid certification claims.

## Options Considered

| Option | Benefit | Cost |
|---|---|---|
| Keep two writing modes | Keeps the existing policy | Allows dense artifact text |
| Add a style lint only | Catches simple text faults | Cannot judge meaning or vocabulary |
| **Use one controlled technical writing profile with review checks** | Gives all artifact producers one clear rule | Needs reviewer judgment for full compliance |

## Decision

Use one controlled technical writing profile for new and changed durable
artifacts. Apply it in the framework and in managed projects.

The profile requires short complete sentences, active voice, one term for one
meaning, one instruction per sentence, and clear document structure. It keeps
facts and uncertainty.

Each artifact producer must load the profile. Review skills must reject an
artifact that fails the profile. Static tests must confirm that each shipped
skill and template loads the profile when it creates an artifact. Reviewers
must also load the profile.

Do not rewrite existing artifacts. Do not claim formal standard compliance.

## Consequences

- Tickets, PR bodies, reviews, AgDRs, designs, audits, and runbooks use one
  writing profile.
- The framework bridges the profile to Claude Code, pi, Cursor, and managed
  projects.
- Reviews can reject unclear artifact text before merge.
- Static tests detect missing profile instructions. They do not assess prose.
- Existing artifacts remain unchanged.

## Artifacts

- Ticket: me2resh/apexyard#1164
- Rule: .claude/rules/writing-standard.md
