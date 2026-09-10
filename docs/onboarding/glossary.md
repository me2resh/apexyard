# ApexYard Plain-Language Glossary

Five common SDLC terms explained in one to three plain-language sentences
each. This is the **single shared asset** used by three surfaces: `/onboard`
shows one term at a time, `/tutorial` renders the full glossary, and
`.claude/rules/glossary-lookup.md` provides on-demand lookup. See
`docs/technical-designs/onboarding-increment-2.md` § D1 (AgDR-0100).

**Read contract** — consumers rely on this exact shape. Keep it when you edit
an entry:

- One term per stable `###` heading.
- The heading's very first line is a greppable key comment
  `<!-- term: <key>[,<key>...] -->` — comma-separated surface spellings
  that all resolve to the same entry (e.g. "issue" and "ticket" both map
  to the first section below).
- Body: 1–3 plain-language sentences. Define any necessary technical term
  in the same entry, unless it is one of these five terms (D6 — Consistency).
- `/tutorial` renders the whole file, top to bottom, unchanged. The other
  consumers select one section by its `term:` key. They do not copy or
  paraphrase this text elsewhere.

---

## Terms

### issue / ticket

<!-- term: issue,ticket -->

A ticket (GitHub calls it an "issue") is a tracked piece of work with its own
number, such as `#42`. The ticket holds the request, its discussion, and the
PR that delivers the change, so the team can find the context later.

**Example**: `/feature` files a ticket as a GitHub page that you can open,
comment on, and reference by number.

### PR (pull request)

<!-- term: pr -->

A PR is a proposed code change packaged for review before it becomes part of
the project. It shows the line-by-line changes and explains what they do and
why they are needed.

**Example**: finishing a ticket opens a PR. Its changes do not reach the main
codebase until the PR is reviewed and merged.

### merge

<!-- term: merge -->

Merging folds a PR's changes into the main codebase. It happens only after an
automated reviewer and a human have approved the exact version being merged.

**Example**: `gh pr merge` is blocked until both approvals match the PR's
current commit. A new commit requires fresh approval.

### branch

<!-- term: branch -->

A branch is a separate line of the code where a change can be built and
tested without changing the shared version. When the work is ready, a PR
asks to bring it back into the main line.

**Example**: a ticket may use a branch such as `feature/#42-add-login`, which
keeps the in-progress work isolated until review.

### CI (continuous integration)

<!-- term: ci -->

CI is an automated check that runs when a PR is opened or updated. It builds
the code, runs tests, and reports pass or fail. A PR with a failing CI check
("red CI") cannot be merged.

**Example**: pushing a new commit to an open PR starts CI again, so the fix
is checked before the next review.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
