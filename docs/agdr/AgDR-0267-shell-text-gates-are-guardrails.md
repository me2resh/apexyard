---
id: AgDR-0267
timestamp: 2026-10-21T12:00:00Z
agent: tech-lead (Hisham)
model: claude-opus-5-5
session: build-1845
trigger: user-prompt
status: executed
category: security
projects: [apexyard]
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Shell-text gates are guardrails, not a security boundary

> In the context of the Bash gate hooks, gate PRs took three to five review rounds each. The dispatcher took 25 to 75 s on large commands. I decided that the shell-text gates are guardrails against honest mistakes. This keeps gate PRs fast and correct. I accept that some exotic bypass shape classes stay open on purpose.

## Outcome and next action

- Outcome: the CEO decided on 2026-10-21 that the shell-text gates are guardrails. This record states the threat model, the real controls, the review bar for gate PRs, the freeze and the latency target.
- Next action: reviewers apply the bar in § "Review bar for gate PRs" to each PR that changes `.claude/hooks/**`. New exotic shape classes go into epic me2resh/apexyard#1846.

## Glossary

| Term | Definition |
|------|------------|
| Shell-text gate | A hook that reads the text of a Bash command and decides to block or allow it. The dispatcher `.claude/hooks/dispatch-bash.sh` runs these hooks. |
| Guardrail | A check that stops honest mistakes. It does not promise to stop a determined attacker. |
| Security boundary | A control that must hold against a hostile actor. |
| Hostile actor | A person, a hostile repository, or a prompt-injected agent that builds a command to get past a gate. |
| Ordinary command | A command that an agent or a human really types in normal work. |
| Exotic shape | A command that is built to get past a text scan and that no working agent types by accident. |
| Shape class | A group of exotic shapes that use the same method. This record names classes only, never exact commands. |
| Gate PR | A PR that changes `.claude/hooks/**`. |

## Context

Ticket: me2resh/apexyard#1845. Tracking epic: me2resh/apexyard#1846.

Gate PRs went round in circles for days:

- #1829 took 5 review rounds.
- #1835, #1838 and #1839 took 3 rounds each.
- Each fix added parser code. The next round then found a new exotic shape class.
- The classes were control or invalid bytes, legacy locales, two shell readings of one command, and letter case.

On 2026-10-21 one PR merged, and the follow-up list grew. The gates also slowed real work:

- The dispatcher took 25 to 75 s on large commands.
- It timed out under load. The dispatcher entry has `timeout` 75 and `onFailure: block`, so a timeout blocks the call.
- It blocked the reviewers' own file writes (#1840).

A text scan of a shell command cannot be complete against a hostile actor. AgDR-0104 states this fact: the ways to express a path or a verb in shell text have no limit. AgDR-0115 already names server-side branch protection as the real control for a terminal push in a managed-project clone. This record applies the same model to all the Bash gates.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep the gates as a security boundary, and block each gate PR on each new exotic shape class (status quo) | No open bypass class is accepted | The class list has no end. Each round adds parser code and latency. Gate PRs take three to five rounds. The scan still cannot be complete. |
| Remove the shell-text gates | No parser cost and no false blocks | Honest mistakes reach the server. The agent loses the fast local message that tells it the fix. |
| Keep the gates as guardrails, put the hostile case on real controls, and set a review bar and a latency target (chosen) | Gate PRs block only on real faults. The hostile case uses controls that do not read shell text. The cost of each gate has a limit. | Some exotic shape classes stay open on purpose. Reviewers must classify each finding as ordinary or exotic. |

## Decision

Chosen: **keep the gates as guardrails, put the hostile case on real controls, and set a review bar and a latency target**. A text scan cannot win against a hostile actor. The real controls do not read shell text, so they hold where the scan cannot.

### Threat model

The shell-text gates catch honest mistakes by agents and humans on ordinary commands. Examples:

- a push to `main` or `dev`
- a bad branch name
- a commit with no ticket
- an edit to a hook file

The gates do not claim to stop a hostile actor who builds a command to get past them. A gate that misses an exotic shape is not a failed security boundary. It is a known limit of a guardrail.

The gates still fail closed. A gate that crashes, times out or cannot read its input blocks the call (AgDR-0104, `docs/hooks-fail-closed.md`). This rule protects the ordinary command, so it stays.

### Real controls for the hostile case

These controls do not read shell text. Each one holds against a hostile actor only when the operator sets it up as stated here:

1. **GitHub rulesets on `main` and `dev`.** On me2resh/apexyard the `Branch-Protection` ruleset targets `main` and `dev`. It requires a pull request with one approving review and status checks. It blocks deletion and force-push (`non_fast_forward`). A ruleset holds only for a credential that is not on its bypass list. A managed project uses its own forge rules (AgDR-0115).
2. **Read-only hook files.** The Edit, Write, MultiEdit and NotebookEdit channel blocks a write to the live hook and settings files of the ops root. It decides on structured tool fields, not on shell text (`block-protected-target-writes.sh`, labelled `Edit CLASS: CONTROL`). The Bash channel of the same hook reads shell text, so it is a backstop. A ConfigChange hook blocks a settings change that turns hooks off (AgDR-0261 § B, #1806). For the hostile case, the operator must also make the hook files read-only at the file-system level.
3. **Claude Code permission rules.** The operator sets allow and deny rules. The harness applies them outside the hook scripts. User settings are a file that an agent can edit, so only managed settings hold against a hostile actor. The framework does not ship a `permissions` block in `.claude/settings.json`.
4. **The per-PR human merge approval.** Every merge needs Rex and an explicit human approval for that PR (`/approve-merge`). The forge holds this approval only when a ruleset requires an approving review, and only for a credential that is not a bypass actor. In all other cases, the merge gate hook holds it, and that hook reads shell text.

**Accepted residual.** An agent session can sometimes use a bypass-actor token. On that install, the merge gate hook is the only barrier to a merge without human approval. A crafted command can get past that hook. This record accepts that residual. The operator closes it with one of these actions:

- Keep each credential that an agent session can use off the bypass list.
- Keep bypass-actor tokens out of agent sessions.

This record names the controls. It does not claim that each install has all four set up. An operator who needs the hostile case closed must set up items 1 to 3 as stated, and must close the residual.

### Review bar for gate PRs

The CEO bar names four blockers for a gate PR:

- a regression against `dev` on an ordinary command
- a correctness bug in normal use
- a failed acceptance criterion
- a false durable doc

Reviewers apply that bar through the text below, so that no other blocker drops. The same text is in both reviewer briefs and in the `/security-review` skill.

The bar narrows one case only. On a PR that changes `.claude/hooks/**`, a crafted command that the shell-text scan does not catch is advisory. This case includes an exotic shape that `dev` blocks and the head does not.

Every other blocker stays:

- kinds 1, 3 and 4 of the Blocking-Severity Bar (AgDR-0172)
- a gate that fails open on its own error, timeout or bad input
- a hook change that runs code from command text, a cloned repository or other untrusted input
- the checks that `.claude/agents/code-reviewer.md` § "Blocking-Severity Bar" keeps blocking. These are the Acceptance Criteria check, the AgDR check, the Glossary requirement, a handbook marked `ENFORCEMENT: blocking`, and rail 1 of `.claude/rules/right-size-ceremony.md`.

A regression on an ordinary command is kind 1. An ordinary command is one that an agent or a human really types. A false block counts. A slowdown above the 2 s target in AgDR-0267 § "Cost budget" counts when `dev` is below it.

A deleted or weakened paired test for a shape that `dev` already blocks is a correctness finding (kind 3).

An exotic bypass shape is advisory. Name its class only, never the exact command. List the class for epic me2resh/apexyard#1846. Do not hunt for new shape classes. Check the delta, the earlier findings, and ordinary commands against `dev`.

A probe of nearby shapes may check that the fix works. A probe result on an exotic shape is advisory. A public tracker must not hold a ready-made bypass.

### Freeze

No new gate-hardening ticket opens for an exotic shape class. A new class goes into epic me2resh/apexyard#1846 as one class-level item.

An item in the epic gets a fix only when one of these is true:

- an ordinary command hits it
- the fix is cheap and adds no new parser surface

A shape that a working agent really typed is an ordinary command, not an exotic shape. It gets a normal bug ticket.

### Cost budget

A guardrail must never cost more than the mistake it prevents. The target for the dispatcher is:

- **2 s or less of wall time for an ordinary command**, on one macOS host with `/bin/bash` 3.2 and the system awk.
- This includes a commit, PR or review command that carries up to 40 KB of heredoc or `--body` text.

The evidence for 2 s:

- AgDR-0264 measured 0.19 s to 0.35 s for the dispatcher on its test shapes, with stub gates. So 2 s is about six times the routing cost. That room covers the real gates, load and a slower host.
- AgDR-0264 also found 37 KB of review prose near base speed. It gave no time for that case.
- The time of the real gates on an ordinary command is not measured yet. The first gate PR that measures it records the value.
- The issue measured 25 s to 75 s on large commands. That is 12 to 37 times the target, and a timeout blocked the call.
- The mistakes that the gates prevent cost about one minute to fix. The ruleset refuses a bad push, or the agent amends one commit. An agent runs tens of Bash calls for one ticket. At 25 s for each large call, the gate costs more than the mistake.

The 75 s `timeout` on the dispatcher entry stays. It is a fail-closed limit, not a budget. An exotic shape can still run to that limit and block. That result is advisory.

### Notes on earlier records

Earlier records sometimes call a shell-text hook a "security gate" or a "security boundary", for example AgDR-0168 and AgDR-0192. Read that term as "guardrail" for the shell-text scan. Notes point to this record from AgDR-0109, AgDR-0168, AgDR-0172 and AgDR-0192.

AgDR-0171 calls its guard list a living list. The freeze applies to that list and to similar lists for exotic shape classes.

## Consequences

- Some exotic shape classes stay open on purpose. Epic me2resh/apexyard#1846 lists them at class level. Each accepted residual is named in the AgDR of its gate.
- Reviewer briefs stop asking for adversarial shape hunts on gate PRs. `.claude/agents/code-reviewer.md`, `.claude/agents/security-reviewer.md` and `.claude/skills/security-review/SKILL.md` each have a "Review bar for gate PRs" section that points to this record.
- On a gate PR, a crafted command that the scan misses no longer blocks. Every other blocker stays. This removes the main cause of three-to-five-round gate PRs.
- On an install where the agent session can use a bypass-actor token, a merge without human approval stays possible through a crafted command. This residual is accepted, and the operator can close it (§ "Real controls for the hostile case").
- A gate PR that slows an ordinary command above 2 s, when `dev` is below 2 s, is a regression. The reviewer measures with the host and tools in § "Cost budget".
- The fail-closed rule of AgDR-0104 stays. A gate that cannot decide still blocks.
- The paired-test rule of AgDR-0109 stays for the shapes that a hook already handles. A missing test for a new exotic class does not block.
- An operator who needs protection against a hostile actor must set up the real controls. The shell-text gates alone do not give that protection.

## Artifacts

- me2resh/apexyard#1845 (this decision)
- me2resh/apexyard#1846 (tracking epic for the advisory shape classes)
- me2resh/apexyard#1840 (reviewer body writes blocked by the gates)
- PRs #1829, #1835, #1838 and #1839 (the review rounds in § "Context")
- AgDR-0104 (a text scan cannot be made sound, controls and backstops)
- AgDR-0115 (server-side branch protection is the control for a managed-project terminal push)
- AgDR-0172 (the four-kind blocking-severity bar, narrowed here for gate PRs)
- AgDR-0261 § B (tamper controls on the edit channel and ConfigChange)
- AgDR-0264 (dispatcher timing evidence and the 75 s fail-closed limit)
- `docs/hooks-fail-closed.md`
