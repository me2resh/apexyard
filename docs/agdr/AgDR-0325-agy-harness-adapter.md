---
id: AgDR-0325
timestamp: 2026-11-21T00:00:00Z
agent: Adel (Platform Engineer)
model: claude-opus-5-5
session: feature/GH-2089-agy-harness-adapter
trigger: user-prompt
status: executed
category: integrations
---

# AgDR-0325: Antigravity CLI (agy) harness adapter

> Facing agy tool calls that reach no gate, we route every agy hook through one wrapper that runs the unmodified gates. The wrapper prints only `ask` or `deny`, and each clone generates its own `.agents/hooks.json`.

## Context

agy is the Google Antigravity CLI. It loads the fork's `AGENTS.md` and `.agents/skills/`, so it receives the rules as text. Without hook wiring, no gate runs under agy.

agy CLI 1.5.14 ships a hooks reference, `~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md`. This record uses that bundled contract. It states these facts:

- agy reads `<workspace>/.agents/hooks.json`. The top level is an object keyed by hook name. Each hook holds event keys.
- A PreToolUse group has a `matcher` regex on the agy tool name. A handler runs with `sh -c`, from the folder that holds `hooks.json`. Its default timeout is 30 seconds.
- Every payload has the common fields `conversationId`, `workspacePaths`, `transcriptPath`, `artifactDirectoryPath`, `modelName`, `hookEventName`, and `cwd`. `cwd` is the agent's working directory, where its commands run by default.
- The PreToolUse `decision` is `allow` ("Automatically allow the tool execution"), `ask`, `force_ask`, or `deny`.
- SessionStart steps are nested objects: `{"systemMessage":{"systemMessage":"..."}}` and `{"errorMessage":{"userMessage":"..."}}`.
- Plugins in `.agents/plugins/` are discovered automatically, and each one runs its own `hooks.json`. `.agents/plugins.json` registers plugins.

The public page `https://antigravity.google/docs/hooks.md`, fetched 2026-11-21, conflicts with the bundled file. It says `allow` delegates to the next hook or the default policy, and it lists `auto_approve`.

The agy CLI uses tool names that the public docs do not list. The contributor ran agy CLI 1.5.14 against the fork build of this adapter. Those live sessions used `write_file`, `edit_file`, `read_file`, and `manage_task`. agy's own tool list gives their argument keys.

Google's terms forbid driving agy from another agent. No agent, harness, or CI job runs agy. A person, not an agent, runs agy for every live check.

Precedents:

- AgDR-0088 generates Codex hook wiring from `.claude/settings.json`.
- AgDR-0092 has the opencode plugin read its gate list from `.claude/settings.json` at load time, so the list cannot drift.
- AgDR-0250 has adapters export `APEXYARD_SESSION_ID` and remove an inherited `CLAUDE_CODE_SESSION_ID`.
- AgDR-0228 sets `onFailure: block` and measured timeouts.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Generate one agy handler for each settings.json handler (Codex style) | Mirrors AgDR-0088. No wrapper logic at run time. | agy sends no Claude-shaped stdin and reads a decision object, not an exit code. Each generated handler would need its own translation and fail-closed mapping. |
| One wrapper that reads `.claude/settings.json` at each call, and a small generator (chosen) | The gate list cannot drift. One place does the translation, the exit mapping, and the fail-closed checks. | The wrapper is new trust-chain code, and it adds a few `jq` calls to each tool call. |
| Commit `.agents/hooks.json` | Every clone gets the gates with no install step. | The file must name the wrapper by path. A relative path depends on where agy runs the hook. |
| Keep `.agents/hooks.json` as gitignored generated output (chosen) | The file can hold an absolute wrapper path. This matches the Codex tracking policy. | Each clone must run `bin/sync-agy-adapter.sh` once. |

## Decision

Chosen: **one wrapper, `harness-adapters/agy/agy-hook.sh`, with a run-time read of `.claude/settings.json`, a small generator, and a gitignored `.agents/hooks.json`.** The wrapper is a transport. Bash owns every gate decision.

### Decisions

The wrapper prints only `ask` or `deny`. It never prints `allow`, `force_ask`, or `auto_approve`. Under the bundled reading, `allow` auto-approves the call. Under the public reading, `auto_approve` does. `ask` requests agy's own permission check under both readings and never auto-approves. An output guard turns any other output into `deny`.

Whether agy prompts for an `ask` call depends on agy's own settings, not on the hook. Those settings are `toolPermission`, `agentMode`, and the terminal sandbox. So the adapter guarantees the gate denies, and prompting is agy's job.

| Topic | Decision | Reason |
|-------|----------|--------|
| Routing | `.agents/hooks.json` has one catch-all PreToolUse matcher, `.*`, and one SessionStart entry. | A per-tool list misses tools that agy adds. A per-tool entry next to the catch-all would run the gates twice. |
| Gated tools | `run_command` maps to `Bash`. `write_file` and `write_to_file` map to `Write`. `edit_file` and `replace_file_content` map to `Edit`. `multi_replace_file_content` maps to `MultiEdit`. | These tools run commands or write files. `edit_file` replaces every match, so it maps with `replace_all=true`. |
| Read-only tools | `read_file`, `view_file`, `list_dir`, `find_by_name`, `search_web`, `read_url_content`, `command_status`, `read_terminal`, `ask_question`, `ask_permission`, and `list_permissions` get `ask` after the `permissions.deny` `Read(...)` check, and before the fork, gate, and session-snapshot checks. `grep_search` is not on the list, so it gets the not-routed `deny`. | They reach no gate, so those checks cannot change their result. A broken fork still lets agy read under its own permission check. `search_web` and `read_url_content` are allowed for parity with Claude Code, where no gate covers `WebSearch` or `WebFetch`. The `Read(...)` rules close the main exfiltration source, the reads of `.env` files, private keys, and `.mcp.json`. Each allowed tool reads only what the `Read(...)` check can see. `read_file` and `view_file` read the one path they name. `command_status` and `read_terminal` read the output of a command that the gates already judged. `find_by_name` and `list_dir` return file names, not content. `grep_search` reads the content of every file under a folder, `.env` files included, and a path rule sees only the folder. agy CLI 1.5.14 does not declare it. |
| permissions.deny | The wrapper applies the `permissions.deny` rules of `.claude/settings.json` literally, read at run time. `Read(<glob>)` covers every string argument of a read-only tool. `Edit(<glob>)` and `Write(<glob>)` cover the file path of the write tools. `Bash(<cmd>)` is an exact match on the trimmed `CommandLine`, with each run of spaces and tabs collapsed to one space. `Bash(<prefix>:*)` also matches `<prefix>` and a space. The reason quotes the rule. | agy does not read these rules, and agy showed no prompt for an `ask` call. Without them, a `read_file` of `.env` could pass, and `read_url_content` could then send the data out. The repo enforces the rules, not agy. |
| Keystrokes | `send_command_input`, and `manage_task` with `Action` `send_input`, always get `deny`. `manage_task` with `list`, `kill`, or `status` gets `ask`. Any other `Action` gets `deny`. | No gate can inspect keystrokes typed into a running shell. agy must still be able to stop its own background tasks. |
| Not routed | Every other tool gets `deny`, with a reason that names the tool. This covers the subagent, schedule, browser, and `mcp_*` tools. | Fail closed. A subagent tool stays denied until a check shows that the subagent's own `run_command` reaches the hook. |
| Argument shape | A duplicate key in any payload object, a case-variant key in `toolCall` or its args, and an args key outside the tool's key list get `deny`. | jq keeps the last duplicate and matches case exactly. agy's Go JSON decoder matches keys case-insensitively. So the wrapper and agy could read different values. |
| Strings | jq checks every string that decides a policy class, and every path field, before a shell substitution sees it. A path with a control character gets `deny`. | A shell substitution drops trailing newlines, so `"list\n"` could pass as `list`. |
| Protected roots | The gates get `CLAUDE_PROJECT_DIR` set to the fork root, and run in the workspace. | No ops-root pin exists under agy, so `_lib-protected-state.sh` protects only `CLAUDE_PROJECT_DIR`. With the workspace there, agy opened in `<fork>/docs` could write `<fork>/.claude/settings.json`. |
| Session snapshot | A session snapshot whose `project_dir` is not the fork root gets `deny`. | The snapshot fixes the protected root for the conversation. |
| Fork check | The wrapper applies the settings.json resolver's walk from the workspace. A walk that finds no fork, or another fork, gets `deny`. | The resolver exits 0 when it finds no fork. A nested anchor would run another fork's gates. |
| Existing terminals | A `run_command` with `RequestedTerminalID`, or with a `RunPersistent` other than `false`, gets `deny`. | Such a command runs in an existing terminal. Its directory can differ from the gated `Cwd`, for example after an earlier `cd`, so the gates would judge the wrong folder. agy CLI 1.5.14 does not declare these keys. |
| Nested `.agents/` config | On every PreToolUse and SessionStart call, the wrapper checks each folder from agy's directory up to, but not including, the fork root. It starts at the top-level `cwd` and at `workspacePaths[0]`, in lexical and physical form. A `.agents/hooks.json`, `.agents/plugins.json`, or `.agents/plugins/` there gets `deny` for every tool, and an error step at SessionStart: "a nested .agents hook or plugin config at <dir> can override the fork's hooks. A person must remove it from the live fork, because the gates block an agent's removal". | agy reads `.agents/` config in the folders between its directory and the fork root, so a nested file could override the fork's hooks. The wiring protection below stops a write through the gates that creates such a file. This check catches a file that already exists, for example one that a person or another tool made. The walk checks only the ancestors on the path, so its cost stays small. The fork root's own `.agents/` is the real wiring. A linked worktree is its own fork root. A sibling folder, or a managed project under `workspace/` while agy runs in the fork root, is not on the path. |
| Terminal sandbox | A `run_command` with a `BypassSandbox` other than absent or JSON `false` gets `deny`: it "asks agy to run outside its terminal sandbox; ApexYard does not allow agy to drop its sandbox". `IsDaemon` stays allowed, and its `CommandLine` still goes through the gates. | The repo enforces the policy, not agy. agy's sandbox is a second layer under the gates, and a call must not remove it. The cost: in a linked worktree, agy's git can fail inside the sandbox with "not a git repository: (null)", and agy may retry with `BypassSandbox`. That retry is now denied, so git inside a worktree may not work under agy. The fork root is not affected. |
| Run directory | A `run_command` runs in `args.Cwd`, else in the top-level `cwd`, else in the workspace. The value must be an existing directory. A top-level `cwd` outside the fork gets `deny`. | agy runs commands in its `cwd`. An explicit `args.Cwd` outside the fork is one command's choice, and the gates judge it there. |
| Relative paths | When the top-level `cwd` differs from the workspace, a relative `Path`, `TargetFile`, or `args.Cwd` gets `deny`. | The contract does not say which folder a relative path uses. A guess could let a gate judge the wrong file. |
| SessionStart | The wrapper prints the nested `systemMessage` and `errorMessage` shapes. | agy ignores a plain string. |
| Failures | A gate exit 2, a wrapper timeout, an exit 126 or 127, an `onFailure: block` failure, malformed stdin, a missing `jq`, and any wrapper error get `deny`. The wrapper always exits 0. | agy's behaviour on a non-zero exit, a crash, or invalid JSON is not documented. A watchdog stops each gate before agy's own timeout. |
| Decision log | An opt-in log writes one JSON line for each call. The payload reaches `jq` on stdin, never as a process argument. | A `--arg` value shows in `ps`, and a large write can fail with `E2BIG`. |
| Wiring protection | `.agents/hooks.json`, `.agents/plugins/`, `.agents/plugins.json`, and `harness-adapters/agy/` are protected targets in a live ApexYard fork root (a root with `.claude/hooks` and `.apexyard-fork` or `onboarding.yaml`), through `PT_ADAPTER_WIRING` in `_lib-protected-state.sh`. Non-fork project roots and the no-root fallback do not apply the agy wiring forms. `bin/sync-agy-adapter.sh` is outside the list, so ordinary `bin/` commands pass in every root. A nested `.agents/hooks.json`, `.agents/plugins.json`, or anything under `.agents/plugins/` is protected at any depth under the fork root, without case, except under `workspace/`. Under `.claude/worktrees/<name>/`, that worktree's own root wiring and `workspace/` subtree stay editable, because a linked worktree is its own fork root. A nested form deeper inside the worktree is protected. The nested forms match directly, with no ancestor check. A nested `.agents` folder (outside `workspace/`) is also protected as the target of a recursive copy, a link, a removal, or a move onto a target that is not an existing directory. A move, a link, or a recursive copy into an existing folder is judged at its new path, `<folder>/<name>`. The folder itself is judged against the core state only, so a copy or link into `harness-adapters/` or `.agents/` still passes. A contents copy, or a source that can land at another name, is judged against the folder in full. That covers flags such as `-T`, `--parents` and `--relative`, and a glob, a brace or a variable in a recursive copy. A plain copy or move with a glob or a variable judges each protected name as a direct child of the folder. A move with a dot glob judges `.agents` and `.claude` as children only when the destination is the live fork root itself. The worktree exemption goes by the path, so a folder there that is not a real worktree is exempt too. A plain `mkdir` of it stays allowed. Moving, copying, or extracting a tree that already contains an `.agents/` config is not caught (AgDR-0267). | Each path can switch the gates off under agy, or run another hook beside them. agy executes only `.agents/hooks.json` and `harness-adapters/agy/agy-hook.sh`, so protecting `bin/sync-agy-adapter.sh` is not needed and caused false blocks on `bin/`. Managed-project clones under `workspace/` stay editable, because they are not on agy's path from the fork root and `check_nested_agents` denies every call if agy starts in them. Deleting a nested config is the remedy, and an ancestor check for the nested forms would need a file-system scan. A worktree's root wiring stays editable by design, as its `.claude/hooks/` is, so the gates under agy are only as strong as the wiring of the folder that the person starts agy in. |
| Codex co-existence | `bin/sync-codex-adapter.sh --clean` removes only `.agents/skills/` and `.codex/`. | A full `.agents/` removal deleted `.agents/hooks.json`. |

### Interaction with current hooks

The wildcard PreToolUse group, `dispatch-bash.sh --shell-alias-only`, runs for every routed call, as under Claude Code. It passes a `Bash`, `Write`, or `Edit` call at once. Its 75 second timeout adds to each tool's budget. So the catch-all timeout is larger than the 30 second default.

The `permissions.deny` rules in `.claude/settings.json` are Claude Code permission rules, not hooks. agy does not read them, so the wrapper applies them literally. With the current rules, agy gets `deny` for reads of `.env` and `.env.*` files, `gh auth token`, `printenv`, a bare `env`, private-key reads, and `.mcp.json` reads.

Glob rules: a leading `//` is an absolute path, `~/` is the home folder, and a leading `/` is the fork root. A pattern with neither matches anywhere under the fork. `**` is any depth, including none, `*` is one path segment, and `?` is one character. A path matches in its given, lexical, or symlink-resolved form, without case. The resolved form follows the whole symlink chain, up to 40 links. A loop, a longer chain, or an unreadable link gets `deny`. A dangling link resolves to its missing target, which the rules then judge. Over-matching is acceptable, because it fails closed. When the rules cannot be read, a call that names a path or a command gets `deny`.

The match is literal. Before it, the wrapper trims the command and collapses each run of spaces and tabs to one space, which can only add denies. A rule never matches a word in the middle of a command, so a search for the word passes. Pipes, chains, wrapped commands, and absolute command paths are not caught. This is the AgDR-0267 limit of the shell-text gates. A full match would need Claude Code's command parsing, which the gates do not reimplement. Rule types other than `Read`, `Edit`, `Write`, and `Bash`, such as `WebFetch(...)`, are not applied. The other adapters (Codex, opencode, pi, and Cursor) do not apply these rules yet. The only other reader is `bin/secrets-selftest.sh`.

### Live check

The contributor ran agy CLI 1.5.14 against the fork build of this adapter on 2026-11-21. In the fork root, agy loaded `.agents/hooks.json` with no trust step. A parent folder was already trusted. `git add -A` got `deny` from `dispatch-bash.sh`, and nothing was staged. A `write_file` and an `edit_file` to `.claude/settings.json` got `deny` from `block-protected-target-writes.sh`. Ordinary `write_file`, `edit_file`, and `read_file` calls got `ask` and succeeded. agy quoted the SessionStart text. Calls that passed got `ask`, and no permission prompt appeared for them under the contributor's agy settings. In the fork root, an `edit_file` on `.agents/hooks.json` and a `run_command` of `rm .agents/hooks.json` both got `deny`. The fork build protects the agy wiring through a wider list that also covers other adapters. This port protects only the agy wiring, so the same deny comes from different code here.

On 2026-11-22, the contributor ran agy CLI 1.5.14 against this port, in a linked worktree that `bin/sync-agy-adapter.sh` wired. `git add -A` got `deny` from `dispatch-bash.sh`. An `edit_file` on `.claude/settings.json` and a `write_file` of a nested `.agents/hooks.json` got `deny` from `block-protected-target-writes.sh`. A `read_file` of a test file named `*.private-key.pem` got `deny` from a `permissions.deny` rule. A `run_command` with `BypassSandbox: true` got `deny`. Ordinary calls got `ask` and succeeded, and agy quoted the SessionStart text. On this port, an edit of the root `.agents/hooks.json` and the persistent-terminal deny are not live-checked. Neither are the `Bash` rules of `permissions.deny` or the nested `.agents/` walk with an existing nested config. agy CLI 1.5.14 did not offer `grep_search`, so its deny cannot run live.

Open questions from the issue:

- Crash or timeout: the wrapper's own watchdog and output guard fail closed, and the wrapper always exits 0 with one decision. A crash of the wrapper process itself under agy has not been observed live.
- Workspace trust: agy keeps trusted folders in `trustedWorkspaces` in its user settings. In the fork root, agy loaded `.agents/hooks.json` with no trust step. A parent folder was already in that list. That entry did not cover a new linked worktree under the same parent. agy asked the person to trust the worktree first, and then added it to the list. agy's bundled docs do not describe workspace trust, and a refused trust prompt was not tested.
- `agy -p`: the hooks run in non-interactive mode. Against the fork build, SessionStart injected the context, and an `edit_file` on `.agents/hooks.json` in the fork root got `deny` from `block-protected-target-writes.sh` ("the edit target is live hook state. Use an isolated worktree."). Against this port, SessionStart injected the context, and agy itself denied a `read_file` that got `ask`, because headless mode cannot prompt. So under `agy -p`, an `ask` call runs only when agy's own settings allow it.

## Consequences

- PreToolUse gates for `Bash`, `Write`, and `Edit` are live-checked under agy CLI 1.5.14 on the fork build and on this port. The `MultiEdit` gates run by construction only.
- The wrapper never auto-approves a call. agy's permission settings decide whether agy prompts.
- The `permissions.deny` rules apply literally, and the wrapper reads gates and rules only from `.claude/settings.json` (not `.claude/settings.local.json` or user settings). Pipes, chains, wrapped commands, and absolute command paths are not caught.
- agy cannot drop its terminal sandbox. So git inside a linked worktree may fail under agy. The fork root is not affected.
- agy cannot use `grep_search` in the fork. It can search with `run_command`, which the gates judge.
- PostToolUse, UserPromptSubmit, and ConfigChange handlers do not run under agy.
- agy cannot use the subagent, schedule, browser, or MCP tools in the fork until each gets a mapping and a live check.
- agy's `run_command` shell does not receive `APEXYARD_SESSION_ID`, because a PreToolUse hook cannot change the command.
- A nested `.agents/` hook or plugin config between agy's directory and the fork root makes every call fail closed, until a person removes it.
- The Codex, opencode, and pi wiring is not a protected target yet. That work is a separate change.
- Each clone must run `bash bin/sync-agy-adapter.sh` once. A moved clone must run it again. `--check` reports the stale path as drift.
- The bundled contract can change with each agy release. This record names agy CLI 1.5.14.

## Artifacts

- Issue: me2resh/apexyard#2089.
- `harness-adapters/agy/agy-hook.sh` and `bin/sync-agy-adapter.sh`
- `.claude/hooks/_lib-protected-state.sh` (`PT_ADAPTER_WIRING`)
- `bin/sync-codex-adapter.sh` (`--clean` scope)
- `.claude/hooks/tests/test_agy_adapter.sh`, `.claude/hooks/tests/test_protected_agy_wiring.sh`, and `.claude/hooks/tests/fixtures/agy-payloads/`
- `docs/harnesses/agy.md`
