---
name: prototype-close
description: Deprecated alias for `/prototype --close`. Closes a prototype via the disposition gate. `--promote` files a [Feature]. `--discard` writes a memo.
argument-hint: "--promote | --discard [<prototype-ticket-number>]"
allowed-tools: Bash, Read, Write
---

Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.

# /prototype-close — Deprecated Alias for `/prototype --close`

`/prototype-close` is deprecated (me2resh/apexyard#2028). Use `/prototype --close`.
This alias ships deprecated in v5.11.0. v5.12.0 removes it.
Permissions follow the skill that runs. If your settings allow `Skill(prototype-close)`, also allow `Skill(prototype)`.

## Usage

```
/prototype-close --promote 142     # same as /prototype --close --promote 142
/prototype-close --discard         # same as /prototype --close --discard
```

## Process

1. Print this note to the operator first:

   ```
   Note: /prototype-close is deprecated. Use /prototype --close --promote|--discard [ticket].
   v5.12.0 removes the alias. A Skill(prototype-close) permission now needs Skill(prototype).
   ```

2. Read `../prototype/close.md` from this skill's directory. Under the ops root, that file is `.claude/skills/prototype/close.md`.
3. Follow that file with `--close $ARGUMENTS` as the arguments. The behaviour, markers, and memo paths are the same as `/prototype --close`.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
