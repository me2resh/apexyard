# Protected-target fixtures

These fixtures support the tamper controls of AgDR-0261 § B (me2resh/apexyard#1806).

## Files

| File | Content |
|------|---------|
| `macos-patch-p0.txt` | The macOS `patch -p0` capture (AgDR-0261 § B.14 item 3). `test_patch_macos_capture.sh` compares a new run on Darwin with this file. |
| `p12.json` | Capture P12, run 2, 2026-10-19. Met. |
| `p12b.json` | Capture P12b, run 2, 2026-10-19. Met for `compact`. `clear` leaves the new session unpinned. |
| `p12c.json` | Capture P12c, run 2, 2026-10-19. Met. |

The fixtures replace home paths, user names, session ids and agent ids with placeholders.

## Captures P12, P12b and P12c

AgDR-0261 § B.10 needs three payload captures from a real Claude Code session before the D17 PR merges.
A unit test cannot make them, because they record what the harness sends.
Both runs used a throwaway clone with a temporary logging hook.
The logger command was an absolute path in the uncommitted settings of that clone.

### Run 2 (the fixtures in this folder)

- P12: the logger recorded the Bash and Edit calls of the worktree subagent.
  So a worktree subagent runs the hooks of the main session, not the hooks in its worktree.
  In those calls the hook-process `CLAUDE_PROJECT_DIR` is the project root.
  The hook-process `$PWD` and the payload `cwd` are the worktree.
  The snapshot project directory is the start directory, so the worktree is not a live root. The `Edit` in the worktree passed.
- P12b: a Bash `cd` inside the project persists. Later hook calls have `$PWD` and the payload `cwd` in the new directory.
  `compact` ran with the moved `$PWD`. It kept the session id, the pin and the snapshot.
  `clear` issued a new session id. Its SessionStart ran with `$PWD` at the project root.
  No pin and no snapshot were written for that session, so its launchers walked up from `$PWD` on each call.
  `CLAUDE_PROJECT_DIR` stayed the project root in every hook call.
- P12c: the subagent added `"env": {"D17_PROBE": "1"}` to its worktree `.claude/settings.json` with the `Edit` tool. The edit passed. No ConfigChange fired.

### Run 1

- P12b: `compact` kept the session id. The pin and the snapshot did not change.
  `clear` issued a new session id with no pin and no snapshot.
  A Bash `cd /tmp` ran in the session. The harness reset the shell to the project root, because the target was outside the project.
- P12: the subagent wrote with a Bash redirect, not the `Edit` tool. The logger matched `Edit|Write` only, so no PreToolUse payload was recorded.
- P12c: the subagent appended one newline to its worktree `.claude/settings.json`. The JSON value did not change. No ConfigChange was logged.

### Changes that follow from the captures

- `pin-ops-root.sh` writes the pin on `clear` when no pin exists for the new session id. It resolves the ops root from `CLAUDE_PROJECT_DIR`, never from `$PWD`, because `$PWD` follows a `cd` inside the project.
- `block-hook-disabling-config-change.sh` blocks a change to a settings file that is not live when the change sets `disableAllHooks` or changes `hooks` or `env` against the committed copy. The harness did not fire ConfigChange for a worktree file, so this rule is defence in depth.

### Steps for a new capture

Do these steps in a scratch clone, not in your live ops fork:

1. Add a temporary hook entry for `PreToolUse` (matcher `Edit|Write|Bash`), `SessionStart` and `ConfigChange`. Give it an absolute path. Make it append its stdin, `$PWD` and `$CLAUDE_PROJECT_DIR` to a log file under `/tmp`.
2. P12: start a session. Spawn a subagent with `isolation: "worktree"`. Tell it to edit one file in its worktree with the `Edit` tool.
3. P12b: in the same session, run `mkdir -p workspace/probe && cd workspace/probe && pwd` with the Bash tool. Run `pwd` again, then `/compact`, `pwd`, `/clear` and `pwd`.
4. P12c: spawn a second worktree subagent. Tell it to add an `env` key to the worktree `.claude/settings.json` with the `Edit` tool.
5. Remove the temporary hook entry.
6. Replace each home path, session id, agent id and user name with a placeholder. Save the results here as `p12.json`, `p12b.json` and `p12c.json`.

The pass criteria are in AgDR-0261 § B.10.
