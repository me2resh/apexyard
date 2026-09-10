# Migration gate resolves what it can and refuses what it cannot

> In the context of the migration gate deciding which ticket governs a Bash write, facing targets it resolved against the wrong project, I decided to **fix resolution only — leaving the set of writes this gate governs identical to `dev`'s** — to achieve a correct governing ticket without widening a blocking gate, accepting that the multi-target and heredoc halves of #1159 stay open.

**The one-sentence property this change claims:** *the set of writes this gate governs is identical to `dev`'s; what changed is which ticket answers.* It is established by measurement — `dev` and this HEAD instrumented over the same command corpus — and pinned by enumerated cases, each mutation-checked.

A differential test was added in round 8 and **removed in round 9**: it extracted `is_migration_path` from the `dev` blob and from HEAD, and those are byte-identical, so it compared a predicate to itself and never invoked a selection pass. Reintroducing the round-5 defect left it passing. It also never ran in CI — the workflow checks out at `fetch-depth: 1`, so the baseline blob is absent, the test skipped silently, and the runner hid the skip. Three reviewers measured this independently. Testing the property properly means comparing what each version *selects from the same payload*, with a CI-available baseline and an absent baseline treated as a failure; that is carried into me2resh/apexyard#1182. The CI half — a suite that cannot obtain its baseline must FAIL rather than skip, and the runner must not report a skipped suite as a pass — is me2resh/apexyard#1183.

**Status**: Accepted
**Date**: 2026-09-05
**Ticket**: me2resh/apexyard#1159
**Related**: [AgDR-0104](AgDR-0104-trust-chain-controls-vs-backstops.md) (pattern-matching command text cannot be made sound) · me2resh/apexyard#1152 (fail-closed across blocking hooks) · me2resh/apexyard#1181 (composes `_resolve_real_path` after the lexical collapse this record deferred; retires two of the three "Known gap" bullets below)

## Context

`require-migration-ticket.sh` extracts a write target from a Bash command, matches it against the migration-path patterns, then resolves which project owns it to pick the right ticket marker. The marker lookup has three tiers: per-worktree, per-project, and an ops-level fallback at `.claude/session/current-ticket`.

When the target cannot be mapped to a project, the lookup falls through to tier 2 — so the gate evaluates the write against **a different ticket than the one governing that worktree**, and reports nothing. On the session that produced #1159, a correct per-worktree marker existed the whole time and a stale ops-level marker from earlier work answered instead.

The reviewer's framing on the issue is the precise one: `_lib-detect-bash-write.sh` deliberately prefers false negatives and promises that an unparseable segment "contributes nothing, never a fabricated target". That is right for a **detector**. For a **gate** it is wrong — falling back is not degrading to *no opinion*, it is degrading to *someone else's answer*.

**The first cut of this change refused only targets containing `$`.** Review of PR #1180 established that this did not deliver the property it claimed, in three separate ways:

1. **Ordering bypass.** The check ran *after* the `#886` loop, which stops at its first migration-shaped match. A compliant literal target named first smuggled a later unresolvable one straight past the gate.
2. **Incomplete condition.** A backtick is the same bash feature as `$(…)`; one was caught, the other was not. Relative and `~/` targets also reached tier 2 unresolved.
3. **False positive on the wrong tool.** The check also applied to `Edit`/`Write`, where `file_path` never passed through a shell — so a literal filename containing `$` was hard-blocked, with a message asserting a cause that had not been observed.

### A labelling correction, because this record propagated the error

This document numbers #1159's failures as: **Failure 1**, the wrong-marker fallthrough — an unresolvable or relative target reaching the wrong ticket. **Failure 2**, the heredoc problem — a heredoc body containing a write command extracted as a real target.

Through rounds 4–8 the PR's commit messages, probe scripts and reviewer briefs repeatedly called the *wrong-marker* problem "Failure 2". It is Failure 1. Architecture review caught it in round 8. **Failure 1 is what this change addresses; Failure 2 was never in scope and stays open.**

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Resolve what is resolvable, refuse what is not (chosen)** | Closes the class rather than one spelling; `~/`, `//`, `/./` and `/../` targets gate *correctly* instead of reaching tier 2 (relative targets do **not** — see the cons cell); order-independent (of **both** passes — round 4 gave pass 1 that property and round 6 finally gave it to pass 2, which had kept a first-match `break`; this cell overclaimed in between) | More code than a single guard. The relative-target half was attempted via the harness `.cwd` and **withdrawn in round 9** — see the Decision section; relative targets are not resolved by this change |
| Refuse on `$` only (the first cut) | Smallest diff | Rejected in review — leaves backticks, `$(…)`, relative and `~/` on the wrong marker, is order-dependent, and false-positives on `Edit`/`Write` |
| Refuse anything not absolute | Simple and strictly safe | Refuses relative paths that are perfectly resolvable; maximises the bypass pressure the ticket already warns about |
| Warn and continue on the ops marker | No workflow interruption | Keeps evaluating against the wrong ticket; a warning in hook output is not a control |
| **Reuse `_resolve_real_path` from `_lib-path-resolve.sh`** | Already shipped; `realpath -m` semantics, so it resolves an absent file *and* one behind a symlinked ancestor — closing the symlink gap this change leaves open; the sibling gate `require-active-ticket.sh` already uses it | Not a drop-in: it re-appends the absent tail verbatim, so dot-segments inside that tail survive, and a wholly absent root yields a doubled leading slash (`//nope/…`). Composing it *after* a lexical collapse is the target design; this change ships the lexical half only, as a staged step. Raised by architecture review in round 5, after two earlier drafts justified the lexical choice on a ground this helper refutes |
| Refuse whenever project resolution fails | Simple condition | **Breaks a legitimate case** — a literal path outside `workspace/` also leaves the project empty, and the ops marker is correct there |

## Decision

### Round 8: the change was narrowed after the stopping rule fired

Rounds 6, 7 and 8 each produced a defect in the multi-target machinery, every one an adjacent case escaping the same single-representative election:

| Round | Key the election used | How it escaped |
|---|---|---|
| 6 | first match wins | a command spanning two projects was approved by whichever matched first |
| 7 | project **name** | the ops domain's name is empty, so that member was silently dropped |
| 8 | marker **path** | one ticket reached through two marker files — a fresh subdirectory misses tier 0, because `git -C` fails on a directory that does not exist |

Each key is a *proxy* for the governing ticket, and each proxy agreed with the ticket until it didn't. Round 8 tripped the stopping rule this record adopted, so the machinery was **removed rather than repaired a fourth time**.

What ships is resolution only:

- **Selection asks the RAW spelling, in both passes.** Normalisation serves resolution alone. Normalisation-in-selection was never part of fixing #1159 — it arrived as a side effect, widened the governed set beyond the ticket, and generated two of the eight defects.
- **Pass 2 selects first-match, exactly as `dev`.** Pass 1 keeps its order-independent scan for unresolvable targets, which is Failure 1's subject and does not widen anything.
- **The accumulator and its multi-marker refusal were removed in #1180.** Cases 49–54 were restored, and the per-target evaluation that replaces that design is complete in #1182.

**What #1180 therefore does NOT close, stated plainly rather than softened:** the two-project order-dependent fail-open remains, inherited unchanged from `dev`. This record previously called that shape "#1159's own subject". So **#1159 stays open for two things** — the heredoc (Failure 2) and the multi-target order-dependence — and this is a scope reduction, recorded as one.

**Amendment — #1182 closes the multi-target item.** The historical statements above describe the #1180 boundary and remain useful for reconstructing why the redesign was required. The current implementation no longer has a first-match representative: each selected migration target is resolved and gated independently, so the order-dependent two-project fail-open is closed. The heredoc detector question remains outside this ticket.

**The price, paid knowingly.** `<abs>/migrations/../1.sql` was allowed while selection normalised, and is governed again now, so `dev`'s false positive returns with it. It was never part of fixing #1159; it arrived with normalisation-in-selection. Retiring it properly belongs to #1182.

**The nine-cell enumeration is superseded, not recounted.** Under the differential property every remaining delta is a *resolution* delta by construction, which is a smaller and better-defined set than the enumeration it replaces. Re-deriving a count for a sweep whose premise changed would be arithmetic dressed as evidence.

Chosen: **resolve, then refuse**, in two passes over every extracted target.

- **Pass 1** examines *all* targets before any is selected, so refusal cannot depend on argument order. A target is unresolvable when it carries a shell variable, a command substitution, or a backtick — constructs whose value is unknowable without executing the command. Refusal is scoped to targets that are migration-shaped in their **raw** spelling.

  Rounds 4–7 had pass 1 test both the raw and normalised spellings. That is gone: it made pass 1 refuse writes that pass 2 no longer governs — a refusal for a write this change declares out of scope — and it was one of the two selection widenings that generated defects. One question, one spelling, both passes.

  An earlier draft offered `$LOG` as reassurance that unrelated redirects are not refused, then round 5 made that example false. Under raw-only selection the reassurance is true again, and true for a checkable reason rather than by inspection: `echo x > $LOG` is not migration-shaped raw, on `dev` or here.

- **Pass 2** selects the **first** migration-shaped target by its **raw** spelling — exactly as `dev` — and normalises only that target, for resolution. Selection set identical to `dev` by construction; resolution is the fix.

  Judging every target against its own governing ticket is **me2resh/apexyard#1182**, not this change. Three attempts at it (rounds 6, 7, 8) each produced an adjacent-case defect, because each held a different *proxy* for the governing ticket — first-match, then project name, then marker path. #1182 removes the need for a proxy instead of choosing a better one, by sharing `require-active-ticket.sh`'s resolver rather than keeping a private copy of the question.

  The round-5 adopter-pattern fix is **subsumed, not reverted**: raw-only selection makes repo-relative `migration_paths` match directly, which is why they work on `dev` too. Its defect was normalised-*only* selection; the fix for that was to ask both spellings, and asking one — the raw one — is strictly simpler and matches `dev`.

The resolvability check is **Bash-only**. An `Edit`/`Write` `file_path` is a literal string that never met a shell, so a `$` there is an ordinary filename character.

**The harness `.cwd` is not read at all.** Rounds 3–8 read it from `.cwd // .tool_input.cwd`, validated it as absolute-and-existing (the two conditions `verify-commit-refs.sh` applies to the same field), and joined relative targets to it. **Round 9 removed that**, and this paragraph previously prescribed the removed design — the failure mode being that #1182 is the ticket which redoes relative-path resolution, and an engineer working from this record would have carried the mechanism forward.

Security review measured why it cannot work: `.cwd` is fixed when the tool call is *formed*, so it cannot see a `cd` inside the command. `cd <B> && cat > ./migrations/1.sql` with `.cwd = <A>` was approved against **A's** ticket while the write landed in **B**. Validating that `.cwd` is a real directory establishes that it exists, not that it is the directory the write happens in. Teaching the join about `cd` / `pushd` / `git -C` was rejected: that is deciding a gate by pattern-matching shell command text, which [AgDR-0104](AgDR-0104-trust-chain-controls-vs-backstops.md) rules cannot be made sound.

A relative target is therefore left **un-normalised** and behaves exactly as on `dev`. It is deliberately not refused — refusing would newly block writes every prior version allowed, which is the bypass pressure this gate can least afford.

### This is weaker than the sibling gate, in ways that matter

An earlier draft of this record claimed the change "mirrors `require-active-ticket.sh`". That was wrong, and the difference is the substance. **Updated by me2resh/apexyard#1181** — two of the three rows below are now closed; see the note after the table.

| | `require-active-ticket.sh` | this gate |
|---|---|---|
| Symlinks | resolved via `_resolve_real_path` | resolved via `_resolve_real_path`, composed after the lexical collapse (me2resh/apexyard#1181) |
| Boundary anchors | canonicalised with `pwd -P` | canonicalised with `pwd -P` (me2resh/apexyard#1181) |
| Containment | four-way raw-AND-resolved check, added for #885's mirror-image hole | single prefix match against the canonicalised anchor |

Lexical `/../` collapsing does not consult the filesystem, so it can disagree with the kernel when a symlink is in the path — the reason #1181 composes `_resolve_real_path` after the lexical pass rather than replacing it with it (see the two RETIRED "Known gap" bullets below).

The Containment row is the one dimension #1181 leaves as recorded, and deliberately: the two functions answer different questions. `require-active-ticket.sh`'s four-way check decides whether a write is EXEMPT from every tracked tree; this gate's single check decides WHICH tracked tree's marker applies once a write is already known to need one. Extending to a four-way check was not evaluated as part of #1181's scope and is not claimed here.

**The direction of this divergence is now narrower.** The framework's own rails call migrations never-Lean and highest-blast-radius; before #1181, the migration gate resolved paths *more weakly* than `require-active-ticket.sh` on two of three dimensions. #1181 closes the Symlinks and Boundary anchors rows for the shapes named in the "Known gap" bullets below; the Containment row remains a genuine, acknowledged design difference rather than an oversight, and the narrower residual noted under the retired symlink-anchor bullet (a `..` immediately after a differently-nested symlink) is unchanged by either gate.

#### The single-representative structure is the defect generator

Worth stating plainly, because the review history is the evidence. Seven commits have approximated one property — *every target is judged against the marker that governs it* — seven different ways, and each left an adjacent case: the ordering bypass in pass 1 (round 2), the first-match `break` in pass 2 (round 6), the unrepresentable ops domain in the fix for that (round 7).

The structural cause is that everything before Gate 1 exists to elect **one** `FILE_PATH` to stand for the whole command, because the tail can evaluate exactly one marker. Each fix improves the election; none removes the need to hold one. Architecture review named this in round 7 and recommended **restructure rather than continue iterating** for the remaining work, staged as: this commit's marker-keyed accumulator, then the resolution half (`_resolve_real_path` composed after the lexical collapse), then per-domain evaluation — which retires the refusal above and removes the election entirely.

A stopping rule was set with it, and this record adopts it: **if another defect of this same class appears, restructure before merging anything further.** It fired in round 8, and the restructure is me2resh/apexyard#1182 — which architecture review reframed from *per-domain evaluation* to **sharing the sibling gate's resolver**: every defect in this sequence came from this hook holding a private copy of a question `require-active-ticket.sh` already answers.

**Status — completed by me2resh/apexyard#1182.** The migration gate now sources `_lib-active-ticket.sh`, the same resolver used by `require-active-ticket.sh`. It resolves relative targets from the hook's real working directory, walks to the nearest existing ancestor for tier-0 worktree detection, and evaluates every migration-shaped target independently. The governing domain is the marker's ticket identity (repository plus issue number), so two paths that share a ticket are one authorization domain without electing a representative path. The former private `_rmt_project_for_path` / `_rmt_marker_for_path` functions and the single-representative accumulator are retired. Cases 49–54 and the selection-parity test are restored; a missing baseline is now a test failure.

#### One resolution regime, one selection spelling

Worth naming, because this record's own repeated failure has been an argument made in one place and not carried to another. `RESOLVED_TARGET` is **always** the normalised spelling, so on the Bash path marker resolution never runs on the raw one. (Scoped deliberately: on the `Edit`/`Write` path `FILE_PATH` is the literal `file_path` and is never normalised at all. An earlier draft stated this without the scope — the same overclaim shape corrected one section above.) Selection asks the **raw** spelling only, in both passes (round 8). It asked both spellings in rounds 5–7; that widening was never part of fixing #1159 and generated two of the defects.

The failure directions are not symmetric, which is why the two halves are separated at all. Selection failing low switches the gate off silently — round 5's blocker. Selection failing high over-blocks: fail-closed and visible. **Resolution** failing wrong picks the wrong ticket, which is the bug this change exists to fix.

Rounds 5–7 answered that asymmetry with *match liberally, resolve canonically*. Round 8 replaced it with something checkable: **match exactly as `dev`, resolve canonically.** Matching liberally is what put selection in territory `dev` never runs, and three of the four rounds that moved it produced a defect.

Normalising the adopter patterns instead was considered and rejected: absolutising a repo-relative pattern needs the repo root it is relative to, which is per-project, and the project is precisely what is unknown until the path has been resolved. Circular — and it would silently redefine an adopter configuration surface inside a fail-closed fix. Raised by architecture review in round 6; the invariant is pinned by cases 36–38 but was previously nowhere stated.

#### Why lexical, honestly

Two earlier drafts of this record — and the code comment — justified the lexical canonicaliser with *"lexical (not realpath) so a not-yet-created migration file still resolves."* **That reason is false and is withdrawn.** `_resolve_real_path` in `_lib-path-resolve.sh` has `realpath -m` semantics: it walks up to the first existing ancestor, `pwd -P`s it, and re-appends the absent tail. Measured at this HEAD, it resolves an absent file *and* an absent file behind a symlinked ancestor in one call. The record was defending its central architectural call on a ground its own named follow-up refutes. Caught by architecture review in round 5.

The honest reason is narrower, and weaker. `_resolve_real_path` is not a drop-in: it re-appends the absent tail verbatim, so dot-segments *inside that tail* survive uncollapsed, and a wholly absent root yields a doubled leading slash (`//nope/db/migrations/1.sql`). The target design is the two **composed** — lexical collapse, then resolve — and this change ships the lexical half. Shipping half of a two-part design is defensible; claiming the other half was unsuitable was not.

## Consequences

- A Bash migration write whose target carries an unexpandable construct is refused, naming the path. `~/` paths and relative paths are resolved by the shared resolver; relative paths are anchored to the hook process's real working directory, not the advisory payload `.cwd`.
- `~/`, `//`, `/./`, `/../`, and ordinary relative spellings resolve to the governing project marker. A target whose migration directory does not yet exist walks to its nearest existing ancestor for tier-0 worktree detection.

- **This change is not monotonic, and that is a real departure.** The first cut only ever *added* refusals, which made it easy to accept. This one moves cells in both directions: security review measured nine cases where `dev` blocked and this change allows — **under default patterns; the tally is not claimed for adopter-configured ones.** The count is also one-directional by construction, and the other direction is real: two shapes go `dev` passthru → this change hard-block, the `$LOG`-from-a-`migrations`-cwd refusal above among them. Both directions belong in a no-regressions assessment. In eight of them the allow is *correct* — the right project's ticket does satisfy the gate, and the block was the wrong-marker bug. The ninth is a genuine new gap, below. A **tenth** was found in round 6 — the sweep enumerated single-target commands only, and pass 2's first-match `break` meant a command naming migration writes in two projects was allowed by whichever matched first. Rounds 6–8 tried three times to fix it and produced a defect each time; round 8 removed the machinery instead. **That cell is not fixed. It remains, inherited unchanged from `dev`**, and #1159 stays open for it — see the Decision section, which this bullet previously contradicted.

  An **eleventh** was found in round 9 and is fixed: the `.cwd` join approved a write in one project against another project's ticket whenever the command changed directory first (`cd <B> && cat > ./migrations/1.sql` with `.cwd = <A>`). `dev` blocked it; the join allowed it silently, while the same write named absolutely stayed blocked — so the verdict depended on the spelling, and the permissive spelling is the ordinary one. The join is removed rather than taught about `cd`: deciding a gate by pattern-matching shell command text is what AgDR-0104 rules cannot be made sound.

- **Known gap — `..` crossing a symlinked anchor resolves to the wrong project. RETIRED for the shape this bullet names, by me2resh/apexyard#1181.** Composing `_resolve_real_path` after the lexical collapse makes a migration write reached through a symlinked ancestor resolve to the same project the kernel's write is governed by. Verified for a direct symlinked ancestor with no `..` involved, and for a `..` immediately after a symlink whose target sits at the SAME depth as the symlink itself — the shape a workspace-registered project alias actually takes, and the shape this bullet's own `<ws>/symproj/../other/db/migrations/1.sql` example describes when `symproj` and the project it aliases are both direct children of the workspace root.

  A narrower shape is not proven, named here rather than buried: a `..` immediately following a symlink whose target is nested at a DIFFERENT depth than the symlink's own position can still diverge from the kernel's answer. `_resolve_real_path`'s per-ancestor `cd ... && pwd -P` inherits bash's LOGICAL (not physical) handling of a compound symlink-then-`..` argument, which is not always what `open()`/`stat()` do for the same string. Measured directly for this one compound shape: `dev` and #1181 give the IDENTICAL wrong answer. Not a regression, and not newly introduced by #1181, but not closed by it either — a limitation of the shared `_resolve_real_path` helper (also used by `require-active-ticket.sh`), not of this gate's composition. Not separately tracked.

- **Known gap — un-canonicalised workspace anchors (pre-existing). RETIRED for the shape that reaches this gate's own code, by me2resh/apexyard#1181.** `require-migration-ticket.sh` now canonicalises `WORKSPACE_DIR`/`OPS_ROOT` with `pwd -P` before the containment check, mirroring `require-active-ticket.sh`'s anchor canonicalisation, so a workspace boundary reached through a symlink compares the same way regardless of which spelling addressed it.

  Worth stating precisely, because it narrows the claim: in the default configuration — `_lib-portfolio-paths.sh` and `_lib-read-config.sh` both present, which is every fork this framework ships — `WORKSPACE_DIR` was already canonical before this fix, because `portfolio_workspace_dir()` resolves its result through `_portfolio_canonicalize` (the same `pwd -P`-based algorithm as `_resolve_real_path`, defined separately in `_lib-portfolio-paths.sh`). This gate's own `/tmp` vs `/private/tmp` bug was therefore reachable only when that override does not fire — the "library missing" fallback this file already exercises for its other libs (a minimal test sandbox, or a clone missing those two files) — and #1181 closes exactly that path. Confirmed by testing both hook versions with the two libraries deliberately absent from the sandbox: pre-#1181 the raw anchor misses the match and falls to the ops marker; #1181 finds the correct project marker.

  **Correction (PR me2resh/apexyard#1198 review, finding B1) — the anchor fix above shipped with a permissive regression of its own; it has since been fixed.** The version first submitted for #1181 canonicalised `WORKSPACE_DIR`/`OPS_ROOT` only when the directory already existed on disk — `[ -n "$X" ] && [ -d "$X" ]` gating a raw `cd ... && pwd -P` — and left the anchor EMPTY otherwise. An absent directory reaches that gap on the first clone of any fresh split-portfolio v2 sibling repo or `.portfolio.workspace_dir` override; a dangling symlink reaches the identical gap by a different route, since `[ -d ]` follows a symlink and reports false when its target is missing. `_rmt_project_for_path`'s first branch is skipped on an empty anchor, so the gate silently stopped identifying the governing project and fell through to the tier-2 ops-level marker instead — #1137's cross-repo authorisation hole, reachable on a path this same change opened. Both code review and security review returned CHANGES REQUESTED on the identical finding; security review additionally measured it empirically, sweeping present / absent / dangling-symlink workspace directories across both the `Edit`/`Write` and `Bash` tool paths against `dev` as the baseline.

  The fix composes `_resolve_real_path` for the anchors, exactly as `_rmt_normalise_target` already does for the target, falling back to the raw anchor only when the helper itself is unavailable (the missing-library degrade the hook already carries). `_resolve_real_path` has `realpath -m` semantics — it canonicalises an absent path by walking to the nearest existing ancestor and re-appending the missing tail — so it never needed the target to exist; the existence guard was not load-bearing for anything the original fix required; it only ever bought a false sense of safety. Security review's framing is the one worth keeping: this gate already refuses an unresolvable migration **target** outright (`_rmt_is_unresolvable` → exit 2); it simply had not extended that same fail-closed posture to an unresolvable **anchor**. It now does. Four cases close the coverage gap the regression exposed — `test_require_migration_ticket.sh` cases 1181-6 through 1181-9, an absent and a dangling-symlink workspace directory on both tool paths — mutation-checked against the existence-gated block this correction replaces: each passes with the fix and fails against it reverted, and none of the 53 cases already in the suite exercised either shape.

- **Known gap — the meta-exemption reads the raw target (pre-existing).** `_rmt_is_meta_exempt` matches before normalisation, so `sub/docs/../db/migrations/1.sql` exempts itself on the `docs/` segment that normalisation would have removed, and skips the gate entirely. Raised by security review in round 4. Not fixed by #1181 either: the exemption predates both changes, and moving it after normalisation widens the blast radius beyond either ticket. Still needs normalising before the exemption test — the natural follow-up, not attempted here.
- **The multi-marker refusal is gone, so it blocks nothing.** Every migration-shaped target is now evaluated independently. Paths sharing a marker ticket form one domain; distinct marker tickets are each checked, regardless of argument order.
- **The delta set has three categories, not two.** Resolution deltas (the fix), pass-1 refusals (new, fail-closed), and selection deltas — of which there are now none by construction, measured across 61 and 314 command shapes by two independent sweeps.

  An earlier version of this bullet called pass-1 refusals *the only* direction in which this change blocks what `dev` allowed. That is false: resolution deltas block too, `workspace/alpha/../beta/migrations/1.sql` among them. The new block is correct — it is the right project's ticket answering — but the claim about where blocks originate was not.
- **Tier-0 ancestor detection — closed by #1182.** The shared resolver walks from a not-yet-created migration directory to the nearest existing ancestor before asking Git for the governing worktree branch. The migration suite includes a regression case for this shape.
- **Per-target meta-exemption — covered by #1182.** The exemption is applied inside the per-target check, so a documentation target cannot shadow a migration target later in the same command.
- **Mutation state, stated rather than summarised.** The round-9 sweep ran 17 mutations over every surviving behaviour, extended to 18 in round 10, not only the ones changed: **14 killed, 3 surviving** (the per-target meta-exemption; the bare-`~` arm, which is unobservable because `~` alone is never migration-shaped; and tier 0).

  An independent 15-mutation set run by security review in round 10 found **two more** this sweep did not account for: the **`..` arm of the lexical canonicaliser** (the `//` and `/./` arms are pinned; `..` was not) and **pass-1's raw-only selection**. Both are missing-test rather than defect. The `..` arm was pinned in round 10 — it is the mechanism behind both the intended fix and the symlink gap above, so leaving the most load-bearing line in the change uncovered was not defensible. Pass-1 raw-only selection is recorded here and carried to #1182. Two survivors found mid-round were consequences of this round's own edits — removing the `.cwd` join disarmed the tilde and no-fabrication cases — which is the round-9 lesson: a previously mutation-checked case stops discriminating when the code *around* it moves, and deleting a neighbour disarms one just as easily. Both were repaired before this landed.
- **Relative target resolution — closed by #1182.** Relative targets are absolutized against the hook process's `pwd -P` and then passed through the shared canonical resolver. The payload `.cwd` is intentionally not trusted for this decision.
- **Tier-0 coverage — closed by #1182.** The suite covers both the worktree-branch environment marker and the linked-worktree/nearest-existing-ancestor path.
- **Correction — an earlier claim in this PR that two surviving mutants proved two mechanisms independently sufficient was incomplete.** Code review found a third, unnamed property they were coupled to: `RESOLVED_TARGET` holding the *first* match. The claim is withdrawn; the machinery it described is gone.
- **The adopter-configured case is narrower than "fixed".** With `migration_paths: ["db/migrations/**"]`, the same file in the same project gates only as a bare relative path. `x/../db/…`, `./db/…`, the absolute spelling, and the whole `Edit`/`Write` half still pass ungated. That matches `dev` exactly, so it is not a regression — but the gate is not comprehensively covering configured patterns either, and an adopter who tests one spelling should not conclude otherwise. Raised by security review in round 6.
- **Why four rounds missed the round-5 regression:** zero of the then-48 cases set `migration_paths` at all, though nine wrote a `project-config.json` for other keys. The whole adopter-configuration space was untested. That is the most transferable lesson in this record, and it lived only in the test file until round 6.
- The ops-fork fallback is unchanged — a literal absolute path outside `workspace/` still legitimately uses the ops marker (case 24).
- The shared detector `_lib-detect-bash-write.sh` is untouched, so `require-active-ticket.sh` and `warn-review-marker-write.sh` are unaffected. Its contract stands; what changed is what *this gate* does with its output.
- **#1159's own description of Failure 2 was wrong, and this record corrects it.** The ticket describes the gate as matching migration paths mentioned in prose. It does not: a heredoc of bare path strings extracts only its real target. The trigger is a heredoc body containing a **write command**, which the extractor parses as a second real write. Recording that here rather than only in the PR body, so the correction survives the PR.

- **Failure 2 of #1159 is still not addressed.** A heredoc body containing a write command is extracted as a real target, so a document quoting `cat > …/migrations/…` is blocked. It reproduced repeatedly while building this change — on a probe script, a debug script, and the commit message itself. That fix carries wider blast radius, so #1159 stays open for it. **Where it belongs is now an open question, not a settled pointer.** An earlier draft said "in the shared detector" (`_lib-detect-bash-write.sh`). [AgDR-0113](AgDR-0113-heredoc-stripper-additive-only.md) § (a) rules that heredoc stripping may serve the *refinement* question ("which ref / is this exempt") but **never** the *gating* question ("is there a real command here at all") — and the gating question is exactly what that library answers, for three hooks. Following the old pointer would walk into a shape the framework has already rejected. Raised by architecture review in round 5. Reviewers noted it composes badly with this gate: the refusal advises "use a literal path", which is unhelpful for a document that is merely *quoting* one.

## Artifacts

- `.claude/hooks/_lib-active-ticket.sh` — shared path, project, ancestor, and marker resolution used by both gates.
- `.claude/hooks/require-active-ticket.sh` — delegates project and marker resolution to the shared library.
- `.claude/hooks/require-migration-ticket.sh` — normalises targets, then checks every migration-shaped target through the shared resolver; no representative election remains.
- `.claude/hooks/tests/test_require_migration_ticket.sh` — cases 23–48, 49–54, 1181-1 through 1181-9, and the current-versus-baseline selection parity test.
- PR me2resh/apexyard#1180 — nine rounds of review — Rex and Hakim throughout, joined by the Solution Architect at round 5 once the design-artifact gate applied. The first cut, the first redesign, and the `.cwd` fix were each rejected on a defect found by probing rather than by reading; this record was corrected in every one of the nine rounds — twice on this same symlink bullet, in opposite directions. Round 4 added the `~user`/`~+`/`~-` fabrication branch the round-3 fix did not reach and made both target-resolution passes ask the migration question of the same string. Round 9 removed the `.cwd` join entirely after security review found it approved a write against a ticket that did not govern it. Every fix is mutation-checked: reintroducing any one of them fails a named case.
