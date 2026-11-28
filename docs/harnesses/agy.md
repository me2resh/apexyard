# Harness support: agy (Antigravity CLI)

**Status:** ✅ **Live-checked on the fork build (2026-11-21) and on this port (2026-11-22)** for `run_command`, `write_file`, `edit_file`, `read_file`, and SessionStart. The contributor ran agy CLI 1.5.14 against both. In each check, a real turn's `git add -A` got `deny` from the unmodified `dispatch-bash.sh`, and the index stayed empty. Edits to `.claude/settings.json` got `deny` from `block-protected-target-writes.sh`. Decision record: [AgDR-0325](../agdr/AgDR-0325-agy-harness-adapter.md).

**Contract checked against:** agy CLI 1.5.14, bundled hooks reference `~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md`. That file is more current than the public web page. The `run_command` argument keys also cover agy CLI 1.5.17, which adds `NotificationTimeoutSeconds`. Check this page again after an agy upgrade.

agy is the Google Antigravity CLI, a terminal coding agent. agy loads the fork's `AGENTS.md` and `.agents/skills/`, so it receives the rules as text. The adapter adds the mechanical gates. It routes agy hook events to the same unmodified `.claude/hooks/*.sh` gates that Claude Code runs.

## Terms of service limit

Google's terms forbid driving agy from another agent. So no agent, harness, or CI job runs agy. A person, not an agent, runs agy for every live check on this page.

## Verification

- **Unit tests:** `.claude/hooks/tests/test_agy_adapter.sh` feeds agy payloads to the wrapper. No test runs agy. The payloads in `.claude/hooks/tests/fixtures/agy-payloads/` have the key shapes that agy CLI 1.5.14 sent, with synthetic values (see that folder's README).
  - `git add -A` gets `deny` from the real `block-git-add-all.sh`. `git status` gets `ask`.
  - A code-path `write_file` gets `deny` from the real `require-active-ticket.sh` without a ticket, and `ask` with one.
  - A `write_file` or `edit_file` to `.claude/settings.json` gets `deny`, also when agy works in a subfolder of the fork.
  - A `run_command` that names a protected file, such as `cat .env`, gets `deny` from a `Read(...)` rule, also with `BypassSandbox: true`.
  - A boolean `BypassSandbox` and a non-negative integer `NotificationTimeoutSeconds` reach the real gates. Any other value of either key gets `deny`.
  - Malformed stdin, a missing `jq`, a missing gate, a gate timeout, an unrouted tool, and a duplicate or case-variant argument key each get `deny`.
  - No output is `allow`, `force_ask`, or `auto_approve`. A test checks that every decision emit path in the wrapper source is `ask` or `deny`.
- **Wiring test:** `.claude/hooks/tests/test_protected_agy_wiring.sh` checks that the agy wiring is a protected target in the live fork root and editable in a worktree.
- **Live, fork build (2026-11-21, agy CLI 1.5.14):** the contributor ran agy CLI 1.5.14 against the fork build of this adapter. These calls come from the decision log:

| agy tool | Call | Decision | Gate or result |
|----------|------|----------|----------------|
| SessionStart | none | inject | agy quoted the injected ApexYard text |
| `run_command` | `git status` | ask | ran |
| `run_command` | `git add -A` | deny | `dispatch-bash.sh` |
| `write_file` | create a file in `src/` | ask | the write succeeded |
| `edit_file` | edit that file | ask | the edit succeeded |
| `read_file` | `ByteOffset` 0 | ask | the read succeeded |
| `edit_file` | `.claude/settings.json` | deny | `block-protected-target-writes.sh`: "the edit target is live hook state" |
| `manage_task` | `kill`, `list` | ask | ran |
| `edit_file` | `.agents/hooks.json` in the fork root | deny | `block-protected-target-writes.sh`: "the edit target is live hook state" |
| `run_command` | `rm .agents/hooks.json` in the fork root | deny | "protected target: .agents/hooks.json" |
| SessionStart, `agy -p` | none | inject | the headless run injected the ApexYard text |
| `edit_file`, `agy -p` | `.agents/hooks.json` in the fork root | deny | `block-protected-target-writes.sh`: "the edit target is live hook state. Use an isolated worktree." |

The last two rows come from one headless `agy -p` run, so the hooks run in non-interactive mode too. agy printed the deny reason and did not change the file. The fork build protects the agy wiring through a wider list that also covers other adapters. This port protects only the agy wiring, so here the same deny comes from different code.

In the fork root, agy loaded `.agents/hooks.json` with no trust step. agy already trusted a parent folder (see the workspace-trust open question below). agy showed no permission prompt for any `ask` call (see [`ask` and agy's permission check](#ask-and-agys-permission-check)).

- **Live, this port (2026-11-22, agy CLI 1.5.14):** the contributor ran agy in a linked worktree that holds this branch. `bin/sync-agy-adapter.sh` wired that worktree, so agy used it as the fork root. These calls come from the decision log:

| agy tool | Call | Decision | Gate or result |
|----------|------|----------|----------------|
| SessionStart | none | inject | agy quoted the injected ApexYard text |
| `run_command` | `git add -A` | deny | `dispatch-bash.sh` |
| `read_file` | `.claude/settings.json` | ask | the read succeeded |
| `edit_file` | `.claude/settings.json` | deny | `block-protected-target-writes.sh`: "the edit target is live hook state" |
| `write_file`, `read_file` | a new file, then a read of it | ask | both succeeded |
| `read_file` | a test file named `*.private-key.pem` | deny | the `permissions.deny` rule `Read(//**/*.private-key.pem)` |
| `run_command` | `pwd` with `BypassSandbox: true` | deny | the wrapper's sandbox check. The wrapper no longer applies it since 2026-11-28 (see the terminal sandbox gap). |
| `write_file` | a nested `sub/.agents/hooks.json` | deny | `block-protected-target-writes.sh`: "the edit target is live hook state" |
| `run_command` | `ls` | ask | ran |
| SessionStart, `agy -p` | none | inject | the headless run injected the ApexYard text |
| `run_command`, `read_file`, `agy -p` | the model's first two calls | ask | agy denied the `read_file` itself, because headless mode cannot prompt, and the run ended with no output |

The gate denied the nested write, so the nested `.agents/` walk found no config, and the live check did not exercise its deny. An earlier run in the same worktree, before the setup script wired it, ran no hook. So agy did not read the `.agents/hooks.json` of the main checkout, which is a parent folder. In that run, `git` failed under agy's default sandbox with "not a git repository". This failure is one reason the wrapper now allows a boolean `BypassSandbox`.

**Not verified live on this port:** an edit of the root `.agents/hooks.json` and the persistent-terminal deny. The live check also did not verify the `Bash` rules of `permissions.deny`, or the nested `.agents/` walk with an existing nested config. The `Bash` rules name secret-printing commands, so the live check did not run them. agy CLI 1.5.14 did not use `replace_file_content`, `multi_replace_file_content`, or `write_to_file`, so the live check did not verify them.

## Enforcement vs advisory today

**Enforced (blocking):** every PreToolUse gate in `.claude/settings.json` for the `Bash`, `Write`, `Edit`, and `MultiEdit` tools. This includes the Bash dispatcher, ticket-first, the migration-ticket gate, the protected-target gate, and the reviewer-write limit. The wrapper reads gates and `permissions.deny` rules only from `.claude/settings.json`. It ignores `.claude/settings.local.json` and user settings. Any gate or deny rule from those files does not run under agy.

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

Claude Code applies the `permissions.deny` rules in `.claude/settings.json` itself. agy does not read them. So the wrapper applies them as written. It reads them at run time, as the gates do. A matching call gets `deny`, and the reason quotes the rule.

| Rule type | Applied to | Match |
|-----------|-----------|-------|
| `Read(<glob>)` | Every string argument of a read-only tool, such as the `read_file` `Path` or a `view_file` path. Each word of a `run_command` that names a path (see the next section). | The path, its lexical form, or its symlink-resolved form matches the glob. The resolved form follows the whole chain, up to 40 links. A loop, a longer chain, or an unreadable link gets `deny`. |
| `Edit(<glob>)` | The file path of `write_file`, `edit_file`, and the other write tools | The same |
| `Write(<glob>)` | The file path of `write_file` and `write_to_file` | The same |
| `Bash(<cmd>)` | `run_command` | The normalized `CommandLine` is `<cmd>` |
| `Bash(<prefix>:*)` | `run_command` | The normalized `CommandLine` is `<prefix>`, or starts with `<prefix>` and a space |

The wrapper trims the normalized `CommandLine`, and turns each run of spaces and tabs in it into one space.

The `Read(...)` check judges every string argument of a read-only tool, not only a path field, as a path. So a `search_web` query whose last path segment is `.env`, such as `config/.env`, gets `deny`. This over-match fails closed. A query that only mentions `.env` in other words does not match.

### `Read(...)` rules and shell commands

A `run_command` can run outside agy's terminal sandbox, because the wrapper allows a boolean `BypassSandbox` (see the argument-key table under [Tool policy](#tool-policy)). So the gates must protect shell commands as they do for Claude Code. Claude Code refuses a shell command that names a path that a `Read(...)` rule covers. The wrapper does the same for a `run_command`:

1. The wrapper splits the `CommandLine` into words. It splits on spaces, tabs, newlines, and the characters `|`, `;`, `&`, `<`, `>`, `(`, `)`, and the backtick.
2. It removes the quote characters from each word. It removes each backslash and keeps the character after it, as the shell does. So `.e\nv` gives `.env`.
3. For a word that contains `=`, it keeps only the text after the first `=`. So `--env-file=.env` gives `.env`.
4. It resolves a word only when its last path segment matches the last segment of a `Read(...)` rule. A relative word resolves against the command directory. A `~/` word resolves against the home folder.
5. It judges each resolved path as for a read-only tool.

So `cat .env`, `grep KEY config/.env.local`, `wc -l < .env`, and `cat ~/proj/.mcp.json` get `deny`. Commands that do not name a protected file still reach the gates. Examples are `git status`, `php artisan test`, `grep -r APP_ENV config/`, `cat .envrc`, and `APP_ENV=testing php artisan test`.

The check does not know which words a command reads. So a protected name that appears only as text also gets `deny`. ApexYard accepts this over-match, because it fails closed, as Claude Code does. Examples and workarounds:

| Command | Workaround |
|---------|------------|
| `echo .env >> .gitignore` | Edit `.gitignore` with the file tools. |
| `grep -n '\.env' .gitignore` | Use a pattern that does not name the file, such as `grep -n 'env$' .gitignore`. |
| A commit message that names `.env`, given with `-m` | Write the message to a file, and use `git commit -F <file>`. |
| `cp .env.example .env` | A person runs it. |

The check has no shell parser (AgDR-0267). These cases stay `ask` and reach the gates:

- a recursive read of a folder, such as `grep -rn DB_PASSWORD .`, which can print `.env` content. Claude Code has the same gap.
- a path built at run time: a glob (`cat .en*`), a brace expansion (`cat .{e,}nv`), a command substitution, or a variable.
- a symlink with an ordinary name that points at a `.env` file.
- ANSI-C or locale quoting (`$'...'` and `$"..."`), which can hide a protected name from the word check.
- a `cd` or `pushd` earlier in the same `CommandLine`. It changes the directory of the later words, but the check resolves a relative word against the directory of the call.
- a `~user` path. The check expands only `~/`.

A command that runs outside the sandbox gets the environment of the terminal that started agy, the same as Claude Code. Keep tokens out of that environment.

Glob rules: a leading `//` is an absolute path, and `~/` is the home folder. A leading `/` is the fork root. A pattern with neither matches anywhere under the fork. `**` is any depth, including none, `*` is one path segment, and `?` is one character. Paths match without case. Over-matching is acceptable, because it fails closed.

With the current rules, agy gets `deny` for these calls:

- reads of `.env` and `.env.*` files, for example `.env.local`. `.envrc` and `src/env.ts` do not match.
- `gh auth token`, with or without arguments,
- `printenv`, with or without arguments, and a bare `env`. `env FOO=1 cmd` still reaches the gates.
- reads of `*.private-key.pem` and `.config/apexyard/*.pem`,
- reads of `.mcp.json`.

Limits:

- Matching is literal, with no shell parser. A `Bash(...)` rule does not catch pipes, chains, wrapped commands, or absolute command paths. This is the same limit as the shell-text gates (AgDR-0267).
- A `Bash(...)` rule never matches a word in the middle of a command, so a search for the word passes. A `Read(...)` rule does judge each word of a command, as the previous section describes.
- The wrapper does not apply other rule types, such as `WebFetch(...)`.
- When the wrapper cannot read the rules, a call that names a path or a command gets `deny`.
- The wrapper reads rules only from `.claude/settings.json`. It ignores `.claude/settings.local.json` and user settings.
- The other adapters (Codex, opencode, pi, and Cursor) do not apply these rules yet.

## `ask` and agy's permission check

When every gate passes, the wrapper prints `ask`, never `allow`. `ask` requests agy's own permission check and never auto-approves. Whether agy prompts depends on agy's own settings, not on the hook:

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
- The wrapper allows `search_web` and `read_url_content` for parity with Claude Code, where no gate covers `WebSearch` or `WebFetch`. A URL can carry data out of the machine.
- The `permissions.deny` `Read(...)` rules still apply first. They deny reads of `.env` files, private keys, and `.mcp.json`, which closes the main source for such an exfiltration.
- Each allowed tool reads only what the `Read(...)` check can see. `read_file` and `view_file` read the one path they name. `command_status` and `read_terminal` read the output of a command that the gates already judged. `find_by_name` and `list_dir` return file names, not content.
- `grep_search` is not on the list. It reads the content of every file under a folder, `.env` files included, and a path rule sees only the folder. agy CLI 1.5.14 does not declare it. So it gets the not-routed `deny`, and agy can search with `run_command` instead.

Before the classes apply, the wrapper checks the argument shape. jq keeps the last of two duplicate keys, while agy's Go JSON decoder matches keys case-insensitively. So the wrapper denies a duplicate key in any payload object and a case-variant key in `toolCall` or its args. It also denies an args key outside the tool's key list:

| Tool | Allowed args keys |
|------|-------------------|
| `run_command` | `CommandLine`, `Cwd`, `WaitMsBeforeAsync`, `IsDaemon`, `BypassSandbox`, `NotificationTimeoutSeconds`, `toolSummary`. A `RequestedTerminalID`, or a `RunPersistent` other than `false`, gets `deny`: the command runs in an existing terminal whose directory the gates cannot see. agy CLI 1.5.14 does not declare these two keys. The wrapper allows a boolean `BypassSandbox`, and its `CommandLine` still goes through `permissions.deny` and every gate. A `BypassSandbox` that is not a boolean gets `deny`. agy CLI 1.5.17 sends `NotificationTimeoutSeconds`. The wrapper allows it when it is a non-negative integer, and any other value gets `deny`. The wrapper allows `IsDaemon`, and its `CommandLine` still goes through the gates. |
| `write_file` | `Path`, `Content`, `Append`, `Overwrite`, `ArtifactMetadata`, `toolSummary` |
| `edit_file` | `Path`, `Target`, `Replacement`, `ArtifactMetadata`, `toolSummary` |
| `read_file` | `Path`, `StartLine`, `EndLine`, `ByteOffset`, `toolSummary` |
| `manage_task` | `Action`, `TaskId`, `toolSummary` |
| `write_to_file` | `TargetFile`, `Overwrite`, `CodeContent`, `Description`, `toolSummary` |
| `replace_file_content` | `TargetFile`, `Instruction`, `Description`, `AllowMultiple`, `TargetContent`, `ReplacementContent`, `StartLine`, `EndLine`, `toolSummary` |
| `multi_replace_file_content` | `TargetFile`, `ReplacementChunks`, `toolSummary`. `ReplacementChunks` must be an array of items with only `TargetContent`, `ReplacementContent`, `AllowMultiple`, `StartLine`, and `EndLine`. |

`ArtifactMetadata` must be an object with only `Summary`, `UserFacing`, and `RequestFeedback`.

To extend the policy, edit `harness-adapters/agy/agy-hook.sh`. The wrapper holds the lists there, with no config key.

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

The command writes `.agents/hooks.json`. Git ignores the file, because it holds this clone's absolute path to the wrapper. Check it for drift with `bash bin/sync-agy-adapter.sh --check`.

The catch-all timeout is the largest gated-tool budget: the sum of that tool's gate timeouts, plus 15 seconds. It is above agy's 30 second default. The generator never changes `.agents/skills/`, which `bin/sync-codex-adapter.sh` owns, and a Codex `--clean` keeps `.agents/hooks.json`.

The agy wiring is a protected target in a live ApexYard fork root, as `.claude/hooks/` is. A fork root holds `.claude/hooks` and either `.apexyard-fork` or `onboarding.yaml`:

- `.agents/hooks.json`,
- the plugin folder `.agents/plugins/` and `.agents/plugins.json`, because agy runs each plugin's own `hooks.json`,
- `harness-adapters/agy/`,
- a nested `.agents/hooks.json`, `.agents/plugins.json`, or anything under `.agents/plugins/`, at any depth under the fork root and without case, except under `workspace/`. Managed-project clones under `workspace/` stay editable. If agy starts inside one, the wrapper's `check_nested_agents` still denies every call. Under `.claude/worktrees/<name>/`, that worktree's own root wiring and `workspace/` subtree stay editable, because a linked worktree is its own fork root. The gate protects a nested form deeper inside the worktree. The exemption goes by the path, so it also covers a folder there that is not a real worktree. If agy starts in such a folder, agy runs the hook config there, and the wrapper denies every tool call.
- a nested `.agents` folder (outside `workspace/`) as the target of a recursive copy, a link, or a removal. The same holds for a move whose target is not an existing directory. A plain `mkdir` of it stays allowed. For a move, a link, or a recursive copy into an existing folder, the gate judges each source at its new path, `<folder>/<name>`. So an `.agents` folder from outside the fork gets `deny`. The gate judges the folder itself only for the core protected state, such as `.claude/hooks/` and the user config. So a copy or link into `harness-adapters/` or `.agents/` still passes. The gate judges the whole folder for a contents copy, from `src/`, from `src/.` or by `ditto`. It does the same for a source that can land at another name. That covers a flag such as `-T`, `--parents`, `--relative` or `--files-from`. It also covers a glob, a brace or a variable in a recursive copy or link. The gate also matches these flags inside a short-flag group and as GNU abbreviations, such as `--par`. A plain copy or move with a glob or a variable replaces only direct children of the folder. So the gate judges each protected name as a child of it: `cp x/* .` passes, and `cp x/* .agents/` or `cp x/* harness-adapters/` gets `deny`. For a dot-glob move, such as `mv x/.* .`, the gate judges `.agents` and `.claude` as children only at the live fork root. Dot-glob moves inside subfolders and `workspace/` pass. A move whose source is a variable or a brace can still bring an `.agents` folder into a folder that has none (AgDR-0267). A live root that agy uses already has a non-empty `.agents/`, which `mv` does not replace. In a fork session, an unresolved operand that names the agy wiring, such as `$D/.agents/hooks.json`, gets `deny`. One that names a settings file does the same. So does an unresolved removal that ends in `.agents` or `harness-adapters`, such as `rm -rf "$TMPDIR/.agents"`, as one that ends in `.claude` does on `dev`. The gate does not catch a tree that already holds an `.agents/` config when a command moves, copies, or extracts it into place.

The gate excludes `bin/sync-agy-adapter.sh` from the protected list, because agy runs only `.agents/hooks.json` and `harness-adapters/agy/agy-hook.sh`. So ordinary commands on `bin/` pass in every root. The gate also excludes non-fork project roots and sessions with no live root from the agy wiring forms.

Write, Edit, MultiEdit, and Bash changes to the protected wiring get `deny`, under agy and Claude Code alike. Change these files in an isolated worktree. `bash bin/sync-agy-adapter.sh` still regenerates `.agents/hooks.json`, because the gate judges only the command text.

agy also reads `.agents/` config in folders between its directory and the fork root. A nested `hooks.json`, `plugins.json`, or `plugins/` there could override the fork's hooks. So on every PreToolUse and SessionStart call, the wrapper checks each folder from agy's directory up to the fork root:

- The walk starts at the top-level `cwd` and at `workspacePaths[0]`, in lexical and physical form. It stops before the fork root, whose `.agents/` is the real wiring.
- It checks only the folders on that path, never a subfolder, so the cost is a few file checks per call.
- A match gets `deny` for every tool, read-only tools included. The reason names the folder and says that the config can override the fork's hooks. It also says that a person must remove it from the live fork, because the gates block an agent's removal. At SessionStart, the same text is an error step.
- A sibling folder is not on the path. A managed project under `workspace/` does not trip the check while agy runs in the fork root. When agy runs inside that project's folder, its `.agents/` config is on the path and gets `deny`.
- A linked worktree is its own fork root, so its `.agents/` is its wiring, and the parent fork's `.agents/` is above the walk.

The Bash check reads the command text, as the other shell-text gates do. The check does not catch a write through an interpreter or an unknown verb, for example a script that a command runs (AgDR-0267).

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

- **Crash or timeout:** the wrapper's own watchdog and output guard fail closed. A gate that runs too long gets `deny` before agy's timeout, and any wrapper error or malformed output becomes `deny`. The wrapper always exits 0 with one decision. No live check has seen a crash of the wrapper process itself under agy.
- **Workspace trust:** the live checks show only these facts:
  - agy keeps trusted folders in `trustedWorkspaces` in its user settings.
  - In the fork root, agy loaded `.agents/hooks.json` with no trust step. A parent folder was already in that list.
  - That parent entry did not cover a new linked worktree under the same parent. agy asked the person to trust the worktree before the session started, and then added it to the list. Each earlier linked worktree also has its own entry.
  - agy's bundled docs do not describe workspace trust. No live check refused a trust prompt.
- **`agy -p`:** the hooks run. Against the fork build, SessionStart injected the context, and an `edit_file` on `.agents/hooks.json` in the fork root got `deny` from `block-protected-target-writes.sh`. Against this port, SessionStart injected the context, and the first calls got `ask`. agy then denied a `read_file` itself, because headless mode cannot prompt. So under `agy -p`, a gate `deny` still applies, and an `ask` call runs only when agy's own settings allow it. agy's message suggests an allow rule under `permissions.allow` in agy's `settings.json`, or a re-run with `--dangerously-skip-permissions`. No live check tried either, and nobody knows yet whether that flag also skips the hooks.
- Does a subagent's own `run_command` reach the workspace hook? Until a check shows it, the subagent tools stay denied.
- Do `ask_permission` and `list_permissions` grant a permission without a user prompt?

## Gaps + tracking

- **Permission rules:** under agy, the wrapper applies `permissions.deny` as written. It reads gates and rules only from `.claude/settings.json`, not from `.claude/settings.local.json` or user settings. A `Bash(...)` rule does not catch pipes, chains, wrapped commands, or absolute command paths. A `Read(...)` rule judges each word of a command, but it does not see a path built at run time or a recursive folder read. The wrapper does not apply rule types other than `Read`, `Edit`, `Write`, and `Bash`. The other adapters do not apply these rules yet.
- **Terminal sandbox:** the wrapper allows a boolean `BypassSandbox`. In agy CLI 1.5.7 and later, `agentMode` is `auto` by default. Auto mode turns the terminal sandbox on even when `enableTerminalSandbox` is `false`, and it removes that key from `settings.json` at startup. Inside the sandbox, git in a linked worktree, `gh`, and network calls fail, and agy retries with `BypassSandbox: true`. The first version of this adapter denied that retry, so those commands could not run under agy. A command that runs outside the sandbox still goes through `permissions.deny`, the `Read(...)` check of each word, and every gate. The wrapper prints `ask` for such a command. agy's bundled `hooks.md` defines `ask` as a prompt that respects agy's Always Allow list. agy's own settings also decide whether it prompts (see [`ask` and agy's permission check](#ask-and-agys-permission-check)). The cost: the sandbox is no longer a second layer under the gates for that command. The `Read(...)` check of each word covers the main loss, the shell read of a protected file. Its limits are in [`Read(...)` rules and shell commands](#read-rules-and-shell-commands).
- **Agent shell session id:** a PreToolUse hook cannot change the agent's command. So agy's `run_command` shell does not get `APEXYARD_SESSION_ID`.
- **Network reads:** `search_web` and `read_url_content` are in the read-only allowlist. Claude Code has the same path, because no PreToolUse gate covers `WebFetch` or `WebSearch`.
- **`if` predicates:** the wrapper matches a `Bash(<glob>)` predicate against the whole command. Claude Code matches each subcommand. No PreToolUse handler uses `if` today.
- **Nested `.agents/` folders:** agy itself could create a nested hook or plugin config. That write now gets `deny` from the wiring protection (outside `workspace/`), under agy and Claude Code alike. The gates do not block a nested config under `workspace/`, or one that someone creates outside the gates. While it sits on the path from agy's directory to the fork root, the wrapper denies every call. The gate matches the removal of a nested config directly, with no ancestor check, so an `rm -rf` of a parent folder passes.
- **Other adapters:** the Codex, opencode, and pi wiring is not a protected target yet.
- **Conformance CI:** not planned. The terms of service forbid an automated agy run.

## Related AgDRs

- [AgDR-0325](../agdr/AgDR-0325-agy-harness-adapter.md): agy harness adapter
- [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md): Codex adapter generation, the generator and drift-check precedent
- [AgDR-0092](../agdr/AgDR-0092-opencode-gate-adapter.md): opencode adapter, the run-time read of `.claude/settings.json`
- [AgDR-0250](../agdr/AgDR-0250-session-keyed-exemption-markers.md): session-keyed markers and `APEXYARD_SESSION_ID`
- [AgDR-0228](../agdr/AgDR-0228-fail-closed-dispatcher-and-ticket-first.md): `onFailure: block` and measured timeouts
- [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md): hooks stay Bash

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*
