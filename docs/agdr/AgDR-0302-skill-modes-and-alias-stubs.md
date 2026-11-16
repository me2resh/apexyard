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

> In the context of three skills that only extend a sibling skill (`/spike-close`, `/prototype-close`, `/tickets-batch`), facing overlap in the skill list and a 16,000-byte cap on `/task`, I decided to make them modes of the sibling skill (`/spike --close`, `/prototype --close`, `/task --batch`), to keep each mode body in a shared mode directory (`.claude/skills/_lib-modes/`), and to keep the old names as deprecated alias stubs until v5.12.0 removes them, to achieve a smaller skill surface without a lost capability or a broken command, accepting that the skill count stays at 72 until the stubs are removed.

## Context

- Issue me2resh/apexyard#2028 asks to fold the three skills into modes, and to keep the old commands as alias stubs for one release.
- `test_skill_shared_blocks.sh` caps `/task` SKILL.md at 16,000 bytes. The `/tickets-batch` body was 18,961 bytes (about 19,000). It cannot go inline.
- Claude Code loads a skill's SKILL.md on invocation. Other files in the skill directory load only when the skill tells the agent to read them.
- `bin/extract-subpacks.sh` copies the top-level sibling files of each audit-pack skill. `/spike`, `/prototype`, and `/task` are in no pack. The codex adapter (`bin/sync-codex-adapter.sh`) copies the whole skill folder, so the mode files travel with the skill there.
- The harness lists every directory under `.claude/skills/` that has a SKILL.md as a command. A stub directory keeps the old command name working. A directory with no SKILL.md, such as `_lib-diagram`, is not a command.
- `link-custom-skills.sh` replaces a framework skill directory with a symlink when an adopter overrides that skill in `custom-skills/`. It moves the framework copy to `.claude/skill-framework-bak/`. A file inside an overridden skill directory is then gone from `.claude/skills/`. The hook skips a source directory with no SKILL.md, so it never replaces `_lib-modes`.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Mode body inline in the sibling SKILL.md | One file for each skill | `/task` exceeds the 16,000-byte cap. Every `/spike` and `/task` run loads the close or batch text that it does not use. |
| B1. Mode body in a supporting file in the sibling skill directory; the old skill becomes a stub that loads it | The default path stays small. One copy of each mode body. | An override of the sibling skill moves the file away, so the mode and the alias both break. |
| B2. Mode body in `.claude/skills/_lib-modes/` (no SKILL.md); the sibling skill and the stub both read it | Same as B1. An override of the sibling skill does not move the file, so the alias keeps working. `git mv` keeps the file history. | The agent must follow a file reference. An override keeps the mode only when it copies the Modes section. |
| C. Mode body in `docs/skills/` | Same as B | The body leaves the skill directory, so subpack extraction and skill-local tests do not find it. |
| D. Remove the old commands now | Smallest list | Breaks every operator habit and every document that names the old commands. The issue forbids it. |

## Decision

Chosen: **B2**, because it keeps the default path of `/spike`, `/prototype`, and `/task` small, keeps one copy of each mode body, and keeps every old command working when an adopter overrides the sibling skill.

- Each sibling skill has a Modes table before step 0: flag, then mode file. The flag can be any word in `$ARGUMENTS`, not only the first word.
- `/spike` and `/prototype` route `--close` to `_lib-modes/spike-close.md` and `_lib-modes/prototype-close.md`. Close mode does not write the active-issue-skill marker. This is the same as the old close skills.
- `/task` routes `--batch` to `_lib-modes/task-batch.md`. The new `--project`, `--priority`, `--parent`, and `--labels` flags prefill the shared questions. They never skip a confirmation.
- Each alias stub prints a deprecation note and reads the same mode file with the mode flag added. It does not read the sibling skill.
- An adopter override of `/spike`, `/prototype`, or `/task` keeps the mode only when the override's SKILL.md has the Modes section. The alias works with or without that section until v5.12.0. Routing a mode past an override with no Modes section needs a hook or script change. This decision does not make that change.
- The skill count stays at 72. The skill list marks the three stubs as deprecated aliases.
- Alias lifetime: the stubs print a deprecation note from this change on. They ship as deprecated aliases in v5.11.0, the next release. v5.12.0, the release after that, removes them. If the next release takes a different version number, the removal moves to the release after it.
- Every quoted skill count is now a computed check (`test_skill_modes_2028.sh`, the `/geo-audit` and `/codify-rule` smoke tests) or a pointer to `docs/claude-md-reference.md`.

## Consequences

- Removing the stubs in v5.12.0 needs these edits: delete the three stub directories; replace `/tickets-batch` with `/task --batch` in `setup/SKILL.md`; remove their rows and the alias note in `docs/claude-md-reference.md`; set the count to 69 there and in `docs/whats-inside.md`; remove `spike-close` and `prototype-close` from the loop in `test_skill_shared_blocks.sh`; remove the stub section of `test_skill_modes_2028.sh`.
- Permissions are keyed on the skill that runs. An alias reads a file and does not run its sibling, so `Skill(tickets-batch)` still covers `/tickets-batch`. The new command `/task --batch` runs `/task`, which needs `Skill(task)`. In the same way, `/spike --close` needs `Skill(spike)`, and `/prototype --close` needs `Skill(prototype)`. Adopters add these permissions to `.claude/settings.local.json` or their managed settings before v5.12.0.
- `/launch-check` names and offers a full audit for each WARN or FAIL row, including `/audit-deps` and `/security-review`. It never runs an audit without a yes. Its open-PR lookup uses the PR list command filtered on the current branch (`test_launch_check_pr_lookup_2028.sh` runs it).

## Artifacts

- me2resh/apexyard#2028
- `.claude/skills/_lib-modes/spike-close.md`, `.claude/skills/_lib-modes/prototype-close.md`, `.claude/skills/_lib-modes/task-batch.md`
- `.claude/hooks/tests/test_skill_modes_2028.sh`, `.claude/hooks/tests/test_launch_check_pr_lookup_2028.sh`
