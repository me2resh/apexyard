# ApexYard Plain-Language Glossary

Five core SDLC terms explained in one to three plain-language sentences
each — no jargon used to define another piece of jargon. This is the
**single shared asset** three surfaces read from, never duplicated: the
just-in-time asides in `/onboard` (guided mode, one term at a time), the
full re-entry render in `/tutorial`, and the any-session on-demand lookup
(`.claude/rules/glossary-lookup.md`). See
`docs/technical-designs/onboarding-increment-2.md` § D1 (AgDR-0100).

**Read contract** — every consumer of this file relies on this exact
shape, so keep it if you edit an entry:

- One term per stable `###` heading.
- The heading's very first line is a greppable key comment
  `<!-- term: <key>[,<key>...] -->` — comma-separated surface spellings
  that all resolve to the same entry (e.g. "issue" and "ticket" both map
  to the first section below).
- Body: 1–3 plain-language sentences. No word inside a definition may be
  jargon unless it is inlined right there or is itself one of these five
  terms (D6 — Consistency).
- `/tutorial` renders the whole file, top to bottom, unchanged. The
  just-in-time asides and the on-demand lookup slice exactly one section
  by its `term:` key. No consumer ever re-types or paraphrases this prose
  elsewhere.

---

## Terms

### issue / ticket

<!-- term: issue,ticket -->

A ticket (GitHub calls it an "issue") is a tracked to-do item with its own
number, like `#42`. It's where the team writes down what needs to happen,
follows the discussion, and links the pull request that eventually does
the work — so anyone can look up "what was #42 about?" months later.

**Example**: when `/feature` files a ticket for you, it's a real page on
GitHub you can open, comment on, and refer back to by that number.

### PR (pull request)

<!-- term: pr -->

A PR is a proposed change to the code, packaged up for review before it
becomes part of the project. It shows exactly what would change (line by
line) alongside a description of what and why, so a reviewer can decide
whether it's safe to bring in.

**Example**: finishing a ticket's work opens a PR; nothing from it reaches
the main codebase until that PR is reviewed and merged.

### merge

<!-- term: merge -->

Merging is the moment a PR's changes are actually folded into the main
codebase — the point of no casual return. Because of that, a merge only
happens after both an automated reviewer and a human have explicitly
approved that exact version of the change; nothing merges on a vague
"looks good, go ahead."

**Example**: `gh pr merge` is blocked until the two approvals above both
match the PR's current state — a fresh commit after approval means
approving again first.

### branch

<!-- term: branch -->

A branch is a parallel, separate copy of the code where a change can be
built and tested without touching the version everyone else is using. Once
the work on a branch is ready, it becomes a PR asking to bring those
changes back into the main line.

**Example**: starting a ticket creates a branch named after it (like
`feature/#42-add-login`), so the in-progress work stays isolated until
it's reviewed.

### CI (continuous integration)

<!-- term: ci -->

CI is an automated check that runs every time a PR is opened or updated —
it builds the code, runs the tests, and reports back pass or fail before
any human review even starts. A PR with a failing CI check ("red CI")
never gets merged, regardless of how small the change looks.

**Example**: pushing a new commit to an open PR re-runs CI automatically,
so a fix you just made gets verified before anyone re-reviews it.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
