---
id: AgDR-0277
timestamp: 2026-10-26T12:00:00Z
agent: claude-code
model: claude-opus-5-5
session: docs-lint-1898
trigger: user-prompt
status: executed
category: patterns
---

# Shared document lint

> For framework and site documents, use shared rules and a Node lint to keep findings consistent. Accept the limits of heuristic checks.

## Context

The site has a document lint and a rules file.
The framework needs the same checks without site page logic.
This change implements step 1 of issue #1898.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Shell and awk port | Uses shell tools | Does not retain parity with the site |
| Node port | Keeps the site text checks without dependencies | Needs Node 22 or later |
| Extend check-writing-profile.sh | Uses an existing check | Combines separate rule sets and needs a parity port |

## Decision

Chosen: **Node port**, because it keeps the same text checks as the site.

Host one shared rules JSON at `docs/docs-lint-rules.json`.
The site lint reads this file first when its release cache contains it.
Keep the dependency-free Node lint in `bin/docs-lint.mjs`.
Keep path scope in `docs/docs-lint-scope.json`.
Check only skill titles and descriptions in frontmatter.

Use three rollout steps:

1. Report all findings without a merge gate.
2. Apply strict checks to changed lines.
3. Apply strict checks to all lines in scope.

## Consequences

- Both tools can use the same rule data and text checks.
- The first step leaves existing documents intact.
- Passive voice checks can give false findings and miss passive forms.
- Future steps can enforce the rules after review of the findings.

## Artifacts

- Rules: `docs/docs-lint-rules.json`
- Scope: `docs/docs-lint-scope.json`
- Lint: `bin/docs-lint.mjs`
- Tests: `.claude/hooks/tests/test_docs_lint.sh`
- Workflow: `.github/workflows/docs-lint.yml`
- User guide: `docs/docs-lint.md`
