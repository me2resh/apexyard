---
name: prototype-close
description: Deprecated alias for `/prototype --close`. Closes a prototype via the disposition gate. `--promote` files a [Feature]. `--discard` writes a memo.
argument-hint: "--promote | --discard [<prototype-ticket-number>]"
allowed-tools: Bash, Read, Write
---

Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.

# /prototype-close: Deprecated Alias for `/prototype --close`

`/prototype-close` has deprecated status (me2resh/apexyard#2028). Use `/prototype --close`.
This alias ships deprecated in v5.11.0. v5.12.0 removes it.
This alias reads a file. It does not run `/prototype`, so `Skill(prototype-close)` is enough for the alias. The new command `/prototype --close` runs `/prototype` and needs `Skill(prototype)`.

## Usage

```
/prototype-close --promote 142     # same as /prototype --close --promote 142
/prototype-close --discard         # same as /prototype --close --discard
```

## Process

1. Print this note to the operator first:

   ```
   Note: /prototype-close is deprecated. Use /prototype --close --promote|--discard [ticket].
   v5.12.0 removes the alias. The new command needs a Skill(prototype) permission.
   ```

2. Read the mode file in this table. Use the ops-root path, or the path relative to this skill's directory:

   <!-- skill-modes:alias (test_skill_modes_2028.sh reads this table) -->
   | Mode file (under the ops root) | Relative to this skill's directory | Arguments to pass |
   |--------------------------------|------------------------------------|-------------------|
   | `.claude/skills/_lib-modes/prototype-close.md` | `../_lib-modes/prototype-close.md` | `--close $ARGUMENTS` |

3. Follow that file with the arguments in the table. The behaviour, markers, and paths are the same as `/prototype --close`.

This alias does not read `/prototype`. It works when an adopter overrides `/prototype` with `custom-skills/prototype/`.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*
