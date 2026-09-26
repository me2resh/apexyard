# Classify /duty playbook proposals by effect, in a tested helper

> In the context of a shift loop that edits its own playbook, facing the risk that the loop removes its own constraints, I decided to classify each proposal by its effect in a deterministic helper, to achieve a rail that holds against proposals framed as corrections, accepting that some harmless corrections go to the operator.

## Context

The `/duty` skill (me2resh/apexyard#1360) runs a shift loop. A daily retro proposes playbook changes. A class A proposal corrects a false statement and applies immediately. A class B proposal waits for per-item operator approval.

A rail that blocks only literal edits to the hard-constraint list is not enough. The realistic failure is a proposal framed as a correction whose effect reduces supervision. Examples include a changed stale threshold, a narrowed escalation gate, or a check that the proposal calls redundant.

The model that drafts a proposal also labels it. A rule written only in prose relies on that same model to classify its own proposal honestly.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Prose rule in the playbook only | No code. Simple to read. | The author classifies its own proposal. No test can check it. |
| Classify by the proposal's declared fields | Simple helper. | The author sets the fields, so it has the same weakness as prose. |
| Classify by effect on the actual text, in `duty.sh` | Deterministic and testable. It ignores the declared framing. | Heuristic keyword and number checks send some harmless edits to class B. |
| A new PreToolUse hook that guards the playbook file | Mechanical enforcement. | Adds to the trust chain. A shell hook cannot tell a sanctioned approval from an unsanctioned edit. Heavy for a skill-scoped control. |

## Decision

Chosen: **classify by effect in `duty.sh`, with an allowlist for class A**, because it is the strongest control that stays inside the skill. The classifier ignores the declared class unless it is B. Class A is possible only in a section that carries the `duty:class-a` marker. The bundled playbook gives that marker to the trap log only. The classifier returns class B when a proposal does any of these:

- targets a section without the `duty:class-a` marker, or text it cannot find
- adds a heading or a section marker
- adds a normative word, such as never, must, only, except, or instead
- removes or rewrites a normative line
- changes any number
- names a gated action, such as merge, approve, force, push, or deploy, or widens unattended action

A first version used a denylist of protected sections. Review found three proposals that passed it as class A: an append that named a gated action, an append that added a new unprotected heading, and an exception line added beside an unchanged rule. The allowlist and the new-text checks close all three. Each has a regression test.

The new-text checks are word lists. A second review showed that a trap entry can avoid the listed words and still read as a widening instruction, for example "Treat a failed read as zero open items." A word list cannot prove intent. So a protected precedence rule in playbook section 10 is the backstop: a trap entry never overrides sections 1 to 8 or 10, and a conflict is an escalation. The rail is therefore two layers. The classifier catches common phrasings mechanically. The precedence rule decides a conflict that the classifier misses.

`duty.sh apply` refuses a class B proposal unless the call passes `--operator-approved`. The skill allows that flag only when the operator typed `approve <id>` in the current message.

## Consequences

- Most corrections become class B, including a factual correction outside the trap log and a corrected number in an evidence line. This error direction is the intended one. Class A covers new trap entries and wording fixes in the trap log.
- The rail is not a security boundary against an agent that edits `playbook.md` directly with a file tool. The helper and the tests make a violation visible and reviewable. They do not make it impossible.
- The protected-section marker is itself in the playbook. A proposal that removes a marker edits a protected section, so it is class B.
- The skill adds no hook and does not change `.claude/settings.json`.

## Artifacts

- me2resh/apexyard#1360
- `.claude/skills/duty/duty.sh`, `.claude/skills/duty/tests/test_duty_rail.sh`
