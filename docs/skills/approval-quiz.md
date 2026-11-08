# Approval quiz (comprehension check)

Opt-in check that the operator understood a PR before `/approve-merge` writes the CEO marker. Shared by `/approve-merge --quiz` and `/explain-pr`.

## Rules

- The quiz runs only when `--quiz` is passed or `merge.approval_quiz` is `true`.
- Default is off. The quiz does not run and never blocks a merge in any other mode.
- The marker format, approval record, and merge-gate hooks stay unchanged.
- Ask exactly three questions with `AskUserQuestion`.
- Each question names a file and a line from the PR diff.
- Every option must come from the evidence pack or the PR body.
- Never ask about a fact that is not in the diff or the ticket body.
- On a wrong answer, show the packed lines for that file and line, then ask again.
- Write no marker and run no merge from this procedure alone.

## Helper

```bash
bash "$MARKER_HOME/.claude/skills/approve-merge/scripts/approval-quiz.sh" should-run "$MARKER_HOME" [--quiz]
bash "$MARKER_HOME/.claude/skills/approve-merge/scripts/approval-quiz.sh" pack <diff-file> <body-file>
bash "$MARKER_HOME/.claude/skills/approve-merge/scripts/approval-quiz.sh" sample-questions <pack-json>
bash "$MARKER_HOME/.claude/skills/approve-merge/scripts/approval-quiz.sh" show-lines <pack-json> <file> <line>
```

`should-run` prints `yes` or `no`. It reads `merge.approval_quiz` through `_lib-read-config.sh`.

## Config

Set in `.claude/project-config.json`:

```json
{
  "merge": {
    "approval_quiz": true
  }
}
```

Shipped default in `.claude/project-config.defaults.json` is `false`.

## Glossary

| Term | Definition |
|------|------------|
| Comprehension check | Questions that show the approver understood the change before approving it. |
