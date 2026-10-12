# ApexYard bootcamp

The Bootcamp pane shows one lesson step beside the Claude Code session.
A wide terminal shows a side pane. A narrow terminal shows an inline pane.
Claude Code selects the placement. Text wraps to fit the pane.

## Install

Run these commands from the ops-fork root:

```bash
claude plugin marketplace add ./ --scope local
claude plugin install apexyard-bootcamp@apexyard --scope local
```

Restart Claude Code or run `/reload-plugins` after an update.

## Use

- `/bootcamp` opens or closes the pane.
- `/bootcamp-next` shows the next step. It crosses module boundaries.
- `/bootcamp-back` shows the previous step. It crosses module boundaries.
- `/bootcamp-goto <module> <step>` selects a step. Numbers start at one.
- `/bootcamp-reset` returns to the first step and clears all checkpoints.

Next and back stop at the course bounds. Goto clamps numbers to valid bounds.
Invalid goto arguments leave progress unchanged. Navigation does not require a ticked checkpoint.

The pane shows the module header, progress row, slide text, command, checkpoint, presenter note, and navigation hint.
`[>]` marks the current step. `[x]` marks a ticked checkpoint. `[ ]` marks another step.
Replace command placeholders with actual ticket and PR numbers.

## Content format

Create one Markdown file for each module under `content/NN-<slug>.md`.
Two digits define the module order. Use lowercase letters, digits, and hyphens in the slug.
Start each file with `# Module title`. Each `## Step title` starts a step.
Put body text before optional metadata lines:

```markdown
# Setup

## Configure ApexYard
Run /setup from the ops fork. Answer the company and tool questions.
Try: /setup
Check: skill setup
Done: Setup call observed.
Note: Explain the company settings.
```

- `Try: <command>` displays a suggested command or plain request.
- `Check: skill <name>` matches a skill prompt or Skill call with that exact name, ignoring a plugin prefix.
- `Check: bash <regex>` matches a Bash command with a case-insensitive JavaScript regex.
- `Done: <text>` supplies the ticked checkpoint text.
- `Note: <presenter note>` displays dim text.

Each field can appear once per step. Empty fields and invalid regexes produce an error.
Body text is required. The pane shows body text as terminal text, including any Markdown markers.
A malformed module shows its file name and parser error. Navigation can move past that module.
Use three to six steps for each generic module. Use short active sentences with at most 20 words.
Avoid nested quantifiers in content regexes. Commands longer than 32,000 characters do not tick Bash checkpoints. Real PR commands with an inline body reach about 7,000 characters.
Use ASCII content and real ApexYard skill names. Keep Corner Shop as the sample project.

## Bundle content

The status plugin uses `$.fs.read` for runtime file reads.
This plugin imports bundled Markdown strings. It pairs well with the explainer pane when installed.
The runtime makes no file calls. After you edit content, run:

```bash
node plugins/apexyard-bootcamp/scripts/build-content.mjs
node plugins/apexyard-bootcamp/scripts/build-content.mjs --check
```

The build script writes `hooks/content.generated.ts`. The check fails when that file is stale.
Run both the plugin tests and the Node bundle test before you submit a change.

## Progress and checkpoints

The `atom`, `read`, and `update` helpers keep module, step, and checkpoint state in the plugin store (`$.store`).
They call the state API, as the reference plugins do.
The host persists the store. Closing the pane does not clear progress.
A restart resumes the stored step. Reset clears stored checkpoints.

Only the current step can tick. Matching events still tick while the pane is closed.
A step without `Check:` never ticks. A plain request alone cannot tick a checkpoint.
A checkpoint confirms a matching skill prompt or tool call after the existing handler returns.
Denied tool calls do not tick. Skill prompts include typed commands, Skill calls, and subagent preloads.
The skill event has no origin field, so a matching preload can tick. It does not prove success, approval, or a completed merge.
The plugin passes skill prompts and tool calls to the existing handler. It never replaces a governance hook.

## Tests

```bash
claude plugin validate --strict plugins/apexyard-bootcamp
claude plugin test plugins/apexyard-bootcamp
node --test plugins/apexyard-bootcamp/scripts/content.test.mjs
```

## Scope

The runtime displays local content and updates the plugin store only.
It makes no model, network, process, or file calls. It writes no files.
The build script and Node test use local files outside the runtime.
The early-access pane API can change. A pane failure does not change any governance gate.

## Glossary

- Module: one Markdown file with ordered steps.
- Checkpoint: a condition that a matching session tool call satisfies.
- PR: pull request, which presents a code change for review.
- Store: host-managed plugin state that survives a session restart.
