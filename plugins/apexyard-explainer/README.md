# ApexYard explainer

## What it shows

The pane shows one plain sentence for each tool call. Each line explains the call and its purpose.

```text
Reads the file app.ts to learn the code.
Runs the tests to check the change.
Pushes the branch to share the change.
```

## Rules

- Display only.
- Local descriptions and templates only.
- No model, network or process calls.
- No file writes.
- It keeps only the last 5 lines in session memory, even when the pane is closed.

## Install

Run these two commands from the ops-fork root:

```bash
claude plugin marketplace add ./ --scope local
claude plugin install apexyard-explainer@apexyard --scope local
```

The local scope enables the plugin only for you on this machine.

Run this command to remove it:

```bash
claude plugin uninstall apexyard-explainer@apexyard --scope local
```

## Use

Type `/explainer-toggle` to open or close the pane.
A wide terminal shows a sidebar beside the transcript.
A narrow terminal shows a box above the prompt.
Claude Code places the pane. The text wraps to fit.

The name cannot be `/explainer:toggle`.
Claude Code command names allow only letters, digits, `_` and `-`.

## Writing rule

Use ASD-STE100 Simplified Technical English for each line.
Use one sentence with 15 words or fewer for templates, simple common words and active voice.
Start each line with a present-tense verb, such as “Reads” or “Runs”.
End each line with a full stop.
Say what the call does and why. A test checks the template word limit.
Names and patterns use one short word to keep lines short.
For a tool with no template, the line is "Runs the tool `<name>`."

## Coverage and fallback order

1. Use the call's non-empty `description` first. Replace whitespace with spaces,
   trim it, cap the line at 120 characters, and end it with a period.
   Agent and Task reviews keep the reviewer template.
2. Use an existing template. Bash still detects git, gh, and test commands.
3. For `mcp__<server>__<tool>`, use "Uses <Server>: <tool words>."
   Remove a leading `claude_ai_` from the server. Replace underscores and
   hyphens with spaces and title-case the server.
4. Use the built-in templates below.
5. Use the generic line for an unknown tool.

Descriptions and commands are checked before shortening. Token-like text
(`ghp_`, `sk-`, `xox`, or a run of 32 or more base64 or hex characters)
causes the description to fall back to a template. Commands are never shown.
Descriptions and MCP names can exceed the template word limit.
All of this runs locally, with zero model or network calls.

## Tools and lines

| Tool or call | Line |
|---|---|
| Read | Reads the file {file} to learn the code. |
| Edit, MultiEdit | Edits the file {file} to change the code. |
| Write | Writes the file {file} to save new content. |
| Grep | Searches the code for {pattern} to find where it appears. |
| Glob | Looks for files that match {pattern} to find the right ones. |
| Agent or Task with a type | Asks the {agent} agent to do one part of the work. |
| Agent or Task with no type | Asks a helper agent to do one part of the work. |
| Agent or Task for a review | Asks a reviewer agent to check the PR. |
| Skill | Runs the skill {skill} to follow its steps. |
| WebFetch | Reads a web page to get facts for the task. |
| WebSearch | Searches the web to find facts for the task. |
| TodoWrite, TaskCreate, TaskUpdate | Updates the task list to track the work. |
| AskUserQuestion | Asks you a question to choose the next step. |
| Workflow | Runs a multi-agent workflow to split the work. |
| ToolSearch | Loads more tools for the next step. |
| SendMessage | Sends a message to another agent. |
| Monitor | Watches a background task until it finishes. |
| TaskStop | Stops a background task. |
| Artifact | Publishes or reads a web page made for this session. |
| LSP | Asks the language server about the code. |
| NotebookEdit | Edits a notebook cell. |
| ScheduleWakeup | Sets a time to continue the work. |
| ReadNotifications | Reads new notifications for this session. |
| BashOutput, TaskOutput, task-output, task_output | Reads the output of a background command. |
| Other tools | Runs the tool `{tool}`. |
| Bash: test run | Runs the tests to check the change. |
| Bash: git status | Checks git status to see what changed. |
| Bash: git diff, git show | Shows the git diff to review the changes. |
| Bash: git log | Reads the git log to learn the recent history. |
| Bash: git add | Adds files to the next commit to prepare it. |
| Bash: git commit | Makes a git commit to save the change. |
| Bash: git push | Pushes the branch to share the change. |
| Bash: git fetch, git pull | Gets new commits from the remote to stay current. |
| Bash: git checkout, git switch, git branch | Changes or lists git branches to keep work apart. |
| Bash: git worktree | Makes or removes a separate work folder for the task. |
| Bash: other git command | Runs a git command to manage the code history. |
| Bash: gh pr create | Opens a pull request so others can review the change. |
| Bash: gh pr merge | Merges the pull request to finish the change. |
| Bash: gh pr review, gh pr comment | Adds a review or comment on the pull request. |
| Bash: other gh pr command | Reads the pull request to check its status. |
| Bash: gh issue create | Opens a new issue to track the work. |
| Bash: other gh issue command | Reads the issue to learn what to build. |
| Bash: other gh command | Runs a GitHub command to work with the repository. |
| Bash: other shell command | Runs a shell command to do one step of the task. |

`{file}`, `{pattern}`, `{agent}`, `{skill}` and `{tool}` mark names in the templates.
The plugin inserts a short name from the call.

## Tests

```bash
claude plugin validate --strict plugins/apexyard-explainer
claude plugin test plugins/apexyard-explainer
```

## Risk

The hook API is early access. If it breaks, the pane disappears. No gate is affected.
