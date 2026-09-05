# Migration gate refuses an unresolvable write target instead of falling back

> In the context of the migration gate resolving which ticket governs a Bash write, facing a target that carries an unexpanded shell variable and therefore matches no project, I decided to **refuse the write** rather than fall back to the ops-level marker, to achieve fail-closed behaviour for a blocking gate, accepting that a legitimate variable-driven migration write must be rewritten with a literal path.

**Status**: Accepted
**Date**: 2026-09-05
**Ticket**: me2resh/apexyard#1159
**Related**: [AgDR-0104](AgDR-0104-trust-chain-controls-vs-backstops.md) (pattern-matching command text cannot be made sound) · me2resh/apexyard#1152 (fail-closed across blocking hooks)

## Context

`require-migration-ticket.sh` extracts a write target from a Bash command, matches it against the migration-path patterns, then resolves which project owns it so it can pick the right ticket marker. The marker lookup has three tiers: per-worktree, per-project, and an ops-level fallback at `.claude/session/current-ticket`.

A Bash write target can carry an unexpanded shell variable. `cat > "$WD/app/migrations/0001_initial.py"` yields the literal string `$WD/app/migrations/0001_initial.py`, because expanding it would mean executing the command. That string still matches `**/migrations/**`, so the gate fires — but it can never match a workspace prefix, so project resolution fails and the lookup lands on tier 2.

The result: the gate evaluates the write against **a different ticket than the one governing that worktree**, and reports nothing. On the session that produced #1159, a correct per-worktree marker existed the whole time and a stale ops-level marker from earlier work was used instead.

The reviewer's framing on the issue is the precise one: `_lib-detect-bash-write.sh` deliberately prefers false negatives and promises that an unparseable segment "contributes nothing, never a fabricated target". That is right for a **detector**. For a **gate** it is wrong — degrading to the ops marker is not degrading to *no opinion*, it is degrading to *someone else's answer*.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Refuse when the target is unresolvable (chosen)** | Fail-closed; the invisible failure becomes a loud one; narrow, one hook, no shared-library change | A legitimate variable-driven migration write must be rewritten with a literal path |
| Warn and continue on the ops marker | No workflow interruption | Keeps evaluating against the wrong ticket; a warning in a stream of hook output is not a control |
| Refuse whenever project resolution fails | Simpler condition | **Breaks a legitimate case** — a literal path outside `workspace/` also leaves the project empty, and the ops marker is correct there (a migration in the ops fork itself) |
| Rewrite target extraction to resolve variables | Addresses the root cause | Requires expanding shell state the hook cannot see; AgDR-0104 already established this class is unsound |

## Decision

Chosen: **refuse when the target is unresolvable**, because a blocking gate that silently answers from the wrong marker is worse than one that stops. The refusal names the offending path so the operator can see why.

The condition is deliberately **unresolvability**, not "project resolution failed". Only a target containing an unexpanded `$` is treated as unresolvable. A literal absolute path outside `workspace/` keeps falling back to the ops marker, which is the correct behaviour for a migration inside the ops fork itself. A regression test pins that case so the condition is not widened later.

## Consequences

- A migration write whose target is a shell variable is refused with the path and a fix instruction. Use a literal path.
- Marker resolution for every literal path is unchanged, including the ops-fork fallback.
- The shared detector `_lib-detect-bash-write.sh` is untouched, so `require-active-ticket.sh` and `warn-review-marker-write.sh` are unaffected. Its detector contract stands; what changed is what the gate does with an unresolved result.
- **Failure 2 of #1159 is not addressed.** A heredoc body containing a write command is extracted as a real target, so a document quoting `cat > .../migrations/...` is blocked. The fix belongs in the shared detector and carries wider blast radius; it is deliberately deferred and the ticket stays open for it.

## Artifacts

- `.claude/hooks/require-migration-ticket.sh` — Gate 0
- `.claude/hooks/tests/test_require_migration_ticket.sh` — cases 23 and 24
