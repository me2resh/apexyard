---
name: spike-close
description: Deprecated alias for `/spike --close`. Closes a spike via the disposition gate. `--promote` files a [Feature]. `--discard` writes a memo.
argument-hint: "--promote | --discard [<spike-ticket-number>]"
allowed-tools: Bash, Read, Write
---

Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.

# /spike-close: Deprecated Alias for `/spike --close`

`/spike-close` is deprecated (me2resh/apexyard#2028). Use `/spike --close`.
This alias ships deprecated in v5.11.0. v5.12.0 removes it.
This alias reads a file. It does not run `/spike`, so `Skill(spike-close)` is enough for the alias. The new command `/spike --close` runs `/spike` and needs `Skill(spike)`.

## Usage

```
/spike-close --promote 142     # same as /spike --close --promote 142
/spike-close --discard         # same as /spike --close --discard
```

## Process

1. Print this note to the operator first:

   ```
   Note: /spike-close is deprecated. Use /spike --close --promote|--discard [ticket].
   v5.12.0 removes the alias. The new command needs a Skill(spike) permission.
   ```

2. Read the mode file in this table. Use the ops-root path, or the path relative to this skill's directory:

   <!-- skill-modes:alias (test_skill_modes_2028.sh reads this table) -->
   | Mode file (under the ops root) | Relative to this skill's directory | Arguments to pass |
   |--------------------------------|------------------------------------|-------------------|
   | `.claude/skills/_lib-modes/spike-close.md` | `../_lib-modes/spike-close.md` | `--close $ARGUMENTS` |

3. Follow that file with the arguments in the table. The behaviour, markers, and paths are the same as `/spike --close`.

This alias does not read `/spike`. It works when an adopter overrides `/spike` with `custom-skills/spike/`.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*
