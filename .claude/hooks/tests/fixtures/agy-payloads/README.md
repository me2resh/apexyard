# agy hook payload fixtures

These files are agy (Google Antigravity CLI) hook inputs for
`.claude/hooks/tests/test_agy_adapter.sh`. The test feeds each file to
`harness-adapters/agy/agy-hook.sh` and checks the decision.

The key names and the payload shape come from agy CLI 1.5.14 live sessions that
the contributor ran against the fork build of this adapter, and from agy's
bundled hook contract and tool list. The values are replaced. These files are
not verbatim captures:

- Paths are synthetic. The test replaces `/work/fork` with its temporary fork.
- The `conversationId` is a made-up UUID. Tool call ids, tasks, and text are
  made up too.
- No file holds a user name, a home directory, or a project name.

A later capture session can replace these files with true captures. Keep the
key names, and scrub the values again.

## Common fields

Every file carries the common fields of agy's bundled contract:
`conversationId`, `workspacePaths`, `cwd`, `hookEventName`, `transcriptPath`,
`artifactDirectoryPath`, and `modelName`. PreToolUse files also carry
`toolCall` (`id`, `name`, `args`), `stepIdx`, and `lastUserInput`.

## Files

| File | agy tool | Key source | Expected decision |
|------|----------|------------|-------------------|
| `run_command.json` | `run_command` | live: `CommandLine`, `WaitMsBeforeAsync`, `toolSummary` | `ask` |
| `run_command-git-add-all.json` | `run_command` | live | `deny` from `block-git-add-all.sh` |
| `run_command-daemon.json` | `run_command` | live: `IsDaemon`, `BypassSandbox` | `ask` |
| `write_file.json` | `write_file` | live: `Path`, `Content`, `Append`. Tool list: `Overwrite`, `ArtifactMetadata` | `ask` with an active ticket |
| `write_file-append.json` | `write_file` | live | `ask` with an active ticket |
| `write_file-settings.json` | `write_file` | live | `deny` from `block-protected-target-writes.sh` |
| `edit_file.json` | `edit_file` | live: `Path`. Tool list: `Target`, `Replacement`, `ArtifactMetadata` | `ask` with an active ticket |
| `edit_file-settings.json` | `edit_file` | live | `deny` from `block-protected-target-writes.sh` |
| `read_file.json` | `read_file` | live: `Path`, `ByteOffset`. Tool list: `StartLine`, `EndLine` | `ask` |
| `read_file-env.json` | `read_file` | synthetic call, `read_file` key shape | `deny` from the `permissions.deny` rule `Read(//**/.env)` |
| `run_command-printenv.json` | `run_command` | synthetic call, `run_command` key shape | `deny` from the `permissions.deny` rule `Bash(printenv)` |
| `manage_task-list.json` | `manage_task` | live: `Action` | `ask` |
| `manage_task-kill.json` | `manage_task` | live: `Action`, `TaskId` | `ask` |
| `manage_task-status.json` | `manage_task` | binary json tags: `Action`, `TaskId` | `ask` |
| `manage_task-send_input.json` | `manage_task` | live: `Action`, `TaskId`, `Input` | `deny`, keystroke reason |
| `unknown-tool.json` | `invoke_subagent` | name from the agy binary, no args | `deny`, not routed |
| `session_start.json` | SessionStart | bundled contract | nested `systemMessage` step |
