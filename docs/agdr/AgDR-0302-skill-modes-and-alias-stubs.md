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

> In the context of three skills that only extend a sibling skill (`/spike-close`, `/prototype-close`, `/tickets-batch`), facing overlap in the skill list and a 16,000-byte cap on `/task`, I decided to make them modes of the sibling skill (`/spike --close`, `/prototype --close`, `/task --batch`), to keep each mode body in a supporting file in the sibling skill directory, and to keep the old names as deprecated alias stubs until v5.12.0 removes them, to achieve a smaller skill surface without a lost capability or a broken command, accepting that the skill count stays at 72 until the stubs are removed.

## Context

- Issue me2resh/apexyard#2028 asks to fold the three skills into modes, and to keep the old commands as alias stubs for one release.
- `test_skill_shared_blocks.sh` caps `/task` SKILL.md at 16,000 bytes. The `/tickets-batch` body was 18,961 bytes (about 19,000). It cannot go inline.
- Claude Code loads a skill's SKILL.md on invocation. Other files in the skill directory load only when the skill tells the agent to read them.
- `bin/extract-subpacks.sh` copies the top-level sibling files of each audit-pack skill. `/spike`, `/prototype`, and `/task` are in no pack. The codex adapter (`bin/sync-codex-adapter.sh`) copies the whole skill folder, so the mode files travel with the skill there.
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
- The skill count stays at 72. The skill list marks the three stubs as deprecated aliases.
- Alias lifetime: the stubs print a deprecation note from this change on. They ship as deprecated aliases in v5.11.0, the next release. v5.12.0, the release after that, removes them. If the next release takes a different version number, the removal moves to the release after it.
- Every quoted skill count is now a computed check (`test_skill_modes_2028.sh`, the `/geo-audit` and `/codify-rule` smoke tests) or a pointer to `docs/claude-md-reference.md`.

## Consequences

- Removing the stubs in v5.12.0 needs these edits: delete the three stub directories; remove their rows and the alias note in `docs/claude-md-reference.md`; set the count to 69 there and in `docs/whats-inside.md`; remove `spike-close` and `prototype-close` from the loop in `test_skill_shared_blocks.sh`; remove the stub section of `test_skill_modes_2028.sh`.
- Permissions are keyed on the skill that runs. An adopter permission `Skill(tickets-batch)` does not cover `/task --batch`, which needs `Skill(task)`. In the same way, `Skill(spike-close)` needs `Skill(spike)`, and `Skill(prototype-close)` needs `Skill(prototype)`. Adopters update `.claude/settings.local.json` or their managed settings before v5.12.0.
- `/launch-check` names and offers a full audit for each WARN or FAIL row, including `/audit-deps` and `/security-review`. It never runs an audit without a yes. Its open-PR lookup uses the PR list command filtered on the current branch (`test_launch_check_pr_lookup_2028.sh` runs it).

## Artifacts

- me2resh/apexyard#2028
- `.claude/skills/spike/close.md`, `.claude/skills/prototype/close.md`, `.claude/skills/task/batch.md`
- `.claude/hooks/tests/test_skill_modes_2028.sh`, `.claude/hooks/tests/test_launch_check_pr_lookup_2028.sh`
