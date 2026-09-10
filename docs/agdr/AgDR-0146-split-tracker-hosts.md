# Split issue and review tracker hosts

> In the context of projects that track issues and code reviews in different systems, facing a single tracker adapter axis, I decided to resolve issue and review adapters independently to support mixed-host projects without breaking existing configurations, accepting a small compatibility layer in the tracker library and configuration docs.

## Context

`tracker.kind` currently selects both issue operations and code-review operations. This forces a Jira-issues and GitLab-reviews project into an inaccurate or custom configuration. The change crosses the shared tracker library and every review-host resolver, so it is a framework-level integration decision.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| Keep one `tracker.kind` and require custom commands | No code change | Mixed-host projects remain second-class and easy to misconfigure |
| Add `tracker.issue_kind` and `tracker.review_kind`, with legacy fallback | Independent routing, backward compatible, incremental adapter support | Adds two resolution paths and documentation burden |
| Add a separate top-level review-host object | Clear long-term model | Larger schema migration and more compatibility work than this issue requires |

## Decision

Chosen: **two tracker kind fields with legacy fallback**. Issue reads and writes resolve `issue_kind`; review submission, merge, SHA checks, and forge detection resolve `review_kind`. When either new field is absent, `tracker.kind` supplies the value for that axis.

## Consequences

- Existing projects retain their current behavior without configuration changes.
- A project can declare Jira or Linear issues with GitHub or GitLab reviews.
- Adapter-specific commands remain unchanged; this change only routes each operation to the correct existing adapter.
- A later change can add richer per-axis command templates without changing the basic resolution contract.

## Artifacts

- Issue: https://github.com/me2resh/apexyard/issues/1225
