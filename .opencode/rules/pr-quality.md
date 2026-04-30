# PR Quality Requirements

## Glossary (MANDATORY)

Every PR description **must** include a Glossary section:

```markdown
## Glossary
| Term | Definition |
|------|------------|
| ... | ... |
```

If missing → the Code Reviewer agent requests changes. No exceptions.

**Why a glossary?** Every PR is a learning opportunity. Explaining terms helps junior engineers learn from senior work, helps senior engineers articulate their thinking, helps future readers understand decisions, and builds shared vocabulary across the team.

## Commit SHA Verification

Before merge, verify that the Code Reviewer's approved commit matches the current HEAD:

```
[ ] Code Reviewer approved commit: <sha>
[ ] Current HEAD commit:           <sha>
[ ] Match? YES → merge.  NO → re-request review.
```

This prevents merging code that was pushed after the last review.

## Design Review (UI Changes)

If the PR touches user-facing UI → design review is required before merge. Mechanically enforced by `require-design-review-for-ui.sh` (blocks merge without a design marker) and the `/approve-design <pr>` skill (writes the marker on explicit designer approval). See `.claude/skills/approve-design/SKILL.md` for the full invocation rules.

## QA Gate Checklist

Before moving a ticket to Done:

```
[ ] All acceptance criteria verified
[ ] Test coverage > 80% for new code
[ ] Integration tests pass
[ ] E2E critical paths pass
[ ] No open Critical/High bugs
[ ] Performance within targets
[ ] Security scan clean
```

## No Red CI Before Merge

**Never** merge with red CI — even if the failure is pre-existing or unrelated. Fix the pre-existing issue first (separate commit), rebase the PR so all checks are green, and only then merge.
