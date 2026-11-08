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

## Procedure for /approve-merge step 4b

Run before step 5 writes the CEO marker. Reuse `MARKER_HOME` and `PR_HOST_REPO` from step 4.

```bash
QUIZ_FLAG=""
case " $ARGUMENTS " in *" --quiz "*) QUIZ_FLAG="--quiz" ;; esac
QUIZ_ON=$(bash "$MARKER_HOME/.claude/skills/approve-merge/scripts/approval-quiz.sh" should-run "$MARKER_HOME" $QUIZ_FLAG) || exit 1
```

When `QUIZ_ON` is `no`, skip the rest of this step.

When `QUIZ_ON` is `yes`:

1. Fetch the PR diff and body for `$PR_HOST_REPO` / `<pr>`.
   Write them to temp files. Do not invent facts outside those files.
2. Build the evidence pack (file:line anchors from the unified diff, plus the PR body):

```bash
DIFF_FILE=$(mktemp) || exit 1
BODY_FILE=$(mktemp) || exit 1
gh pr diff <pr> --repo "$PR_HOST_REPO" > "$DIFF_FILE" || exit 1
gh pr view <pr> --repo "$PR_HOST_REPO" --json body -q '.body' > "$BODY_FILE" || exit 1
PACK_FILE=$(mktemp) || exit 1
bash "$MARKER_HOME/.claude/skills/approve-merge/scripts/approval-quiz.sh" pack "$DIFF_FILE" "$BODY_FILE" > "$PACK_FILE" || exit 1
```

3. Ask exactly three comprehension-check questions with `AskUserQuestion`. Each question must name a file and a line from the pack. Ground every option in the pack or the PR body. Never ask about a fact that is not in the diff or the ticket body. Prefer `approval-quiz.sh sample-questions` as the question source when it returns three items.
4. On a wrong answer, run `approval-quiz.sh show-lines` for that file and line, show those lines to the user, and ask the same question again. Do not write the CEO marker until all three answers are correct.

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
