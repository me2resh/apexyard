---
name: spike-close
description: Deprecated alias for `/spike --close`. Closes a spike via the disposition gate. `--promote` files a [Feature]. `--discard` writes a memo.
argument-hint: "--promote | --discard [<spike-ticket-number>]"
allowed-tools: Bash, Read, Write
---

Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.

# /spike-close — Deprecated Alias for `/spike --close`

`/spike-close` is deprecated (me2resh/apexyard#2028). Use `/spike --close`.
This alias ships deprecated in v5.11.0. v5.12.0 removes it.
Permissions follow the skill that runs. If your settings allow `Skill(spike-close)`, also allow `Skill(spike)`.

## Usage

```
/spike-close --promote 142     # same as /spike --close --promote 142
/spike-close --discard         # same as /spike --close --discard
```

## Process

1. Print this note to the operator first:

   ```
   Note: /spike-close is deprecated. Use /spike --close --promote|--discard [ticket].
   v5.12.0 removes the alias. A Skill(spike-close) permission now needs Skill(spike).
   ```

2. Read `../spike/close.md` from this skill's directory. Under the ops root, that file is `.claude/skills/spike/close.md`.
3. Follow that file with `--close $ARGUMENTS` as the arguments. The behaviour, markers, and memo paths are the same as `/spike --close`.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
