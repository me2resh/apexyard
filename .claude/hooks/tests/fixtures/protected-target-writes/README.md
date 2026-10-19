# Protected-target fixtures

These fixtures support the tamper controls of AgDR-0261 § B (me2resh/apexyard#1806).

## Files

| File | Content |
|------|---------|
| `macos-patch-p0.txt` | The macOS `patch -p0` capture (AgDR-0261 § B.14 item 3). `test_patch_macos_capture.sh` compares a new run on Darwin with this file. |
| `p12.json` | Capture P12, 2026-10-19. Inconclusive. |
| `p12b.json` | Capture P12b, 2026-10-19. Met for "no rewrite". Inconclusive for a moved `$PWD`. |
| `p12c.json` | Capture P12c, 2026-10-19. Inconclusive. |

The fixtures replace home paths, user names, session ids and agent ids with placeholders.

## Captures P12, P12b and P12c

AgDR-0261 § B.10 needs three payload captures from a real Claude Code session before the D17 PR merges.
A unit test cannot make them, because they record what the harness sends.

### What the 2026-10-19 run captured

- P12b: `compact` kept the session id. The pin and the snapshot did not change.
  `clear` issued a new session id. That session has no pin and no snapshot, so it runs in no-snapshot mode.
  A Bash `cd /tmp` ran in the session. The harness reset the shell to the project root, so no hook saw a moved `$PWD`.
- P12: the subagent wrote with a Bash redirect, not the `Edit` tool. The logger matched `Edit|Write` only, so no PreToolUse payload was recorded.
- P12c: the subagent appended one newline to its worktree `.claude/settings.json`. The JSON value did not change. No ConfigChange was logged.

### What the next run must capture

- P12: tell the subagent to use the `Edit` tool. Log PreToolUse for `Bash` and `Edit`. Record whether a line appears, and its `CLAUDE_PROJECT_DIR` and `cwd`.
  The worktree checks out the committed settings, which have no logger. A line with the logger's absolute path shows that the subagent runs the main session's hooks.
- P12b: run a Bash `cd` to a directory inside the project, for example `workspace`. Then run one Bash command, `/compact` and `/clear`. Record `$PWD` for each hook call.
- P12c: tell the subagent to add `"env": {"D17_PROBE": "1"}` to its worktree `.claude/settings.json` with the `Edit` tool. Record whether ConfigChange fires, and its `source` and `file_path`.

### Steps

Do these steps in a scratch fork, not in your live ops fork:

1. Add a temporary hook entry for `PreToolUse` (matcher `Edit`), `SessionStart` and `ConfigChange` that appends its stdin, `$PWD` and `$CLAUDE_PROJECT_DIR` to a log file under `/tmp`.
2. P12: start a session. Spawn a subagent with `isolation: "worktree"`. Tell it to edit one file in its worktree. Record the hook-process `CLAUDE_PROJECT_DIR`, the payload `cwd` and the worktree path.
3. P12b: in the same session, run a Bash `cd` to another directory. Then run `/compact`, then `/clear`. For each SessionStart, record `source`, `session_id` and the hook-process `$PWD`. Record the pin file before and after.
4. P12c: tell the worktree subagent to edit the worktree's `.claude/settings.json`. Record whether ConfigChange fires, and its `source` and `file_path`.
5. Remove the temporary hook entry.
6. Replace each home path, session id and user name with a placeholder. Save the results here as `p12.json`, `p12b.json` and `p12c.json`.

The pass criteria are in AgDR-0261 § B.10.
