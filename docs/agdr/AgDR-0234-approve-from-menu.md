---
id: AgDR-0234
timestamp: 2026-10-12T14:30:00Z
agent: platform-engineer
model: grok-4.7
session: gh1391-approve-from-menu
trigger: user-prompt
status: executed
category: security
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# AgDR-0234: Record menu approval from the harness question tool

> The operator can approve a merge or a design review from a menu. The hook writes the record from the harness payload. The record has the same trust level as a typed marker.

## Context

Issue #1391 asks for menu approval. The typed `/approve-merge` and `/approve-design` commands stay.

AgDR-0110 and issue #1042 keep approval human-only. A model that reads a menu answer and then writes the marker is not proof. Nothing in that path shows that the human selected the option.

The harness runs a PostToolUse hook after `AskUserQuestion`. The payload contains the question and the selected option. The menu record has the same trust level as a typed marker. The guard is a text-match backstop (AgDR-0104); the real control is the human-only menu answer plus the gate's head-SHA match.

The question must name the repo, the PR number, and the full 40-hex head SHA. The selected option must be the exact approve label. `Not yet` writes nothing. An umbrella "go" does not match the question shape.

The record shows that the question tool returned the approve label. In normal Claude Code use only a human answers. When an SDK host supplies answers, the host program, not a person, chose it.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| HMAC of the record with a per-session key in a file the model tools cannot read | The gate can reject a forged record | This repo has no such file. Hooks and the model tools share one user and one disk |
| HMAC with a key in a normal file | Easy to add a field | Bash and Read can read the key. The model can then forge the HMAC |
| The menu hook is the supported writer of `approval_channel=menu`. A PreToolUse guard blocks Edit, Write, and Bash writes of that channel onto a marker | Uses the tools this repo has. The typed path stays | The guard matches command text. AgDR-0104 says that match is a backstop. A later copy can hide the channel string |

## Decision

Chosen: the menu hook writes the record. A PreToolUse guard blocks model writes of `approval_channel=menu`.

No file in this framework is unreadable by the model tools. A key file the hook can read is a key file Bash can read. An HMAC would not prove the writer. The guard remains a text-match backstop (AgDR-0104).

The guard is a backstop, not a proof of the writer. AgDR-0104 records that limit. The gate checks the record fields and the head SHA. Carry-over rules stay as they are.

`record-menu-approval.sh` runs on PostToolUse for `AskUserQuestion`. `block-forged-menu-approval.sh` runs on PreToolUse for Edit, Write, and MultiEdit. The Bash dispatcher runs the same guard on every Bash call. It fails closed if that guard crashes.

A menu record has `skill_version=3` and `approval_channel=menu`. The typed merge marker stays at `skill_version=2` with no channel. Design and architecture typed markers stay a bare SHA. The gates accept both shapes. The merge gate refuses a menu record inside the merge command. The hook writes the file before the merge.

## Consequences

- The operator can select the approve option on a menu that names the repo, the PR, and the full head SHA.
- `Not yet` writes nothing.
- An umbrella "go" does not count. A prose answer does not count.
- The typed `/approve-merge` path still works.
- A direct Edit, Write, or Bash payload that puts `approval_channel=menu` on a marker file is blocked.
- A menu record has the same trust level as a typed marker. The guard is a text-match backstop (AgDR-0104); the real control is the human-only menu answer plus the gate's head-SHA match. Calls naming the writer or library are blocked, but hidden spellings or copies can still bypass text matching.
- Architecture review uses the same menu shape. The architecture gate accepts that record and still accepts a bare SHA.

## Artifacts

- Issue: me2resh/apexyard#1391
- Prior decision: AgDR-0110
- Backstop limit: AgDR-0104
- Hook: `.claude/hooks/record-menu-approval.sh`
- Guard: `.claude/hooks/block-forged-menu-approval.sh`
