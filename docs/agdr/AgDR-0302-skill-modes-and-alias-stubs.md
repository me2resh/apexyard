---
id: AgDR-0302
timestamp: 2026-11-14T12:00:00Z
agent: tech-lead
model: claude-opus-5-5
session: n/a
trigger: user-prompt
status: executed
category: patterns
---

# Fold close and batch skills into modes, with alias stubs

> In the context of three skills that only extend a sibling skill (`/spike-close`, `/prototype-close`, `/tickets-batch`), facing overlap in the skill list and a 16,000-byte cap on `/task`, I decided to make them modes of the sibling skill (`/spike --close`, `/prototype --close`, `/task --batch`), to keep each mode body in a supporting file in the sibling skill directory, and to keep the old names as alias stubs for one release, to achieve a smaller skill surface without a lost capability or a broken command, accepting that the skill count stays at 72 until the stubs are removed.

## Context

- Issue me2resh/apexyard#2028 asks to fold the three skills into modes, and to keep the old commands as alias stubs for one release.
- `test_skill_shared_blocks.sh` caps `/task` SKILL.md at 16,000 bytes. The `/tickets-batch` body is about 18,000 bytes. It cannot go inline.
- Claude Code loads a skill's SKILL.md on invocation. Other files in the skill directory load only when the skill tells the agent to read them.
- `bin/extract-subpacks.sh` copies the sibling files of a skill directory. Supporting files travel with the skill.
- The harness lists every directory under `.claude/skills/` as a command. A stub directory keeps the old command name working.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Mode body inline in the sibling SKILL.md | One file for each skill | `/task` exceeds the 16,000-byte cap. Every `/spike` and `/task` run loads the close or batch text that it does not use. |
| B. Mode body in a supporting file (`close.md`, `batch.md`) in the sibling skill directory; the old skill becomes a stub that loads the same file | The default path stays small. One copy of each mode body. The stub and the mode cannot drift. `git mv` keeps the file history. | The agent must follow a file reference. Readers look in two files for one skill. |
| C. Mode body in `docs/skills/` | Same as B | The body leaves the skill directory, so subpack extraction and skill-local tests do not find it. |
| D. Remove the old commands now | Smallest list | Breaks every operator habit and every document that names the old commands. The issue forbids it. |

## Decision

Chosen: **B**, because it keeps the default path of `/spike`, `/prototype`, and `/task` small. It also keeps one copy of each mode body, and every old command keeps working.

- `/spike` and `/prototype` check `$ARGUMENTS` for `--close` before step 0. Close mode reads `close.md` and does not write the active-issue-skill marker. This is the same as the old close skills.
- `/task` checks `$ARGUMENTS` for `--batch` before step 0. Batch mode reads `batch.md`. The new `--project`, `--priority`, `--parent`, and `--labels` flags prefill the shared questions. They never skip a confirmation.
- Each alias stub prints a deprecation note and loads the same mode file with the mode flag added.
- The skill count stays at 72. The skill list marks the three stubs as deprecated aliases. The next release deprecates the stubs, and the release after that removes them.
- Every quoted skill count is now a computed check (`test_skill_modes_2028.sh`, the `/geo-audit` and `/codify-rule` smoke tests) or a pointer to `docs/claude-md-reference.md`.

## Consequences

- Removing a stub later is a delete of one directory, a row in the skill list, and the count. `test_skill_modes_2028.sh` then needs its stub section removed.
- `/launch-check` names and offers a full audit for each WARN or FAIL row, including `/audit-deps` and `/security-review`. It never runs an audit without a yes.

## Artifacts

- me2resh/apexyard#2028
- `.claude/skills/spike/close.md`, `.claude/skills/prototype/close.md`, `.claude/skills/task/batch.md`
- `.claude/hooks/tests/test_skill_modes_2028.sh`
