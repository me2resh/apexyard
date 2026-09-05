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
| **Resolve what is resolvable, refuse what is not (chosen)** | Closes the class rather than one spelling; relative and `~/` targets gate *correctly* instead of being refused; order-independent (of **both** passes — round 4 gave pass 1 that property and round 6 finally gave it to pass 2, which had kept a first-match `break`; this cell overclaimed in between) | More code than a single guard; needs the harness `.cwd` |
| Refuse on `$` only (the first cut) | Smallest diff | Rejected in review — leaves backticks, `$(…)`, relative and `~/` on the wrong marker, is order-dependent, and false-positives on `Edit`/`Write` |
| Refuse anything not absolute | Simple and strictly safe | Refuses relative paths that are perfectly resolvable; maximises the bypass pressure the ticket already warns about |
| Warn and continue on the ops marker | No workflow interruption | Keeps evaluating against the wrong ticket; a warning in hook output is not a control |
| **Reuse `_resolve_real_path` from `_lib-path-resolve.sh`** | Already shipped; `realpath -m` semantics, so it resolves an absent file *and* one behind a symlinked ancestor — closing the symlink gap this change leaves open; the sibling gate `require-active-ticket.sh` already uses it | Not a drop-in: it re-appends the absent tail verbatim, so dot-segments inside that tail survive, and a wholly absent root yields a doubled leading slash (`//nope/…`). Composing it *after* a lexical collapse is the target design; this change ships the lexical half only, as a staged step. Raised by architecture review in round 5, after two earlier drafts justified the lexical choice on a ground this helper refutes |
| Refuse whenever project resolution fails | Simple condition | **Breaks a legitimate case** — a literal path outside `workspace/` also leaves the project empty, and the ops marker is correct there |

## Decision

Chosen: **resolve, then refuse**, in two passes over every extracted target.

- **Pass 1** examines *all* targets before any is selected, so refusal cannot depend on argument order. A target is unresolvable when it carries a shell variable, a command substitution, or a backtick — constructs whose value is unknowable without executing the command. Refusal is scoped to targets that are migration-shaped in **either** spelling — raw or normalised. An earlier draft said "scoped to a target's literal text, so an unrelated `$LOG` redirect is not refused", and offered that as reassurance. Round 5 made pass 1 test both spellings, which turns the example into a counter-example: `echo x > $LOG` issued from a `migrations/` cwd is passthru on `dev`, was allowed at commit 4, and is **refused** at this HEAD. That is the intended direction — fail-closed on a gate — but the record must not claim otherwise. The raw spelling is retained alongside the normalised one because normalisation can consume a `migrations/` segment via `..`, which would silently drop a refusal that exists today.
- **Pass 2** judges *every* migration-shaped target, not the first. Where the matching targets are governed by more than one **marker**, the command is **refused** and the operator is asked to split it: gating on any one of them approves the writes the others govern.

  The key is the resolved marker, not the project name. Round 6 keyed on the name and got both directions wrong at once: the ops domain's name is legitimately empty, so that member was silently dropped (fail-open, order-dependent), while two projects sharing a single `current-ticket` were refused for differing in a field that governs nothing (over-refusal, against `dev`). All three reviewers found the first half independently in round 7.

  **This refusal is a staged step, not the end state.** The end state is **per-domain evaluation** — loop the distinct governing markers and block if any one of them fails — which dominates the refusal on both axes: never weaker on safety, since the refusal only ever blocks more, and strictly better on usability, since the refusal also blocks the case where every marker is satisfied. It is expressible despite the hook's binary verdict; it is deferred here only because it needs the single-representative structure described below to be unwound first.

  Two things keep the interim refusal defensible. It is **strictly closer to `dev`** than what it replaced, and the SDLC's **one-ticket-at-a-time rule already forbids** a single command spanning two governing tickets — so the refusal enforces an existing invariant rather than inventing a new inconvenience. Two targets under the *same* marker still gate normally.
- **Pass 2** normalises each resolvable target — `~` expanded, relative resolved against the harness-supplied `.cwd`, and `//`, `/./`, `/../` canonicalised lexically (see "Why lexical" below — the reason is **not** the one two earlier drafts gave) — then applies the migration match and project resolution. The **match itself is unchanged; the string it is applied to is not**, and that is where round 5's defect lived: selecting on the normalised spelling alone silently disabled the Bash half of this gate on every fork that configures `migration_paths`, because adopter patterns are repo-relative while the defaults are `*/`-anchored and survive absolutisation. Pass 2 now asks both spellings, with the raw arm gated on a configured pattern set so it cannot reinstate the default-pattern false positive.

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

**The direction of this divergence is the part worth flagging.** The framework's own rails call migrations never-Lean and highest-blast-radius, yet after this change the migration gate resolves paths *more weakly* than `require-active-ticket.sh`, which governs ordinary writes. The stricter gate guards the lower-stakes surface. That is accepted here as a **staged step**, not as a resting state, and it is the reason the follow-up below is named rather than merely noted.

#### The single-representative structure is the defect generator

Worth stating plainly, because the review history is the evidence. Seven commits have approximated one property — *every target is judged against the marker that governs it* — seven different ways, and each left an adjacent case: the ordering bypass in pass 1 (round 2), the first-match `break` in pass 2 (round 6), the unrepresentable ops domain in the fix for that (round 7).

The structural cause is that everything before Gate 1 exists to elect **one** `FILE_PATH` to stand for the whole command, because the tail can evaluate exactly one marker. Each fix improves the election; none removes the need to hold one. Architecture review named this in round 7 and recommended **restructure rather than continue iterating** for the remaining work, staged as: this commit's marker-keyed accumulator, then the resolution half (`_resolve_real_path` composed after the lexical collapse), then per-domain evaluation — which retires the refusal above and removes the election entirely.

A stopping rule was set with it, and this record adopts it: **if another defect of this same class appears, restructure before merging anything further.**

#### One resolution regime, a two-spelling selection predicate

Worth naming, because this record's own repeated failure has been an argument made in one place and not carried to another. `RESOLVED_TARGET` is **always** the normalised spelling, so on the Bash path marker resolution never runs on the raw one. (Scoped deliberately: on the `Edit`/`Write` path `FILE_PATH` is the literal `file_path` and is never normalised at all. An earlier draft stated this without the scope — the same overclaim shape corrected one section above.) Only *selection* asks both spellings, and only because adopter patterns are repo-relative by documented contract.

The asymmetry is deliberate, and the failure directions are not symmetric. Selection failing low switches the gate off silently — that was round 5's blocker. Selection failing high over-blocks, which is fail-closed and visible. **Resolution** failing wrong picks the wrong ticket, which is the bug this whole change exists to fix. So: match liberally, resolve canonically.

Normalising the adopter patterns instead was considered and rejected: absolutising a repo-relative pattern needs the repo root it is relative to, which is per-project, and the project is precisely what is unknown until the path has been resolved. Circular — and it would silently redefine an adopter configuration surface inside a fail-closed fix. Raised by architecture review in round 6; the invariant is pinned by cases 36–38 but was previously nowhere stated.

#### Why lexical, honestly

Two earlier drafts of this record — and the code comment — justified the lexical canonicaliser with *"lexical (not realpath) so a not-yet-created migration file still resolves."* **That reason is false and is withdrawn.** `_resolve_real_path` in `_lib-path-resolve.sh` has `realpath -m` semantics: it walks up to the first existing ancestor, `pwd -P`s it, and re-appends the absent tail. Measured at this HEAD, it resolves an absent file *and* an absent file behind a symlinked ancestor in one call. The record was defending its central architectural call on a ground its own named follow-up refutes. Caught by architecture review in round 5.

The honest reason is narrower, and weaker. `_resolve_real_path` is not a drop-in: it re-appends the absent tail verbatim, so dot-segments *inside that tail* survive uncollapsed, and a wholly absent root yields a doubled leading slash (`//nope/db/migrations/1.sql`). The target design is the two **composed** — lexical collapse, then resolve — and this change ships the lexical half. Shipping half of a two-part design is defensible; claiming the other half was unsuitable was not.

## Consequences

- A Bash migration write whose target carries an unexpandable construct is refused, naming the path. Relative and `~/` paths are resolved and gated normally — the refusal message says so, to avoid pushing operators toward workarounds.
- Relative (with a usable `.cwd`), `~/`, `//`, `/./` and `/../` spellings now resolve to the **correct** project marker instead of silently reaching tier 2.

- **This change is not monotonic, and that is a real departure.** The first cut only ever *added* refusals, which made it easy to accept. This one moves cells in both directions: security review measured nine cases where `dev` blocked and this change allows — **under default patterns; the tally is not claimed for adopter-configured ones.** The count is also one-directional by construction, and the other direction is real: two shapes go `dev` passthru → this change hard-block, the `$LOG`-from-a-`migrations`-cwd refusal above among them. Both directions belong in a no-regressions assessment. In eight of them the allow is *correct* — the right project's ticket does satisfy the gate, and the block was the wrong-marker bug. The ninth is a genuine new gap, below. A **tenth** was found in round 6 and is now fixed rather than accepted: the sweep enumerated single-target commands only, and pass 2's first-match `break` meant a command naming migration writes in two projects was allowed outright when the earlier-matching one happened to satisfy the gate. Reversing the arguments blocked it. Measured `dev` BLOCK / BLOCK against HEAD ALLOW / BLOCK — an order-dependent verdict on a blocking gate, and #1159's own subject.

- **Known gap — a symlinked anchor makes the gate resolve a different file than the kernel writes, and here that is a NEW divergence.** Normalisation is lexical, so it cannot see a symlink. Two earlier drafts of this record got this wrong in opposite directions and both were measured, not reasoned:
  - The first claimed `<ops>/plaindir/../workspace/A/…` escaped the fork. Re-measured with real `open()` calls rather than shell `cd`: with a **plain** directory the kernel and the hook agree. There is no escape and no divergence. That retraction stands.
  - The second then folded the symlink case into the pre-existing anchor-spelling gap below. That was over-corrected. A **symlink alone is enough** — no `..` required — and for the shapes this change introduces the divergence is **not** pre-existing: `dev` never resolved a project for a relative target at all, so it fell to the ops marker and blocked; this change resolves one and allows under the caller's project ticket. This is the ninth case referenced above, and it is the one genuine new gap this change opens.
- **Known gap — un-canonicalised workspace anchors (pre-existing).** The workspace boundary is never canonicalised, so on macOS the same file addressed through `/tmp` versus `/private/tmp` resolves to different markers. `dev`'s raw prefix match is equally wrong here, so this one really is pre-existing.
- **Known gap — the meta-exemption reads the raw target (pre-existing).** `_rmt_is_meta_exempt` matches before normalisation, so `sub/docs/../db/migrations/1.sql` exempts itself on the `docs/` segment that normalisation would have removed, and skips the gate entirely. Raised by security review in round 4. Not fixed here: the exemption predates this change and moving it after normalisation widens the blast radius beyond the ticket.
- Closing all three needs `_resolve_real_path` and `pwd -P` anchors, as the sibling gate `require-active-ticket.sh` already does, plus normalising before the exemption test. That is the natural follow-up and is not attempted here.
- **The refusal blocks three shapes `dev` allowed.** Cataloguing them because the non-monotonic ledger above is the no-regressions assessment: a command spanning two projects whose tickets both satisfy the gate; one spanning a project and the ops domain where both satisfy; and one spanning two projects under different markers that both satisfy. All three are fail-closed, all three are forbidden by one-ticket-at-a-time anyway, and all three are retired by per-domain evaluation. The mirror-image over-refusal that was **not** acceptable — two projects sharing a single marker — was a round-7 defect and is fixed, not accepted.
- **The adopter-configured case is narrower than "fixed".** With `migration_paths: ["db/migrations/**"]`, the same file in the same project gates only as a bare relative path. `x/../db/…`, `./db/…`, the absolute spelling, and the whole `Edit`/`Write` half still pass ungated. That matches `dev` exactly, so it is not a regression — but the gate is not comprehensively covering configured patterns either, and an adopter who tests one spelling should not conclude otherwise. Raised by security review in round 6.
- **Why four rounds missed the round-5 regression:** zero of the then-48 cases set `migration_paths` at all, though nine wrote a `project-config.json` for other keys. The whole adopter-configuration space was untested. That is the most transferable lesson in this record, and it lived only in the test file until round 6.
- The ops-fork fallback is unchanged — a literal absolute path outside `workspace/` still legitimately uses the ops marker (case 24).
- The shared detector `_lib-detect-bash-write.sh` is untouched, so `require-active-ticket.sh` and `warn-review-marker-write.sh` are unaffected. Its contract stands; what changed is what *this gate* does with its output.
- **#1159's own description of Failure 2 was wrong, and this record corrects it.** The ticket describes the gate as matching migration paths mentioned in prose. It does not: a heredoc of bare path strings extracts only its real target. The trigger is a heredoc body containing a **write command**, which the extractor parses as a second real write. Recording that here rather than only in the PR body, so the correction survives the PR.

- **Failure 2 of #1159 is still not addressed.** A heredoc body containing a write command is extracted as a real target, so a document quoting `cat > …/migrations/…` is blocked. It reproduced repeatedly while building this change — on a probe script, a debug script, and the commit message itself. That fix carries wider blast radius, so #1159 stays open for it. **Where it belongs is now an open question, not a settled pointer.** An earlier draft said "in the shared detector" (`_lib-detect-bash-write.sh`). [AgDR-0113](AgDR-0113-heredoc-stripper-additive-only.md) § (a) rules that heredoc stripping may serve the *refinement* question ("which ref / is this exempt") but **never** the *gating* question ("is there a real command here at all") — and the gating question is exactly what that library answers, for three hooks. Following the old pointer would walk into a shape the framework has already rejected. Raised by architecture review in round 5. Reviewers noted it composes badly with this gate: the refusal advises "use a literal path", which is unhelpful for a document that is merely *quoting* one.

## Artifacts

- `.claude/hooks/require-migration-ticket.sh` — `_rmt_is_unresolvable`, `_rmt_normalise_target`, two-pass target loop
- `.claude/hooks/tests/test_require_migration_ticket.sh` — cases 23–55. Cases 31–34 pin `.cwd` trust; **cases 36–38 are what pin normalisation itself** — they use a fixture whose ops and per-project markers give opposite verdicts, so the exit code reveals which marker answered. Case 34 does not pin normalisation, contrary to an earlier draft: its target lands outside `workspace/` either way, so the ops marker answers identically normalised or not.
- PR me2resh/apexyard#1180 — seven rounds of review — Rex and Hakim throughout, joined by the Solution Architect at round 5 once the design-artifact gate applied. The first cut, the first redesign, and the `.cwd` fix were each rejected on a defect found by probing rather than by reading; this record was corrected in every one of the seven rounds — twice on this same symlink bullet, in opposite directions. Round 4 added the `~user`/`~+`/`~-` fabrication branch the round-3 fix did not reach, made both target-resolution passes ask the migration question of the same string, and gave the `.cwd` validation its first real coverage. Every fix is mutation-checked: reintroducing any one of them fails a named case.
