---
id: AgDR-0237
timestamp: 2026-10-13T00:00:00Z
agent: platform-engineer
model: claude-opus-5-5
session: dd4f4d1a-da79-48b3-b358-38966bbd5ade
trigger: user-prompt
status: executed
category: patterns
projects: [apexyard]
---

<!-- Uses the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Pilot the Agent Gate Contract on one hook and on Rex

> In the context of review rounds that AgDR-0172 capped in prose, facing gate answers that an orchestrator cannot read without parsing text, I decided to pilot the Agent Gate Contract (AGC) on one hook and on Rex's review output. The goal is answers with stable finding ids and, where the fix is mechanical, no round at all. I accepted a second output path in `dispatch-bash.sh`, which runs only in Claude Code and Codex.

## Context

- me2resh/apexyard#1418 and AgDR-0172 found review rounds up to five or six deep and added a severity bar, delta re-reviews and a two-round cap. Those rules live in reviewer prose.
- AGC (https://github.com/abbaseya/agent-gate-contract, draft 0.1, MIT) is an open standard for a gate's answer: one JSON object with a verdict, findings with stable ids and statuses, the strongest remedy, a check per finding, coverage and an attempt budget. A gate that can fix the action returns `repaired` instead of `block`.
- me2resh/apexyard#1698 proposes a pilot: one deterministic hook, Rex's output, and a measurement of review rounds.
- Every ApexYard hook answers with exit 2 and text on stderr. None uses Claude Code's JSON output (`updatedInput`).
- Claude Code's `updatedInput` replaces the whole tool input, and Claude Code does not run PreToolUse hooks again on it (hooks reference, checked 2026-10-13).
- The Codex adapter runs the same hooks and sets `APEXYARD_CODEX_HOOK_TOOL`. The OpenCode and Pi adapters treat exit 0 as allow and ignore stdout.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| `block-ambient-tracker-repo.sh` (chosen) | With one active target, its own block text already names the fix: "Add --repo <owner/repo>". The rewrite is one flag. It runs on every Bash call. | Its command parsing is complex, so the repair must stay narrow. |
| `block-git-add-all.sh` | Frequent. | No mechanical fix: choosing which files to stage is the point of the rule. |
| `validate-commit-format.sh` (compound commit commands) | Frequent. | The fix splits one call into several, which one `updatedInput` cannot express. |
| `block-main-push.sh`, `validate-branch-name.sh` | Clear rules. | The fix needs a new branch or a rename, not a rewrite of the call. |
| Repair inside the hook only | No dispatcher change. | Later gates would judge the original command, and Claude Code does not re-run hooks on `updatedInput`. A rewrite could pass a gate unchecked. |
| Repair pass in `dispatch-bash.sh` that re-runs every gate on the rewrite (chosen) | Every gate judges the call that will actually run. A failure blocks. | One more code path in the dispatcher. |
| Repair on every runtime | Simpler. | On OpenCode and Pi, exit 0 is allow, so the original unqualified call would run. That is weaker than today. |
| Repair only on positively detected Claude Code and Codex (chosen) | Matches the AGC bindings that are verified. Other runtimes keep today's block. | Runtime detection depends on `CLAUDE_PROJECT_DIR`, the hook input fields, and the Codex adapter's variable. |

## Decision

Chosen: **`block-ambient-tracker-repo.sh` as the pilot hook, with a repair pass in `dispatch-bash.sh` that runs only in Claude Code and Codex and re-runs every gate on the rewritten call, plus an `agc` block at the end of every Rex review.** The hook's fix is the one in its own message, it is one flag, and the re-check keeps every other gate in force.

## Consequences

- **The hook** has three modes, set by `APEXYARD_AGC_MODE`:
  - Unset: the normal gate. It still exits 2 with the same text, and adds the AGC object on stderr in a fenced `agc` block.
  - `repair`: set only by `dispatch-bash.sh`. For one active target and a plain one-line `gh issue|pr <subcommand>` call, it prints a `repaired` AGC object and exits 0. The flag `--repo <owner/repo>` goes right after the subcommand.
  - `preview`: AGC SPEC §11. The same check on a proposed command. It prints the AGC object, never blocks and writes no state.
- **No repair** for a compound command, shell syntax (a semicolon, pipe, ampersand, parenthesis, redirect, dollar sign, backtick, backslash or `#`), more than one line, more than one active target, or a target that is not a plain `owner/repo`. Those calls block as before. The block names the strongest remedy the hook can carry: the exact rewritten command, or a delegate to the calling agent.
- **The dispatcher** applies a repair before any other gate reads the command, then runs every gate on the rewritten call. Any gate that blocks the rewrite wins. In repair mode, stdout holds only the final PreToolUse JSON and gate output goes to stderr. Every failure to apply a repair blocks.
- **Per-runtime output** follows the AGC bindings:
  - Claude Code: `updatedInput` with no `permissionDecision`, so the person's permission settings still decide.
  - Codex: `updatedInput` with `permissionDecision: "allow"`, which Codex requires. It was measured not to skip Codex's approval.
  - OpenCode, Pi and Cursor: no repair, no AGC claim.
- **Rex** ends every posted review with one `agc` block: `gate.id` `rex-code-review`, stable finding ids `rex-code-review/<class>/<location>`, `new` / `still-open` / `regressed` statuses, `carried` ids, and `attempt.budget` 3. Rounds one and two match the two-round cap. A blocking finding still open in round three returns `escalate` to the human approver. The block is a report format only. The verdict, the severity bar, the approval marker and every merge gate are unchanged.
- **Measurement.** The baseline counts every Rex review (PR review or PR comment containing "Reviewed by Rex") on PRs merged into `dev` from 2026-09-27, the day AgDR-0172 took effect, to 2026-10-13:
  - 158 PRs had Rex reviews, with 422 rounds in all: a mean of 2.67, and at most 9.
  - Rounds per PR: 1 → 33 PRs, 2 → 47, 3 → 44, 4 → 17, 5 → 11, 6 → 4, 7 → 1, 9 → 1.
  - The count includes "waiting for CI" COMMENT rounds and re-reviews after base merges, not only fix rounds. The after-measurement uses the same query over a period the maintainer chooses, and can split rounds by `still-open` findings from the `agc` blocks.
- **Limits of the pilot:**
  - The hook does not count attempts across calls, so its `attempt.n` is always 1.
  - The AGC validator is Node, so it runs by hand or in CI, never in a hook.

## Artifacts

- me2resh/apexyard#1698
- `.claude/hooks/_lib-agc.sh`
- `.claude/hooks/block-ambient-tracker-repo.sh`
- `.claude/hooks/dispatch-bash.sh` (AGC repair pass)
- `.claude/hooks/tests/test_agc_pilot.sh`
- `.claude/agents/code-reviewer.md` § "AGC Findings Block"
- AGC: SPEC.md and EVIDENCE.md at v0.1.2, BINDINGS.md on `main` (Codex binding not yet tagged)
