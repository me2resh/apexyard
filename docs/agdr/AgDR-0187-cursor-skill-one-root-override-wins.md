---
id: AgDR-0187
timestamp: 2026-09-29T12:06:44Z
agent: platform-engineer
model: composer
session: cursor-1377
trigger: user-prompt
status: executed
category: integrations
---

# Cursor skill root stays `.claude/skills/`. Override wins. Bak leaves that root.

> In the context of Cursor listing a custom skill override and the framework bak as two entries with the same name, facing duplicate skill names when third-party configs are on, I decided to keep `.claude/skills/` as Cursor's single skill root, move framework bak copies to `.claude/skill-framework-bak/`, write a managed `.cursorignore` block for override sources, and warn operators not to open a parent portfolio workspace, accepting a path change from AgDR-0022's in-skills bak location.

## Context

Custom skills override framework skills through `link-custom-skills.sh` (AgDR-0022). The hook used to move the framework copy to `.claude/skills/<name>.framework.bak/` and symlink the custom skill into `.claude/skills/<name>/`.

Cursor keys skills by the `SKILL.md` frontmatter `name` field. The bak copy still lived under the skill root and still held `SKILL.md` with the same name. Cursor therefore listed two entries for one skill. The override and the bak competed. Operators could not tell which entry ran.

A second layout also duplicates names. In split-portfolio mode the portfolio `custom-skills/` directory is a sibling of the fork. Opening the parent folder in Cursor can find the fork symlink and the portfolio original. That is a workspace-root choice, not an adapter generation bug.

AgDR-0151 already made Cursor native-first. Generating a second skill tree under `.cursor/skills/` or `.agents/skills/` would add another root beside `.claude/skills/`. That would create more duplicates, not fewer.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Generate `.cursor/skills/` with deduped symlinks and keep native `.claude/skills/` | Matches "generation" wording | Cursor would load both roots and list every skill twice |
| Move bak to `.claude/skill-framework-bak/<name>/`, manage `.cursorignore`, warn on parent workspaces | One skill root. Override stays live. Bak stays recoverable with intact `SKILL.md`. Parent sources can be ignored when Cursor honors `.cursorignore` | Changes the AgDR-0022 bak path. Relies on install docs when Cursor ignores are incomplete |
| Rename bak `SKILL.md` only | Smallest path change | Leaves bak dirs inside the skill root. Easy to miss on a future sweep |
| Rely only on docs telling people to open the fork | Smallest code change | Leaves the bak duplicate inside a correct fork workspace |

## Decision

Chosen: **move bak outside the skill root, manage `.cursorignore`, warn on parent workspaces**.

`.claude/skills/` remains the only Cursor skill root for the fork. The override symlink is the live entry. After a collision, `link-custom-skills.sh` moves the framework copy to `.claude/skill-framework-bak/<name>/`. A SessionStart sweep migrates legacy `.claude/skills/<name>.framework.bak/` dirs to that location.

`bin/sync-cursor-adapter.sh` writes a managed block into `.cursorignore` that ignores `custom-skills/`, nested `**/custom-skills/`, and bak paths. That keeps one skill root when Cursor honors the ignore file. Install and sync also tell operators to open the ops fork, not a parent folder that also holds the portfolio.

`bin/list-cursor-skills.sh` lists the names Cursor would load from disk. `--duplicates` fails when one name appears more than once. `--unique` prints the override-wins winner. Tests use that harness. They do not launch Cursor.

## Consequences

- A fork with an override shows one Cursor entry per skill name. The override is the live path.
- Restoring a framework skill means moving `.claude/skill-framework-bak/<name>/` back to `.claude/skills/<name>/` after removing the override symlink.
- Opening a parent workspace that contains both the fork and `custom-skills/` can still list duplicates if Cursor does not honor `.cursorignore`. The install and docs warn about that layout.
- No second generated skill tree is added under `.cursor/` or `.agents/`. Native-first stays intact.

## Artifacts

- Refs me2resh/apexyard#1377
- `.claude/hooks/link-custom-skills.sh`
- `.claude/hooks/_lib-cursor-skills.sh`
- `bin/list-cursor-skills.sh`
- `bin/install-cursor-adapter.sh`
- `bin/sync-cursor-adapter.sh`
- `.claude/hooks/tests/test_cursor_skill_dedupe.sh`
- `docs/harnesses/cursor.md`
- `docs/cursor-adapter.md`
- Precedent: AgDR-0022 (custom wins), AgDR-0151 (native-first Cursor overlay)

## Evolution

Cursor skill loading stayed on the native `.claude/skills/` root. Framework bak copies left that root. Adapter generation now maintains a `.cursorignore` block for override sources. Parent-directory portfolio layouts stay documented as unsafe when ignores do not apply.
