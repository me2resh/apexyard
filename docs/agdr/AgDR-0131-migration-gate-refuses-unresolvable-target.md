# Migration gate resolves what it can and refuses what it cannot

> In the context of the migration gate deciding which ticket governs a Bash write, facing targets it cannot map to a project, I decided to **normalise every resolvable target and refuse the genuinely unresolvable ones — checking all targets, not just the first** — to achieve fail-closed behaviour for a blocking gate, accepting that unexpandable shell constructs must be rewritten as literal paths.

**Status**: Accepted
**Date**: 2026-09-05
**Ticket**: me2resh/apexyard#1159
**Related**: [AgDR-0104](AgDR-0104-trust-chain-controls-vs-backstops.md) (pattern-matching command text cannot be made sound) · me2resh/apexyard#1152 (fail-closed across blocking hooks)

## Context

`require-migration-ticket.sh` extracts a write target from a Bash command, matches it against the migration-path patterns, then resolves which project owns it to pick the right ticket marker. The marker lookup has three tiers: per-worktree, per-project, and an ops-level fallback at `.claude/session/current-ticket`.

When the target cannot be mapped to a project, the lookup falls through to tier 2 — so the gate evaluates the write against **a different ticket than the one governing that worktree**, and reports nothing. On the session that produced #1159, a correct per-worktree marker existed the whole time and a stale ops-level marker from earlier work answered instead.

The reviewer's framing on the issue is the precise one: `_lib-detect-bash-write.sh` deliberately prefers false negatives and promises that an unparseable segment "contributes nothing, never a fabricated target". That is right for a **detector**. For a **gate** it is wrong — falling back is not degrading to *no opinion*, it is degrading to *someone else's answer*.

**The first cut of this change refused only targets containing `$`.** Review of PR #1180 established that this did not deliver the property it claimed, in three separate ways:

1. **Ordering bypass.** The check ran *after* the `#886` loop, which stops at its first migration-shaped match. A compliant literal target named first smuggled a later unresolvable one straight past the gate.
2. **Incomplete condition.** A backtick is the same bash feature as `$(…)`; one was caught, the other was not. Relative and `~/` targets also reached tier 2 unresolved.
3. **False positive on the wrong tool.** The check also applied to `Edit`/`Write`, where `file_path` never passed through a shell — so a literal filename containing `$` was hard-blocked, with a message asserting a cause that had not been observed.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Resolve what is resolvable, refuse what is not (chosen)** | Closes the class rather than one spelling; relative and `~/` targets gate *correctly* instead of being refused; order-independent | More code than a single guard; needs the harness `.cwd` |
| Refuse on `$` only (the first cut) | Smallest diff | Rejected in review — leaves backticks, `$(…)`, relative and `~/` on the wrong marker, is order-dependent, and false-positives on `Edit`/`Write` |
| Refuse anything not absolute | Simple and strictly safe | Refuses relative paths that are perfectly resolvable; maximises the bypass pressure the ticket already warns about |
| Warn and continue on the ops marker | No workflow interruption | Keeps evaluating against the wrong ticket; a warning in hook output is not a control |
| Refuse whenever project resolution fails | Simple condition | **Breaks a legitimate case** — a literal path outside `workspace/` also leaves the project empty, and the ops marker is correct there |

## Decision

Chosen: **resolve, then refuse**, in two passes over every extracted target.

- **Pass 1** examines *all* targets before any is selected, so refusal cannot depend on argument order. A target is unresolvable when it carries a shell variable, a command substitution, or a backtick — constructs whose value is unknowable without executing the command. Refusal is scoped to targets whose literal text is still migration-shaped, so an unrelated `$LOG` redirect in the same command is not refused.
- **Pass 2** normalises each resolvable target — `~` expanded, relative resolved against the harness-supplied `.cwd` (not the hook's own cwd; the same distinction `verify-commit-refs.sh` draws for #1050), and `//`, `/./`, `/../` canonicalised lexically so a not-yet-created migration file still resolves — then applies the existing migration match and project resolution.

The resolvability check is **Bash-only**. An `Edit`/`Write` `file_path` is a literal string that never met a shell, so a `$` there is an ordinary filename character.

This mirrors the sibling gate `require-active-ticket.sh`, which already absolutises and canonicalises before its containment checks.

## Consequences

- A Bash migration write whose target carries an unexpandable construct is refused, naming the path. Relative and `~/` paths are resolved and gated normally — the refusal message says so, to avoid pushing operators toward workarounds.
- Relative, `~/`, `//`, `/./` and `/../` spellings now resolve to the **correct** project marker instead of silently reaching tier 2. This is a behaviour change: writes that previously consulted a stale ops marker now consult the right one, which can newly block where the correct ticket does not satisfy the gate. That is the fix working.
- The ops-fork fallback is unchanged — a literal absolute path outside `workspace/` still legitimately uses the ops marker (case 24).
- The shared detector `_lib-detect-bash-write.sh` is untouched, so `require-active-ticket.sh` and `warn-review-marker-write.sh` are unaffected. Its contract stands; what changed is what *this gate* does with its output.
- **Failure 2 of #1159 is still not addressed.** A heredoc body containing a write command is extracted as a real target, so a document quoting `cat > …/migrations/…` is blocked. It reproduced repeatedly while building this change — on a probe script, a debug script, and the commit message itself. That fix belongs in the shared detector and carries wider blast radius, so #1159 stays open for it. Reviewers noted it composes badly with this gate: the refusal advises "use a literal path", which is unhelpful for a document that is merely *quoting* one.

## Artifacts

- `.claude/hooks/require-migration-ticket.sh` — `_rmt_is_unresolvable`, `_rmt_normalise_target`, two-pass target loop
- `.claude/hooks/tests/test_require_migration_ticket.sh` — cases 23–30
- PR me2resh/apexyard#1180 — Rex and Hakim reviews that rejected the first cut
