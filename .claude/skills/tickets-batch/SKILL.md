---
name: tickets-batch
description: Deprecated alias for `/task --batch`. Files 2 to 20 structured tickets in one shared-context flow.
argument-hint: "<optional bulk description>"
allowed-tools: Bash, Read, Write, AskUserQuestion
---

Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.

# /tickets-batch — Deprecated Alias for `/task --batch`

`/tickets-batch` is deprecated (me2resh/apexyard#2028). Use `/task --batch`.
This alias ships deprecated in v5.11.0. v5.12.0 removes it.
Permissions follow the skill that runs. If your settings allow `Skill(tickets-batch)`, also allow `Skill(task)`.

## Usage

```
/tickets-batch                                      # same as /task --batch
/tickets-batch ./backlog-batches/auth-refactor.md   # same as /task --batch ./backlog-batches/auth-refactor.md
```

## Process

1. Print this note to the operator first:

   ```
   Note: /tickets-batch is deprecated. Use /task --batch [file-or-description].
   v5.12.0 removes the alias. A Skill(tickets-batch) permission now needs Skill(task).
   ```

2. Read `../task/batch.md` from this skill's directory. Under the ops root, that file is `.claude/skills/task/batch.md`.
3. Follow that file with `--batch $ARGUMENTS` as the arguments. The behaviour is the same as `/task --batch`: mixed ticket types, the 2 to 20 limit, one batch confirmation, and partial-failure handling.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
