---
name: tickets-batch
description: Deprecated alias for `/task --batch`. Files 2 to 20 structured tickets in one shared-context flow.
argument-hint: "<optional bulk description>"
allowed-tools: Bash, Read, Write, AskUserQuestion
---

Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.

# /tickets-batch: Deprecated Alias for `/task --batch`

`/tickets-batch` is deprecated (me2resh/apexyard#2028). Use `/task --batch`.
This alias ships deprecated in v5.11.0. v5.12.0 removes it.
This alias reads a file. It does not run `/task`, so `Skill(tickets-batch)` is enough for the alias. The new command `/task --batch` runs `/task` and needs `Skill(task)`.

## Usage

```
/tickets-batch                                      # same as /task --batch
/tickets-batch ./backlog-batches/auth-refactor.md   # same as /task --batch ./backlog-batches/auth-refactor.md
```

## Process

1. Print this note to the operator first:

   ```
   Note: /tickets-batch is deprecated. Use /task --batch [file-or-description].
   v5.12.0 removes the alias. The new command needs a Skill(task) permission.
   ```

2. Read the mode file in this table. Use the ops-root path, or the path relative to this skill's directory:

   <!-- skill-modes:alias (test_skill_modes_2028.sh reads this table) -->
   | Mode file (under the ops root) | Relative to this skill's directory | Arguments to pass |
   |--------------------------------|------------------------------------|-------------------|
   | `.claude/skills/_lib-modes/task-batch.md` | `../_lib-modes/task-batch.md` | `--batch $ARGUMENTS` |

3. Follow that file with the arguments in the table. The behaviour, markers, and paths are the same as `/task --batch`.

This alias does not read `/task`. It works when an adopter overrides `/task` with `custom-skills/task/`.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*
