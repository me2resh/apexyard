---
name: apexyard-workflow
description: Use when starting work on a ticket, creating a PR, or merging. Enforces apexyard conventions: branch creation, commit format, PR workflow, code review, merge gate. TRIGGER on any ticket work, PR creation, or merge attempt.
---

# Apexyard Workflow for OpenCode

This skill enforces the apexyard SDLC workflow. Follow it EXACTLY when working on any ticket.

## Before any code edit

1. **Verify you're on a feature branch** — run `git branch --show-current`. If on `main`, STOP and create a branch: `git checkout -b {type}/{TICKET-ID}-{description}`.
2. **Verify the ticket exists** — `gh issue view <N> --repo <owner/repo>`. If it doesn't exist, create it first.

## Before git push

3. **Run CI checks**: `npm run lint && npm run typecheck && npm run test`
4. **Stage specific files only**: `git add <file>` (NEVER `git add -A` or `git add .`)
5. **Commit with proper format**: `type: subject` body with `Closes #N`
6. **Push**: `git push`
7. **Create PR**: `gh pr create` with title `type(TICKET): description` and body with Glossary section

## Code review

8. **Invoke Rex**: use the `code-review` skill or load `.opencode/agents/rex.md` via Task tool
9. **Never write review markers yourself** — Rex writes `*-rex.approved`; the user/CEO writes `*-ceo.approved` via explicit approval
10. **Wait for explicit merge approval** — only merge on explicit per-PR user "approved"

## If working on a managed project (workspace/<name>/)

11. **Ensure githooks are active**: `git config core.hooksPath .githooks`
