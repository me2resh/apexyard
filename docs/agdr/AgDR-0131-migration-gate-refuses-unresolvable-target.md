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
- **Pass 2** normalises each resolvable target — `~` expanded, relative resolved against the harness-supplied `.cwd`, and `//`, `/./`, `/../` canonicalised lexically so a not-yet-created migration file still resolves — then applies the existing migration match and project resolution.

The resolvability check is **Bash-only**. An `Edit`/`Write` `file_path` is a literal string that never met a shell, so a `$` there is an ordinary filename character.

`.cwd` is read from `.cwd // .tool_input.cwd` (both shipped shapes) and trusted only when **absolute and existing** — the two conditions `verify-commit-refs.sh` applies to the same field. Anything else is discarded rather than joined: a relative or bogus value would fabricate a plausible absolute path that is indistinguishable downstream from a real one. With no usable `.cwd`, a relative target is left **un-normalised** and behaves exactly as it did before this change. It is deliberately not refused — refusing would newly block writes every prior version allowed, which is the bypass pressure this gate can least afford.

### This is weaker than the sibling gate, in ways that matter

An earlier draft of this record claimed the change "mirrors `require-active-ticket.sh`". That was wrong, and the difference is the substance:

| | `require-active-ticket.sh` | this gate |
|---|---|---|
| Symlinks | resolved via `_resolve_real_path` | **not resolved** — normalisation is purely lexical |
| Boundary anchors | canonicalised with `pwd -P` | **not canonicalised** |
| Containment | four-way raw-AND-resolved check, added for #885's mirror-image hole | single prefix match |

Lexical `/../` collapsing does not consult the filesystem, so it can disagree with the kernel when a symlink is in the path. Consequences of that are recorded below.

## Consequences

- A Bash migration write whose target carries an unexpandable construct is refused, naming the path. Relative and `~/` paths are resolved and gated normally — the refusal message says so, to avoid pushing operators toward workarounds.
- Relative (with a usable `.cwd`), `~/`, `//`, `/./` and `/../` spellings now resolve to the **correct** project marker instead of silently reaching tier 2.

- **This change is not monotonic, and that is a real departure.** The first cut only ever *added* refusals, which made it easy to accept. This one moves cells in both directions: security review measured nine cases where `dev` blocked and this change allows. In eight of them the allow is *correct* — the right project's ticket does satisfy the gate, and the block was the wrong-marker bug. The ninth is a genuine new gap, below.

- **Known gap — a symlinked anchor makes the gate resolve a different file than the kernel writes, and here that is a NEW divergence.** Normalisation is lexical, so it cannot see a symlink. Two earlier drafts of this record got this wrong in opposite directions and both were measured, not reasoned:
  - The first claimed `<ops>/plaindir/../workspace/A/…` escaped the fork. Re-measured with real `open()` calls rather than shell `cd`: with a **plain** directory the kernel and the hook agree. There is no escape and no divergence. That retraction stands.
  - The second then folded the symlink case into the pre-existing anchor-spelling gap below. That was over-corrected. A **symlink alone is enough** — no `..` required — and for the shapes this change introduces the divergence is **not** pre-existing: `dev` never resolved a project for a relative target at all, so it fell to the ops marker and blocked; this change resolves one and allows under the caller's project ticket. This is the ninth case referenced above, and it is the one genuine new gap this change opens.
- **Known gap — un-canonicalised workspace anchors (pre-existing).** The workspace boundary is never canonicalised, so on macOS the same file addressed through `/tmp` versus `/private/tmp` resolves to different markers. `dev`'s raw prefix match is equally wrong here, so this one really is pre-existing.
- **Known gap — the meta-exemption reads the raw target (pre-existing).** `_rmt_is_meta_exempt` matches before normalisation, so `sub/docs/../db/migrations/1.sql` exempts itself on the `docs/` segment that normalisation would have removed, and skips the gate entirely. Raised by security review in round 4. Not fixed here: the exemption predates this change and moving it after normalisation widens the blast radius beyond the ticket.
- Closing all three needs `_resolve_real_path` and `pwd -P` anchors, as the sibling gate `require-active-ticket.sh` already does, plus normalising before the exemption test. That is the natural follow-up and is not attempted here.
- The ops-fork fallback is unchanged — a literal absolute path outside `workspace/` still legitimately uses the ops marker (case 24).
- The shared detector `_lib-detect-bash-write.sh` is untouched, so `require-active-ticket.sh` and `warn-review-marker-write.sh` are unaffected. Its contract stands; what changed is what *this gate* does with its output.
- **Failure 2 of #1159 is still not addressed.** A heredoc body containing a write command is extracted as a real target, so a document quoting `cat > …/migrations/…` is blocked. It reproduced repeatedly while building this change — on a probe script, a debug script, and the commit message itself. That fix belongs in the shared detector and carries wider blast radius, so #1159 stays open for it. Reviewers noted it composes badly with this gate: the refusal advises "use a literal path", which is unhelpful for a document that is merely *quoting* one.

## Artifacts

- `.claude/hooks/require-migration-ticket.sh` — `_rmt_is_unresolvable`, `_rmt_normalise_target`, two-pass target loop
- `.claude/hooks/tests/test_require_migration_ticket.sh` — cases 23–44. Cases 31–34 pin `.cwd` trust; **cases 36–38 are what pin normalisation itself** — they use a fixture whose ops and per-project markers give opposite verdicts, so the exit code reveals which marker answered. Case 34 does not pin normalisation, contrary to an earlier draft: its target lands outside `workspace/` either way, so the ops marker answers identically normalised or not.
- PR me2resh/apexyard#1180 — four rounds of Rex and Hakim review. The first cut, the first redesign, and the `.cwd` fix were each rejected on a defect found by probing rather than by reading; this record was corrected four times for overclaiming — twice on this same symlink bullet, in opposite directions. Round 4 added the `~user`/`~+`/`~-` fabrication branch the round-3 fix did not reach, made both target-resolution passes ask the migration question of the same string, and gave the `.cwd` validation its first real coverage. Every fix is mutation-checked: reintroducing any one of them fails a named case.
