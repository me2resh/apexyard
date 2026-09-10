# Detect gate-invisible review markers advisorily; never repair them

> In the context of **reviewer approval markers landing at the bare-number path when an orchestrator's spawn prompt names one**, facing **a fail-closed block whose only visible symptom looks like a valid approval on disk**, I decided **to forbid literal marker paths in spawn prompts, detect offenders with an advisory hook, and teach the gates to name the near-miss** to achieve **a diagnosis that arrives before the forgery pressure does**, accepting **that nothing mechanically prevents the bad path, and that the framework will never auto-repair a misplaced marker**.

## Context

Approval markers have been repo-qualified since [AgDR-0060](AgDR-0060-review-marker-repo-qualifier.md):

```
.claude/session/reviews/<owner>__<repo>__<pr>-<role>.approved
```

Every gate that reads a marker — `block-unreviewed-merge.sh`,
`require-architecture-review.sh`, `require-design-review-for-ui.sh` — resolves
that path through `review_marker_path` in `_lib-review-markers.sh`. There is no
bare-number fallback on any **on-disk** marker lookup. (`block-unreviewed-merge.sh`
does match a bare-number basename when validating the *inline content* of a
compound write-then-merge command, but that reads the command text, not the
filesystem — it does not make a bare-number file visible to the gate.)

me2resh/apexyard#746 fixed the **producer** side: `code-reviewer.md`,
`security-reviewer.md`, and `solution-architect.md` all resolve their own path
correctly today. me2resh/apexyard#1144 reports the residual **orchestrator**
side. When the agent spawning a reviewer includes a literal path in the prompt —
*"on APPROVED, write `.claude/session/reviews/<N>-rex.approved`"* — the reviewer
obeys the instruction it was handed in preference to its own correct resolution.
The marker lands bare-number, and no gate reads it.

Two properties make this worth more than its severity suggests:

1. **The symptom inverts the truth.** `ls .claude/session/reviews/` shows a file
   named `<N>-rex.approved`. To a human that reads as a valid approval. The gate
   reports "marker missing" — accurate about the path it checked, false about
   what the operator can see. Nothing surfaces the discrepancy.
2. **The obvious repair is the forbidden one.** Moving the file into place
   satisfies the gate's *filename* without satisfying its *intent* — the exact
   behaviour `.claude/rules/pr-workflow.md` § "Build agents cannot self-review"
   exists to prevent. In the session that produced #1144, the natural workaround
   was flagged by a security classifier as indistinguishable from fabricating an
   approval. The classifier was right. An orchestrator that has blocked itself on
   a path typo, and knows the review genuinely passed, is one rationalisation
   away from writing a gate signal by hand.

So the defect is fail-closed (a blocked merge, never an unreviewed one), and its
real cost is that it *pressures an agent toward marker forgery*.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Do nothing** — #746 already fixed the producers | Zero cost; agents are correct in isolation | Leaves the orchestrator vector open and the forgery pressure with it. #1144 is a field report, not a hypothesis |
| **Bare-number fallback in the gates** — read the unqualified path too | One-line fix; the "missing" marker becomes visible immediately | Reintroduces exactly the (repo, PR) collision AgDR-0060 removed. Two repos with a PR #429 would share one marker again. **Rejected on those grounds alone** |
| **Auto-repair** — a hook renames offenders to the qualified path | Fully self-healing; operator never sees the problem | The hook would *be* the forgery. It cannot know a real review happened, only that a file exists; a build agent that wrote the file gets its marker promoted to a valid gate signal by the framework itself. **Rejected: this is the failure mode, automated** |
| **Block the write** — PreToolUse refusal on a bare-number marker path | Prevents the bad state entirely | Requires deciding from command *text* whether a write targets a marker — [AgDR-0104](AgDR-0104-trust-chain-controls-vs-backstops.md) established that shape cannot be made sound, and [AgDR-0111](AgDR-0111-marker-gate-plain-advisory.md) already demoted `warn-review-marker-write.sh` to advisory for precisely this reason. Repeating the pattern would repeat its 13-false-positives-in-one-session outcome |
| **Forbid the cause in prose + advisory detector + gate diagnosis** (chosen) | Addresses the actual vector at zero mechanical risk; makes the symptom legible at three moments; never touches a file | Self-discipline for the cause; the detector can be ignored |

## Decision

Chosen: **prose rule for the cause, advisory detection for the symptom, and a
named near-miss at the gates — with no automated repair at any layer.**

Three coordinated changes:

1. **Cause.** `/code-review`, `/security-review`, and `/design-review` each state
   that a spawn prompt must never contain a literal marker path; the reviewer
   resolves its own. Recorded as a rule in `.claude/rules/pr-workflow.md`. Two
   stale bare-number literals in `code-reviewer.md` — which contradicted that
   agent's own correct `$REX_MARKER` resolution — were corrected, along with the
   same stale form in `workflow-gates.md` and `pr-workflow.md`. Instructions that
   model the wrong path are themselves a vector.
2. **Detector.** `warn-unqualified-review-marker.sh` warns on any
   `<digits>-<role>.approved` in the reviews directory. Wired to PostToolUse
   (Write/Edit/MultiEdit/Bash, behind a payload-substring fast path) so it fires
   in the same turn as the write, and to SessionStart so leftovers from a prior
   session are swept. Always exits 0; never deletes, never renames.
3. **Diagnosis.** `unqualified_marker_hint` in `_lib-review-markers.sh` produces
   the near-miss paragraph; the three merge gates append it to their refusal
   message when an offender exists, and `/approve-merge`'s step 4 does the same.
   Every one of those surfaces states the wrong fix *as wrong* alongside the
   right one.

The "do not move it" line is load-bearing, not decoration. Naming a near-miss
without naming the wrong repair hands an agent a diagnosis and a temptation in
the same breath.

## Consequences

- **The cause is unenforced, deliberately.** No shell hook can inspect a spawn
  prompt — the `Agent` tool has no `PreToolUse` matcher ([AgDR-0056](AgDR-0056-subagent-mcp-first.md)).
  This joins the self-discipline family (`plan-mode`, `agent-role-selection`,
  `reconcile-before-build`), and the prose says so plainly rather than implying a
  backstop it doesn't have — the same honesty correction me2resh/apexyard#1044
  applied to `right-size-ceremony.md` after it cited a premium-only token meter as
  if the OSS framework shipped one.
- **A misplaced marker still blocks the merge, and that is correct.** The
  framework diagnoses; it does not repair. The only sanctioned recovery is to
  delete the gate-invisible file and re-run a real review.
- **No gate behaviour changes.** The hint is appended to an existing refusal
  path; the exit code, the marker lookup, and the SHA comparison are untouched.
  A fork without the new lib helpers degrades to today's message (the call is
  guarded and its stderr discarded).
- **The detector adds a hook to the PostToolUse Bash and Write paths.** Cost is
  one `jq` extraction plus one `grep` on the tool payload for calls that never
  mention `.approved`; a full scan only when they do.
- **This is not a security control.** A gate-invisible marker cannot produce an
  unreviewed merge. It sits with `warn-stale-review-markers.sh` and
  `check-upstream-drift.sh`, not with the merge gates.
- **AgDR-0060's collision guarantee is preserved.** The rejected fallback option
  would have undone it; nothing here reads the bare-number path as an approval.

## Artifacts

- Ticket: me2resh/apexyard#1144
- Predecessor (producer-side fix): me2resh/apexyard#746
- Marker naming scheme: [AgDR-0060](AgDR-0060-review-marker-repo-qualifier.md)
- Why text-matching gates are advisory: [AgDR-0111](AgDR-0111-marker-gate-plain-advisory.md), [AgDR-0104](AgDR-0104-trust-chain-controls-vs-backstops.md)
- Why the spawn boundary is unhookable: [AgDR-0056](AgDR-0056-subagent-mcp-first.md)
- Why Rex runs at every tier (the marker is required unconditionally): [AgDR-0116](AgDR-0116-lean-tier-reachable.md)
