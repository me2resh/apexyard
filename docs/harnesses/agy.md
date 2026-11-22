# Harness support: agy (Antigravity CLI)

**Status:** ✅ **Live-checked on the fork build (2026-11-21) and on this port (2026-11-22)** for `run_command`, `write_file`, `edit_file`, `read_file`, and SessionStart. The contributor ran agy CLI 1.5.14 against both. In each check, a real turn's `git add -A` got `deny` from the unmodified `dispatch-bash.sh`, and nothing was staged. Edits to `.claude/settings.json` got `deny` from `block-protected-target-writes.sh`. Decision record: [AgDR-0314](../agdr/AgDR-0314-agy-harness-adapter.md).

**Contract checked against:** agy CLI 1.5.14, bundled hooks reference `~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md`. That file is more current than the public web page. Check this page again after an agy upgrade.

agy is the Google Antigravity CLI, a terminal coding agent. agy loads the fork's `AGENTS.md` and `.agents/skills/`, so it receives the rules as text. The adapter adds the mechanical gates. It routes agy hook events to the same unmodified `.claude/hooks/*.sh` gates that Claude Code runs.

## Terms of service limit

Google's terms forbid driving agy from another agent. So no agent, harness, or CI job runs agy. A person, not an agent, runs agy for every live check. The live checks on this page were run by hand.

## Verification

- **Unit tests:** `.claude/hooks/tests/test_agy_adapter.sh` feeds agy payloads to the wrapper. No test runs agy. The payloads in `.claude/hooks/tests/fixtures/agy-payloads/` have the key shapes that agy CLI 1.5.14 sent, with synthetic values (see that folder's README).
  - `git add -A` gets `deny` from the real `block-git-add-all.sh`. `git status` gets `ask`.
  - A code-path `write_file` gets `deny` from the real `require-active-ticket.sh` without a ticket, and `ask` with one.
  - A `write_file` or `edit_file` to `.claude/settings.json` gets `deny`, also when agy works in a subfolder of the fork.
  - Malformed stdin, a missing `jq`, a missing gate, a gate timeout, an unrouted tool, and a duplicate or case-variant argument key each get `deny`.
  - No output is `allow`, `force_ask`, or `auto_approve`. A test checks that every decision emit path in the wrapper source is `ask` or `deny`.
- **Wiring test:** `.claude/hooks/tests/test_protected_agy_wiring.sh` checks that the agy wiring is a protected target in the live fork root and editable in a worktree.
- **Live, fork build (2026-11-21, agy CLI 1.5.14):** the contributor ran agy CLI 1.5.14 against the fork build of this adapter. These calls come from the decision log:

| agy tool | Call | Decision | Gate or result |
|----------|------|----------|----------------|
| SessionStart | — | inject | agy quoted the injected ApexYard text |
| `run_command` | `git status` | ask | ran |
| `run_command` | `git add -A` | deny | `dispatch-bash.sh` |
| `write_file` | create a file in `src/` | ask | the write succeeded |
| `edit_file` | edit that file | ask | the edit succeeded |
| `read_file` | `ByteOffset` 0 | ask | the read succeeded |
| `edit_file` | `.claude/settings.json` | deny | `block-protected-target-writes.sh`: "the edit target is live hook state" |
| `manage_task` | `kill`, `list` | ask | ran |
| `edit_file` | `.agents/hooks.json` in the fork root | deny | `block-protected-target-writes.sh`: "the edit target is live hook state" |
| `run_command` | `rm .agents/hooks.json` in the fork root | deny | "protected target: .agents/hooks.json" |
| SessionStart, `agy -p` | — | inject | the headless run injected the ApexYard text |
| `edit_file`, `agy -p` | `.agents/hooks.json` in the fork root | deny | `block-protected-target-writes.sh`: "the edit target is live hook state. Use an isolated worktree." |

The last two rows come from one headless `agy -p` run, so the hooks run in non-interactive mode too. agy printed the deny reason and did not change the file. The fork build protects the agy wiring through a wider list that also covers other adapters. This port protects only the agy wiring, so here the same deny comes from different code.

In the fork root, agy loaded `.agents/hooks.json` with no trust step. A parent folder was already trusted (see the workspace-trust open question below). agy showed no permission prompt for any `ask` call (see [`ask` and agy's permission check](#ask-and-agys-permission-check)).

- **Live, this port (2026-11-22, agy CLI 1.5.14):** the contributor ran agy in a linked worktree that holds this branch. `bin/sync-agy-adapter.sh` wired that worktree, so agy used it as the fork root. These calls come from the decision log:

| agy tool | Call | Decision | Gate or result |
|----------|------|----------|----------------|
| SessionStart | — | inject | agy quoted the injected ApexYard text |
| `run_command` | `git add -A` | deny | `dispatch-bash.sh` |
| `read_file` | `.claude/settings.json` | ask | the read succeeded |
| `edit_file` | `.claude/settings.json` | deny | `block-protected-target-writes.sh`: "the edit target is live hook state" |
| `write_file`, `read_file` | a new file, then a read of it | ask | both succeeded |
| `read_file` | a test file named `*.private-key.pem` | deny | the `permissions.deny` rule `Read(//**/*.private-key.pem)` |
| `run_command` | `pwd` with `BypassSandbox: true` | deny | the wrapper's sandbox check |
| `write_file` | a nested `sub/.agents/hooks.json` | deny | `block-protected-target-writes.sh`: "the edit target is live hook state" |
| `run_command` | `ls` | ask | ran |
| SessionStart, `agy -p` | — | inject | the headless run injected the ApexYard text |
| `run_command`, `read_file`, `agy -p` | the model's first two calls | ask | agy denied the `read_file` itself, because headless mode cannot prompt, and the run ended with no output |

The nested write was denied, so the nested `.agents/` walk found no config, and its deny was not exercised. An earlier run in the same worktree, before it was wired, ran no hook. So agy did not read the `.agents/hooks.json` of the main checkout, which is a parent folder. In that run, `git` failed under agy's default sandbox with "not a git repository", which is the known cost of the sandbox deny.

**Not verified live on this port:** an edit of the root `.agents/hooks.json` and the persistent-terminal deny. The `Bash` rules of `permissions.deny` and the nested `.agents/` walk with an existing nested config are not verified either. The `Bash` rules name secret-printing commands, so the live check did not run them. agy CLI 1.5.14 did not use `replace_file_content`, `multi_replace_file_content`, or `write_to_file`, so they are not verified.

## Enforcement vs advisory today

**Enforced (blocking):** every PreToolUse gate in `.claude/settings.json` for the `Bash`, `Write`, `Edit`, and `MultiEdit` tools. This includes the Bash dispatcher, ticket-first, the migration-ticket gate, the protected-target gate, and the reviewer-write limit.

| agy tool | Gates as Claude Code tool |
|----------|---------------------------|
| `run_command` | `Bash` |
| `write_file` (CLI) | `Write`. `Path` gives `file_path`, `Content` gives `content`. `Append` and `Overwrite` run the same gates. |
| `write_to_file` | `Write` |
| `edit_file` (CLI) | `Edit`. `Path`, `Target`, and `Replacement` give `file_path`, `old_string`, and `new_string`. `replace_all` is always `true`. |
| `replace_file_content` | `Edit` |
| `multi_replace_file_content` | `MultiEdit` |

The wildcard PreToolUse group, `dispatch-bash.sh --shell-alias-only`, runs for every routed call, as under Claude Code. It passes a `Bash`, `Write`, or `Edit` call at once.

**SessionStart:** the wrapper returns the SessionStart dispatcher's stdout as `{"systemMessage":{"systemMessage":"..."}}`. A failing hook adds `{"errorMessage":{"userMessage":"..."}}`.

**Advisory only under agy:**

- PostToolUse, UserPromptSubmit, and ConfigChange hooks do not run.
- Review agents (Rex, Hakim) and skills that need Claude-only tools do not run inside agy.

## `permissions.deny` under agy

Claude Code applies the `permissions.deny` rules in `.claude/settings.json` itself. agy does not read them. So the wrapper applies them literally, read at run time like the gates. A matching call gets `deny`, and the reason quotes the rule.

| Rule type | Applied to | Match |
|-----------|-----------|-------|
| `Read(<glob>)` | Every string argument of a read-only tool, such as the `read_file` `Path` or a `view_file` path | The path, its lexical form, or its symlink-resolved form matches the glob. The resolved form follows the whole chain, up to 40 links. A loop, a longer chain, or an unreadable link gets `deny`. |
| `Edit(<glob>)` | The file path of `write_file`, `edit_file`, and the other write tools | The same |
| `Write(<glob>)` | The file path of `write_file` and `write_to_file` | The same |
| `Bash(<cmd>)` | `run_command` | The normalized `CommandLine` is `<cmd>` |
| `Bash(<prefix>:*)` | `run_command` | The normalized `CommandLine` is `<prefix>`, or starts with `<prefix>` and a space |

The normalized `CommandLine` is trimmed, and each run of spaces and tabs in it becomes one space.

The `Read(...)` check judges every string argument of a read-only tool, not only a path field, as a path. So a `search_web` query whose last path segment is `.env`, such as `config/.env`, gets `deny`. This over-match fails closed. A query that only mentions `.env` in other words does not match.

Glob rules: a leading `//` is an absolute path, and `~/` is the home folder. A leading `/` is the fork root. A pattern with neither matches anywhere under the fork. `**` is any depth, including none, `*` is one path segment, and `?` is one character. Paths match without case. Over-matching is acceptable, because it fails closed.

With the current rules, agy gets `deny` for these calls:

- reads of `.env` and `.env.*` files, for example `.env.local`. `.envrc` and `src/env.ts` do not match.
- `gh auth token`, with or without arguments,
- `printenv`, with or without arguments, and a bare `env`. `env FOO=1 cmd` still reaches the gates.
- reads of `*.private-key.pem` and `.config/apexyard/*.pem`,
- reads of `.mcp.json`.

Limits:

- Matching is literal, with no shell parser. Pipes, chains, wrapped commands, and absolute command paths are not caught. This is the same limit as the shell-text gates (AgDR-0267).
- A rule never matches a word in the middle of a command, so a search for the word passes.
- Other rule types, such as `WebFetch(...)`, are not applied.
- When the rules cannot be read, a call that names a path or a command gets `deny`.
- The other adapters (Codex, opencode, pi, and Cursor) do not apply these rules yet.

## `ask` and agy's permission check

When every gate passes, the wrapper prints `ask`, never `allow`. `ask` requests agy's own permission check and never auto-approves. Whether agy actually prompts depends on agy's own settings, not on the hook:

- `toolPermission`: `request-review`, which the public reference names as the default, `proceed-in-sandbox`, `always-proceed`, or `strict`,
- `agentMode`,
- the terminal sandbox.

In the contributor's live check of the fork build, no prompt appeared for any `ask` call. So the adapter guarantees the gate denies, and prompting is agy's job.

In headless mode (`agy -p`), agy cannot prompt. In the live check of this port, agy denied a `read_file` that got `ask` (see the `agy -p` open question).

The agy docs conflict on `allow`:

- The bundled `hooks.md` (agy CLI 1.5.14) defines `allow` as "Automatically allow the tool execution". It lists no `auto_approve`.
- The live public page `https://antigravity.google/docs/hooks.md`, fetched 2026-11-21, says `allow` delegates to the next hook or the default policy. It does list `auto_approve`.

`ask` is the safe choice under both readings, so the wrapper uses it.

## Tool policy

`.agents/hooks.json` sends every agy tool to the wrapper through one catch-all matcher, `.*`. The wrapper then puts the tool into one of five classes:

| Class | Tools | Result |
|-------|-------|--------|
| Gated | `run_command`, `write_to_file`, `write_file`, `edit_file`, `replace_file_content`, `multi_replace_file_content` | The settings.json gates decide. A pass gives `ask`. |
| Read-only allowlist | `read_file`, `view_file`, `list_dir`, `find_by_name`, `search_web`, `read_url_content`, `command_status`, `read_terminal`, `ask_question`, `ask_permission`, `list_permissions` | `ask` after the `permissions.deny` `Read(...)` check, and before the fork, gate, and session-snapshot checks |
| Keystrokes | `send_command_input` | Always `deny`. No gate can inspect keystrokes. |
| Task control | `manage_task` | `Action` `list`, `kill`, or `status` gets `ask`. `send_input` gets the keystroke `deny`. A missing or unknown `Action` gets `deny`. |
| Not routed | Every other tool, including subagent, schedule, browser, and `mcp_*` tools | `deny`, with a reason that names the tool |

Why the read-only tools get `ask` early:

- They reach no ApexYard gate. So the fork, gate, and session-snapshot checks cannot change their result, and a broken fork still lets agy read under its own permission check.
- `search_web` and `read_url_content` are allowed for parity with Claude Code, where no gate covers `WebSearch` or `WebFetch`. A URL can carry data out of the machine.
- The `permissions.deny` `Read(...)` rules still apply first. They deny reads of `.env` files, private keys, and `.mcp.json`, which closes the main source for such an exfiltration.
- Each allowed tool reads only what the `Read(...)` check can see. `read_file` and `view_file` read the one path they name. `command_status` and `read_terminal` read the output of a command that the gates already judged. `find_by_name` and `list_dir` return file names, not content.
- `grep_search` is not on the list. It reads the content of every file under a folder, `.env` files included, and a path rule sees only the folder. agy CLI 1.5.14 does not declare it. So it gets the not-routed `deny`, and agy can search with `run_command` instead.

Before the classes apply, the wrapper checks the argument shape. jq keeps the last of two duplicate keys, while agy's Go JSON decoder matches keys case-insensitively. So the wrapper denies a duplicate key in any payload object and a case-variant key in `toolCall` or its args. It also denies an args key outside the tool's key list:

| Tool | Allowed args keys |
|------|-------------------|
| `run_command` | `CommandLine`, `Cwd`, `WaitMsBeforeAsync`, `IsDaemon`, `BypassSandbox`, `toolSummary`. A `RequestedTerminalID`, or a `RunPersistent` other than `false`, gets `deny`: the command runs in an existing terminal whose directory the gates cannot see. agy CLI 1.5.14 does not declare these two keys. A `BypassSandbox` other than absent or `false` gets `deny`: ApexYard does not allow agy to drop its terminal sandbox. `IsDaemon` is allowed, and its `CommandLine` still goes through the gates. |
| `write_file` | `Path`, `Content`, `Append`, `Overwrite`, `ArtifactMetadata`, `toolSummary` |
| `edit_file` | `Path`, `Target`, `Replacement`, `ArtifactMetadata`, `toolSummary` |
| `read_file` | `Path`, `StartLine`, `EndLine`, `ByteOffset`, `toolSummary` |
| `manage_task` | `Action`, `TaskId`, `toolSummary` |
| `write_to_file` | `TargetFile`, `Overwrite`, `CodeContent`, `Description`, `toolSummary` |
| `replace_file_content` | `TargetFile`, `Instruction`, `Description`, `AllowMultiple`, `TargetContent`, `ReplacementContent`, `StartLine`, `EndLine`, `toolSummary` |
| `multi_replace_file_content` | `TargetFile`, `ReplacementChunks`, `toolSummary`. `ReplacementChunks` must be an array of items with only `TargetContent`, `ReplacementContent`, `AllowMultiple`, `StartLine`, and `EndLine`. |

`ArtifactMetadata` must be an object with only `Summary`, `UserFacing`, and `RequestFeedback`.

To extend the policy, edit `harness-adapters/agy/agy-hook.sh`. The lists are hardcoded there, with no config key.

- Add a tool to `READ_ONLY_TOOLS` only after you confirm that it cannot run a command or write a file.
- To gate a tool that runs a command or writes a file, make three changes:
  1. Add a mapping in `build_pretooluse_payload`.
  2. Add the name to `GATED_TOOLS` and to `AGY_TOOLS` in `bin/sync-agy-adapter.sh`. The generator stops when the two lists differ.
  3. Add a test.

## How it works (transport)

- `harness-adapters/agy/agy-hook.sh` is the wrapper. agy runs it for every tool call and at session start.
- The wrapper reads the handler list from `.claude/settings.json` at each call, so the gate list cannot drift. It runs each matching handler command unchanged.
- The wrapper checks that the settings.json resolver finds the wrapper's own fork from the workspace. It denies when the workspace resolves to no fork or to another fork.
- The gate gets `APEXYARD_SESSION_ID` set to the agy `conversationId`. The wrapper removes an inherited `CLAUDE_CODE_SESSION_ID`.
- The gate gets `CLAUDE_PROJECT_DIR` set to the fork root, so the protected-state library protects the fork's `.claude/` whatever folder agy works in. The gates run in the workspace.
- A `run_command` runs in `args.Cwd`, else in the payload's top-level `cwd`, else in the workspace. Each value must be an existing directory. A top-level `cwd` must be inside the fork. When the top-level `cwd` differs from the workspace, a relative `Path`, `TargetFile`, or `args.Cwd` gets `deny`.
- Exit 2 from a gate gives `{"decision":"deny","reason":"<gate stderr>"}`. A wrapper watchdog stops a gate at its `timeout`, or at 30 seconds, and denies.
- The wrapper applies the `permissions.deny` rules before any gate runs (see [`permissions.deny` under agy](#permissionsdeny-under-agy)).
- The wrapper fails closed. Any wrapper error gives `deny`.

## How to install

Run this once in each clone of the fork:

```bash
bash bin/sync-agy-adapter.sh
```

The command writes `.agents/hooks.json`. The file is gitignored, because it holds this clone's absolute path to the wrapper. Check it for drift with `bash bin/sync-agy-adapter.sh --check`.

The catch-all timeout is the largest gated-tool budget: the sum of that tool's gate timeouts, plus 15 seconds. It is above agy's 30 second default. The generator never changes `.agents/skills/`, which `bin/sync-codex-adapter.sh` owns, and a Codex `--clean` keeps `.agents/hooks.json`.

The agy wiring is a protected target in the live fork root, as `.claude/hooks/` is:

- `.agents/hooks.json`,
- the plugin folder `.agents/plugins/` and `.agents/plugins.json`, because agy runs each plugin's own `hooks.json`,
- `harness-adapters/agy/`,
- `bin/sync-agy-adapter.sh`,
- a nested `.agents/hooks.json`, `.agents/plugins.json`, or anything under `.agents/plugins/`, at any depth under the fork root and without case. This includes the `.agents/` config of a managed-project clone under `workspace/`, which matches the read-side check below. Under `.claude/worktrees/<name>/`, only that worktree's own root wiring is exempt, because a linked worktree is its own fork root. A nested form deeper inside the worktree is protected. The exemption goes by the path, so it also covers a folder there that is not a real worktree. If agy starts in such a folder, agy runs the hook config there, and the wrapper denies every tool call.
- a nested `.agents` folder as the target of a recursive copy, a link, or a removal. The same holds for a move whose target is not an existing directory. A move, a link, or a recursive copy into an existing folder is judged at its new path, `<folder>/<name>`. So an `.agents` folder from outside the fork gets `deny`. The folder itself is judged only for the core protected state, such as `.claude/hooks/` and the user config. So a copy or link into `bin/` still passes. A contents copy, from `src/`, from `src/.` or by `ditto`, is judged against the folder in full. So is a source that can land at another name. That covers a flag such as `-T`, `--parents`, `--relative` or `--files-from`. It also covers a glob, a brace or a variable in a recursive copy or link. A plain copy or move with a glob or a variable replaces only direct children of the folder. So each protected name is judged as a child of it: `cp x/* .` passes, and `cp x/* bin/` gets `deny`. The gate also matches these flags inside a short-flag group and as GNU abbreviations, such as `--par`. An unresolved operand that names the agy wiring, such as `$D/.agents/hooks.json`, gets `deny`, as one that names a settings file does. A plain `mkdir` of it stays allowed. A tree that already holds an `.agents/` config, moved, copied, or extracted into place, is not caught.

Write, Edit, MultiEdit, and Bash changes there get `deny`, under agy and Claude Code alike. Change these files in an isolated worktree. `bash bin/sync-agy-adapter.sh` still regenerates `.agents/hooks.json`, because the gate judges only the command text.

agy also reads `.agents/` config in folders between its directory and the fork root. A nested `hooks.json`, `plugins.json`, or `plugins/` there could override the fork's hooks. So on every PreToolUse and SessionStart call, the wrapper checks each folder from agy's directory up to the fork root:

- The walk starts at the top-level `cwd` and at `workspacePaths[0]`, in lexical and physical form. It stops before the fork root, whose `.agents/` is the real wiring.
- It checks only the folders on that path, never a subfolder, so the cost is a few file checks per call.
- A match gets `deny` for every tool, read-only tools included. The reason names the folder and says that the config can override the fork's hooks. It also says that a person must remove it from the live fork, because the gates block an agent's removal. At SessionStart, the same text is an error step.
- A sibling folder is not on the path. A managed project under `workspace/` does not trip the check while agy runs in the fork root. When agy runs inside that project's folder, its `.agents/` config is on the path and gets `deny`.
- A linked worktree is its own fork root, so its `.agents/` is its wiring, and the parent fork's `.agents/` is above the walk.

The Bash check reads the command text, as the other shell-text gates do. A write through an interpreter or an unknown verb, for example a script that a command runs, is not caught (AgDR-0267).

## Decision log

The wrapper can write one JSON line for each hook call. The log is off by default.

- Create `.claude/session/agy-hook-log.enabled` to write to `.claude/session/agy-hooks.log`. Use this switch with agy, because agy may not pass your environment to hooks.
- Or set `APEXYARD_AGY_HOOK_LOG=<path>`.

A line holds the time, the event, the agy and Claude Code tool names, the `conversationId`, and the decision. A deny line also holds the gate, the first 300 characters of the reason, and the sorted args key names. A line holds the first 200 characters of a command, or a file path. It never holds file content.

> **Warning:** command text can hold a secret, for example a token in a `curl` header. Turn the log off when you do not need it.

The wrapper prints its decision before it writes the line, and it ignores logging errors. The payload reaches `jq` on stdin, never as a process argument. The wrapper skips the write when the log file or its folder is a symlink.

## Preconditions

- Run `bash bin/sync-agy-adapter.sh` in the clone first.
- Open agy in the fork root or a folder inside it. A workspace outside the fork gets `deny`.

## Open questions

- **Crash or timeout:** the wrapper's own watchdog and output guard fail closed. A gate that runs too long gets `deny` before agy's timeout, and any wrapper error or malformed output becomes `deny`. The wrapper always exits 0 with one decision. A crash of the wrapper process itself under agy has not been observed live.
- **Workspace trust:** only these facts are observed:
  - agy keeps trusted folders in `trustedWorkspaces` in its user settings.
  - In the fork root, agy loaded `.agents/hooks.json` with no trust step. A parent folder was already in that list.
  - That parent entry did not cover a new linked worktree under the same parent. agy asked the person to trust the worktree before the session started, and then added it to the list. Each earlier linked worktree also has its own entry.
  - agy's bundled docs do not describe workspace trust. A refused trust prompt was not tested.
- **`agy -p`:** the hooks run. Against the fork build, SessionStart injected the context, and an `edit_file` on `.agents/hooks.json` in the fork root got `deny` from `block-protected-target-writes.sh`. Against this port, SessionStart injected the context, and the first calls got `ask`. agy then denied a `read_file` itself, because headless mode cannot prompt. So under `agy -p`, a gate `deny` still applies, and an `ask` call runs only when agy's own settings allow it. agy's message suggests an allow rule under `permissions.allow` in agy's `settings.json`, or a re-run with `--dangerously-skip-permissions`. Neither was tested, and it is not known whether that flag also skips the hooks.
- Does a subagent's own `run_command` reach the workspace hook? Until a check shows it, the subagent tools stay denied.
- Do `ask_permission` and `list_permissions` grant a permission without a user prompt?

## Gaps + tracking

- **Permission rules:** `permissions.deny` is applied literally under agy. Pipes, chains, wrapped commands, and absolute command paths are not caught. Rule types other than `Read`, `Edit`, `Write`, and `Bash` are not applied. The other adapters do not apply these rules yet.
- **Terminal sandbox:** a `run_command` with `BypassSandbox` gets `deny`, because the repo enforces the policy, not agy. The cost: in a linked worktree, agy's git can fail inside its sandbox with "not a git repository: (null)", and agy may retry with `BypassSandbox`. That retry is denied, so git inside a worktree may not work under agy. The fork root is not affected.
- **Agent shell session id:** a PreToolUse hook cannot change the agent's command. So agy's `run_command` shell does not get `APEXYARD_SESSION_ID`.
- **Network reads:** `search_web` and `read_url_content` are in the read-only allowlist. Claude Code has the same path, because no PreToolUse gate covers `WebFetch` or `WebSearch`.
- **`if` predicates:** the wrapper matches a `Bash(<glob>)` predicate against the whole command. Claude Code matches each subcommand. No PreToolUse handler uses `if` today.
- **Nested `.agents/` folders:** agy itself could create a nested hook or plugin config. That write now gets `deny` from the wiring protection, under agy and Claude Code alike. A nested config made outside the gates, for example by a person, is not blocked when it is made. While it sits on the path from agy's directory to the fork root, the wrapper denies every call. The removal of a nested config is matched directly, with no ancestor check, so an `rm -rf` of a parent folder passes.
- **Other adapters:** the Codex, opencode, and pi wiring is not a protected target yet.
- **Conformance CI:** not planned. The terms of service forbid an automated agy run.

## Related AgDRs

- [AgDR-0314](../agdr/AgDR-0314-agy-harness-adapter.md): agy harness adapter
- [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md): Codex adapter generation, the generator and drift-check precedent
- [AgDR-0092](../agdr/AgDR-0092-opencode-gate-adapter.md): opencode adapter, the run-time read of `.claude/settings.json`
- [AgDR-0250](../agdr/AgDR-0250-session-keyed-exemption-markers.md): session-keyed markers and `APEXYARD_SESSION_ID`
- [AgDR-0228](../agdr/AgDR-0228-fail-closed-dispatcher-and-ticket-first.md): `onFailure: block` and measured timeouts
- [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md): hooks stay Bash

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*
