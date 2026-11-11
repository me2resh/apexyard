---
id: AgDR-0295
timestamp: 2026-11-11T08:00:00Z
agent: platform-engineer
model: claude-opus-5-5
session: gh1922-gate-band-plugin
trigger: user-prompt
status: executed
category: architecture
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# AgDR-0295: Split gate work between the hooks, the Claude Code mod, and the Cockpit

> In the context of ORBIT outcome o8, facing a need to show gate state and collect approvals inside Claude Code, I decided that the bash hooks enforce, an opt-in mod shows state and asks for approval through the AgDR-0234 menu hook, and the Cockpit keeps the views outside one session. This keeps one enforcement core, accepting a second key press for each approval.

## Context

Issue me2resh/apexyard#1922 is the build slice for outcome `o8-claude-code-gate-mod`. Criteria ac8-1 to ac8-6 apply.

- A mod is a Claude Code plugin with function hooks. It runs inside one Claude Code session.
- The `apexyard-status` plugin already draws a band above the prompt. It shows the active ticket, the waiting PRs and the reviewer lock. It did not show CI state.
- No approval pane existed.
- AgDR-0234 records a human merge approval from the harness question tool. The `record-menu-approval.sh` PostToolUse hook writes the record. The question must name the repo, the PR and the full 40-hex head SHA.
- Plan constraints C5 to C7 apply. The mod is Claude Code only. The mod is a guardrail, not a security boundary. The bash core does not change.
- The hook freeze applies until the bypass self-test on 17 and 18 November 2026. This slice changes no file in `.claude/hooks/` except new tests. It does not change `.claude/settings.json`.

A probe on Claude Code 2.1.322 gave three facts:

1. A plugin `$.tool.call` of `Read` ran the settings PostToolUse hook for `Read`.
2. The engine refuses a plugin `$.tool.call` of `AskUserQuestion`. It names `$.ui.ask` as the only route. A plugin cannot pre-fill the answers.
3. `$.ui.ask` rejects in a `claude -p` run, because no person can answer.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| The pane writes the CEO marker after the operator presses Approve | One key press | The mod becomes a marker writer. AgDR-0110 and AgDR-0234 forbid a model-side writer. The forged-menu guard would block the write |
| The pane runs the menu hook script with a built payload | One key press. Uses the hook code | The plugin builds the payload, so the plugin chooses the answer. A crafted payload is not proof of a human choice |
| The pane opens the engine's own question menu with `$.ui.ask` and the AgDR-0234 question. The settings hook records the answer | The existing hook writes the record. Only the engine's menu returns the answer. The plugin writes nothing | Two key presses for each approval. It needs an interactive session |
| Move gate state and approvals to the Cockpit only | No change in Claude Code | The operator leaves the session to approve. Outcome o8 asks for the band and the pane in Claude Code |

## Decision

Chosen: the pane opens the engine's question menu with `$.ui.ask`. The AgDR-0234 hook records the answer.

The split is as follows:

| Part | Owns | Does not own |
|------|------|--------------|
| Bash hooks in `.claude/hooks/` | Every gate decision. The merge, design and architecture gates. The head-SHA match. The red-CI block. The only writer of a menu record (`record-menu-approval.sh`) | Display |
| `apexyard-status` plugin (the band) | One line above the prompt: the active ticket, CI state of the branch PR, the waiting PRs with their CI state, and the reviewer lock | Any write. Any gate decision |
| `apexyard-gate` plugin (the pane) | A list of Rex-approved PRs with no CEO marker. Each row shows the repo, the PR, the head SHA, the CI state and the Rex verdict. Approve and Not yet buttons | Any write. Any merge. Any tool or settings hook |
| The Cockpit (premium, outside Claude Code) | Views across sessions, repos and harnesses. History and trends. A token meter, if one is built | Gate decisions. Approval records |

The approval flow has these steps:

1. The operator presses Approve on a pane row. The press is the first human key press.
2. The pane reads the PR again from GitHub with no cache.
3. The pane refuses when the head SHA differs from the SHA that the row shows. It also refuses a closed PR, a failed lookup, a red CI state, and a head that Rex did not approve. A refusal asks nothing.
4. The pane calls `$.ui.ask` with `Approve and merge <owner>/<repo>#<pr> at <sha>?` and the options `Approve and merge` and `Not yet`.
5. The operator selects an option in the engine's menu. This is the second human key press.
6. The settings PostToolUse hook for `AskUserQuestion` runs `record-menu-approval.sh`. The hook writes the record only for the exact approve label.
7. The pane reads the record back. It reports whether the hook recorded the shown SHA. It never writes the record.

The merge itself stays a separate step. The merge gate checks the record against the live head SHA.

The two plugins stay separate. An operator can keep the display-only band without the approval path. A reviewer can read the approval path in one small plugin. Each plugin can import only its own files. The pane therefore repeats four small helpers from the band plugin: the marker list, the marker SHA, the ops-root walk and the CI word.

The pane offers only the merge approval. Design and architecture approvals stay on `/approve-design`, `/approve-architecture` and the AgDR-0234 menu. The pane has no data that tells which PRs need a design review.

## Consequences

- With both plugins off or missing, every gate behaves as before. The committed settings enable neither plugin. Neither plugin registers a tool hook or a settings hook.
- An approval from the pane needs two human key presses: Approve in the pane, then the approve option in the menu.
- A stale SHA refuses before the menu opens. If the head moves while the menu is open, the record names the old SHA. The merge gate then refuses the merge, and the pane says so.
- A dismissed menu, a `Not yet` answer, free text, or a `claude -p` run records nothing.
- The record has the same trust level as any AgDR-0234 menu record. The control is the human menu answer plus the head-SHA match in the merge gate (AgDR-0104, C6).
- An SDK host that answers `AskUserQuestion` itself can approve. AgDR-0234 already records this limit.
- The check that the settings PostToolUse hook runs for a `$.ui.ask` menu rests on the `Read` probe. A manual check in an interactive session must confirm it before the slice closes. If the hook does not run, the pane reports "no record" and tells the operator to use `/approve-merge`.
- The plugin hook API is early access. A Claude Code release can break the band or the pane. No gate depends on either plugin.

## Artifacts

- Issue: me2resh/apexyard#1922
- ORBIT slice: `slice-golden-path-o8-gate-mod`, plan `plan-apexyard-harness-golden-path` revision 4
- Prior decisions: AgDR-0104, AgDR-0110, AgDR-0227, AgDR-0234
- Band: `plugins/apexyard-status/`
- Pane: `plugins/apexyard-gate/`
- Tests: `plugins/apexyard-gate/hooks/*.test.ts*`, `plugins/apexyard-status/hooks/ci.test.ts`, `.claude/hooks/tests/test_gate_plugin_off.sh`
