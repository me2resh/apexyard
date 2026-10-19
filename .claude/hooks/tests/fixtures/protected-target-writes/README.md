# Protected-target fixtures

These fixtures support the tamper controls of AgDR-0261 § B (me2resh/apexyard#1806).

## Files

| File | Content |
|------|---------|
| `macos-patch-p0.txt` | The macOS `patch -p0` capture (AgDR-0261 § B.14 item 3). `test_patch_macos_capture.sh` compares a new run on Darwin with this file. |

## Captures P12, P12b and P12c

AgDR-0261 § B.10 needs three payload captures from a real Claude Code session before the D17 PR merges.
A unit test cannot make them, because they record what the harness sends.

Do these steps in a scratch fork, not in your live ops fork:

1. Add a temporary hook entry for `PreToolUse` (matcher `Edit`), `SessionStart` and `ConfigChange` that appends its stdin, `$PWD` and `$CLAUDE_PROJECT_DIR` to a log file under `/tmp`.
2. P12: start a session. Spawn a subagent with `isolation: "worktree"`. Tell it to edit one file in its worktree. Record the hook-process `CLAUDE_PROJECT_DIR`, the payload `cwd` and the worktree path.
3. P12b: in the same session, run a Bash `cd` to another directory. Then run `/compact`, then `/clear`. For each SessionStart, record `source`, `session_id` and the hook-process `$PWD`. Record the pin file before and after.
4. P12c: tell the worktree subagent to edit the worktree's `.claude/settings.json`. Record whether ConfigChange fires, and its `source` and `file_path`.
5. Remove the temporary hook entry.
6. Replace each home path, session id and user name with a placeholder. Save the results here as `p12.json`, `p12b.json` and `p12c.json`.

The pass criteria are in AgDR-0261 § B.10.
