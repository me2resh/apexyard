# Exempt /handover's two prescribed branches, and name the shadowed-skill recovery in the gates

> In the context of me2resh/apexyard#1161, facing a reported session where `/code-review` returned a full review but never wrote its approval marker, I decided to add an exact-literal branch exemption for `/handover`'s two prescribed branches and to name the bundled-skill shadowing failure mode in the two banners the orchestrator already reads, to achieve a merge gate that stays satisfiable through a sanctioned path, accepting that the shadowing itself is a harness-side name collision this framework cannot detect mechanically.

## Context

Issue #1161 reported three defects. Validation separated them, because they have different causes and only two are still live.

**The reported primary defect is real, and its cause is outside this repository.** ApexYard's `.claude/skills/code-review/SKILL.md` carries no `context: fork`, so it cannot run as a background subagent. Claude Code ships its own bundled `/code-review`, which has run as a background subagent since harness v2.1.218 and gained the `/review` alias in v2.1.223. The reporter's whole symptom set — a background run, findings returned through the harness rather than posted to the pull request, `ReportFindings` present in the agent's expectations, no marker, no active-reviewer marker — matches the bundled skill and cannot be produced by ApexYard's. A project skill normally overrides a bundled skill of the same name, and it does so in this fork on harness 2.1.260. It did not in the reporter's session.

The consequence is what makes this an ApexYard concern rather than someone else's bug. When the bundled skill wins the name, `block-unreviewed-merge.sh` refuses the merge and instructs the orchestrator to run `/code-review` — which runs the bundled skill again, and writes no marker again. The framework prescribes a remedy that silently cannot work, and leaves the orchestrator holding a genuine APPROVED verdict with no legitimate way to record it. The two ways out of that position are merging outside the gate and forging the marker. Both are behaviours the framework spends considerable machinery preventing, so it must not manufacture the pressure toward them.

**The reported handover defect is real and live.** `/handover` steps 8.5 and 8.6 hardcode `docs/agents-md` and `docs/apexyard-badge`. Both are rejected by `validate-branch-name.sh` (exit 2) on the current `dev`. The skill's own prescribed branch cannot satisfy the fork's own gate.

**The reported hook false-positive is real but already fixed.** On v5.1.0 the hook blocked two of three realistic tracker-create shapes that merely described a marker path in prose. On `dev` all three exit 0 silently. #1000 and #1026 fixed it in v5.3.0; #1026 made the hook advisory per AgDR-0111.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Detect the shadowed skill mechanically | Would catch it without operator judgment | Not possible. A `PreToolUse` hook sees tool calls, not which skill the harness resolved a name to; the `Agent` spawn boundary has no matcher (AgDR-0056) |
| Rename ApexYard's skill to avoid the collision | Removes the collision outright | Breaks every banner, rule, and doc that names `/code-review`, and breaks operator muscle memory, to work around a harness-version-specific resolution bug |
| Tell adopters to set `disableBundledSkills` | Settles the collision permanently | A global setting disabling every bundled skill, imposed on all adopters, to fix a failure most never hit |
| **Name the failure and the recovery in the two banners the orchestrator already reads** | Reaches the reader at the exact moment they are stuck, costs nothing when the bug is absent, needs no new surface | Advisory. It informs a decision; it cannot force one |
| Relax the merge gate when no marker can be obtained | Unblocks the session | Rejected outright. A gate that yields to "I could not get a marker" is not a gate |
| **Exact-literal branch exemption for the two `/handover` names** | Mirrors the existing `release/` and `sync/` precedent; anchored regex exempts nothing else | Slightly widens a gate-relaxing surface |
| Give `/handover` a ticket-carrying branch name | No hook change | There is no ticket to name. `/handover` is bootstrap-class, runs before the adopted repo has tickets, and the adopted repo may have no tracker |

## Decision

Chosen: **the exact-literal branch exemption plus the banner-level recovery**, because each addresses its defect at the smallest surface that can carry it.

The branch exemption follows a precedent this repository already set twice. `release/vN.N.N` and `sync/main-to-dev-after-vN.N.N` are exempt for the same stated reason: a framework-prescribed, canonical, ticketless branch where the work itself is the ticket. `/handover`'s two branches share that shape and add a stronger argument — they are pushed into an **adopted** repository that ApexYard does not govern the SDLC of, and they land as a pull request its owner reviews. The regex is anchored on both ends against the two names, so `docs/agents-md-v2` and every other `docs/*` branch still require a ticket ID.

The shadowed-skill recovery is deliberately advisory, because no sound mechanical detection exists. It states two identifying signs, and it states the recovery: set the active-reviewer marker, then spawn Rex directly with the Agent tool. That path restores the sanctioned review without anyone touching a gate signal by hand. Both banners say plainly not to write the marker, because a good review does not make a hand-written marker legitimate.

The already-fixed hook false-positive gets no code change. It is reported back to the issue with the fixing version.

## Consequences

- `/handover` steps 8.5 and 8.6 can complete. Both skill steps now carry a note that the branch name is load-bearing, so a later reader does not "tidy" it and silently re-arm the gate.
- An orchestrator stuck behind a marker-less review is told what happened and what to do, at the moment the merge is refused and again when the pull request is created.
- The exemption widens the branch gate by exactly two names. It cannot be extended by accident: matching more names requires editing the anchored regex.
- The shadowing itself remains undetected. An operator who ignores both banners is in the same position as before, minus the false impression that re-running `/code-review` will help.
- Adopters who hit the collision every session have two settled options named in the rule, neither of them required.

## Artifacts

- me2resh/apexyard#1161
- `.claude/hooks/validate-branch-name.sh`, `.claude/hooks/block-unreviewed-merge.sh`, `.claude/hooks/auto-code-review.sh`
- `.claude/rules/pr-workflow.md` section "When the harness bundled skill shadows /code-review"
- `.claude/skills/handover/SKILL.md` steps 8.5 and 8.6
- `.claude/hooks/tests/test_validate_branch_name_handover.sh`
- Prior art: AgDR-0007 (release branches), AgDR-0052 (sync branches), AgDR-0111 (marker gate advisory), AgDR-0056 (no spawn-boundary matcher)
