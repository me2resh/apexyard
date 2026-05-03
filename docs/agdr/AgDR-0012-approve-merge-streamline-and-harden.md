# /approve-merge — structured CEO marker + same-turn merge

> In the context of the merge-gate workflow that requires explicit per-PR CEO approval, facing two compounding frictions — (a) the existing skill writes the marker but stops before the merge, requiring a second user message ("merge it" / "go") that adds latency on every PR without any independent safety check (#132), and (b) the marker is just a bare SHA on a single line, so the model can mechanically bypass the gate by writing `echo SHA > <pr>-ceo.approved` directly without the skill ever running (#48, surfaced as a real-world incident on a managed project's PR) — I decided to ship a **bundled** change that (1) introduces a structured key/value marker format with required fields `sha=`, `approved_by=user`, `skill_version=2`, validated by `block-unreviewed-merge.sh`, and (2) makes the skill's default flow record-the-marker AND run `gh pr merge --squash --delete-branch` in the same turn, with `--no-merge` as an opt-out for the rare deferred-merge case, to achieve a clearer authorization model — "the load-bearing rule is explicit per-PR approval, not two user messages" — accepting that the structured fields can in principle be fabricated by a determined model (the protection is procedural visibility, not cryptographic), that bare-SHA legacy markers from the previous skill version are mechanically rejected (re-run `/approve-merge` once if you have stale markers in flight), and that this is one bundled PR closing #132 only (with #48 closed manually post-merge per the single-Closes-per-PR rule, precedent: AgDR-0010 / PR #147 + AgDR-0011 / PR #152).

## Context

Two threads converged on the merge-gate skill:

**Thread 1 — UX friction (#132).** Every successful merge in this session and earlier ones followed the same pattern: I ask "PR #X ready to merge — approved?", user replies "X approved", I invoke `/approve-merge X` (which writes the marker and STOPS), then I have to ask again ("Confirm and I'll run gh pr merge?"), user says "go" / "X approved" again, I run the merge. Two user messages for one authorization moment.

The skill's stated rationale for stopping was "the user might change their mind in the 30 seconds between approval and merge." In practice, this never happened — the markers were always merged on the next message — but the friction was paid every time. Three merges in this session × 2 ≈ 6 redundant round-trips that added ≈ 30 seconds to the wall-clock of each merge.

**Thread 2 — Real bypass surface (#48).** A real incident on a managed project's PR earlier this year — a CEO marker was written with the model's `echo HEAD_SHA > <pr>-ceo.approved` rather than via the skill, and the merge succeeded. The bare-SHA format means the gate's check (`marker SHA == HEAD SHA`) passes for any one-line marker the model can write, regardless of whether the user ever approved.

The two-message ceremony in #132 was indirectly hedging against #48 — splitting authorization across messages made an accidental bypass harder because *both* messages had to be unambiguous. But that's a procedural defence against a mechanical problem. Once the marker format itself is hardened, the second message has no work left to do.

So the threads couple: shipping #132 alone weakens the procedural defence against #48; shipping #48 alone keeps the friction. The right shape is to ship them together — harden the marker format AND drop the second-message ceremony, with each change reinforcing the other.

## Options

### Option A — Ship #132 only (drop the ceremony, keep the bare-SHA marker)

| Pros | Cons |
|------|------|
| Smallest diff | Leaves the bypass surface from #48 wide open |
| No format-change migration | Procedural defence (two messages) is the only barrier — and we just removed it |

Rejected. Removes friction at the cost of safety.

### Option B — Ship #48 only (harden the marker, keep the two-message ceremony)

| Pros | Cons |
|------|------|
| Closes the bypass | Friction stays — every merge still costs two messages |
| Independent change | Marker hardening + ceremony become belt-and-suspenders for the same threat, redundant |

Rejected. Solves the right problem but pays the wrong cost.

### Option C — Bundle #132 + #48 in one PR (CHOSEN)

| Pros | Cons |
|------|------|
| Threads compose: structured marker provides mechanical defence, single-turn flow removes redundant ceremony | Single-Closes-per-PR rule means #48 closed manually post-merge (precedent AgDR-0010, AgDR-0011) |
| Coherent design: "explicit per-PR approval IS the merge moment" | Transition: bare-SHA legacy markers in flight need re-record (acceptable — markers are session state, not committed) |
| Tests cover the new format end-to-end | Requires both the skill and the hook to land together |

Chosen. Two threads, one PR, one AgDR.

### Option D — Cryptographic marker (HMAC-signed by a session secret)

| Pros | Cons |
|------|------|
| Genuinely model-unfabricable | Massive scope: requires a secret-management story, key rotation, cross-machine portability, etc. |
| Strong security guarantee | Wildly disproportionate for the threat (one team, one operator, audit-trail-not-encryption) |

Considered and rejected. The threat model is "agent makes a procedural mistake or shortcut", not "untrusted attacker forges merge approvals." The structured-key format is the right level — visible enough to make a forge a deliberate rule violation, not so heavy that it needs key infrastructure.

## Decision

**Bundle #132 + #48 in one PR.** Specifically:

- New marker format `<pr>-ceo.approved`:

  ```
  sha=<40-char hex>
  approved_by=user
  approved_at=<ISO-8601>
  skill_version=2
  approval_summary="<≤200 char user message snippet>"
  ```

  Required fields validated by the merge gate: `sha=`, `approved_by=user`, `skill_version=>=2`. The other fields are audit-only.

- New skill default flow: `/approve-merge <pr>` writes the structured marker AND runs `gh pr merge <pr> --repo <owner/repo> --squash --delete-branch` in the same turn. Opt-out via `/approve-merge <pr> --no-merge`.

- New hook validation: `block-unreviewed-merge.sh` parses the marker as key/value, rejects bare-SHA legacy markers with a "stale format" error pointing at `/approve-merge`, rejects markers without `approved_by=user`, rejects `skill_version=<2`.

- `pr-workflow.md` § "Plan-level 'go' is NOT merge approval" reframed: the load-bearing rule is "explicit per-PR approval", not "two user messages." The discrete moment is the `/approve-merge` invocation; the merge follows as a deterministic consequence.

## Consequences

### Now safer

- The bare-`echo SHA > file` bypass is mechanically rejected. The model has to type `approved_by=user` and `skill_version=2` on purpose to forge — a visible, grep-able rule violation rather than a one-line accident.
- The merge gate's error messages now point at `/approve-merge` consistently, including a clear "stale format" message for legacy markers. Easier to recover from.
- The PR-workflow rule is sharper: one moment of approval, one consequence. No ambiguity about whether "go" was about the plan or the merge.

### Now riskier

- **Skill-cooperation matters.** A skill that wrote bare-SHA markers (the old version, OR a fork that customised the skill) won't pass the new gate. Mitigation: clear error message, idempotent re-run.
- **Auto-merge surprises.** Adopters used to the old "stop and confirm" flow will get an immediate merge after `/approve-merge`. Mitigation: CHANGELOG entry; skill description and the rule doc both explicitly call out the change. The `--no-merge` opt-out preserves the old shape for adopters who want it.
- **Marker format can drift.** The `skill_version=` field exists so future format changes can bump the version. Hooks can then accept a range. Don't rely on the current format being permanent.

### Future work — out of scope here

- **Rex marker hardening.** This PR only hardens the CEO marker. Rex's marker stays bare-SHA because it's written by the automated review agent, not a human-authorization moment — different threat model. If Rex marker forgery becomes a concern, file a separate ticket.
- **`merge_strategy` config.** The skill currently hardcodes `--squash --delete-branch`. A future ticket could read this from `.claude/project-config.json` (e.g. `merge: { strategy: "squash"|"merge"|"rebase", delete_branch: true|false }`).
- **Cryptographic marker.** If the threat model ever shifts to "untrusted agent" / "untrusted operator", revisit Option D above. Not a near-term concern.
- **`--no-merge` test coverage.** The current test file covers the hook's marker-validation logic end-to-end. The skill itself doesn't have automated tests yet (skills are markdown-driven instructions to the model). A separate ticket could add a manual checklist.

### Migration

- In-flight bare-SHA markers from the old skill: the merge gate will refuse with a clear error pointing at `/approve-merge`. Re-run the skill; it writes the new format and merges. One re-run per stale marker.
- AgDR numbering: this AgDR is 0012. The voice-removal ticket (#157, filed 2026-05-03) will land separately and claim the next available number at that time (likely 0013 if it lands after this PR).

## Artifacts

- `me2resh/apexyard#132` — drop the "stop before merge" rule
- `me2resh/apexyard#48` — harden CEO merge marker against self-approval bypass
- `.claude/skills/approve-merge/SKILL.md` — single-turn flow + structured marker docs
- `.claude/hooks/block-unreviewed-merge.sh` — structured-marker validation
- `.claude/rules/pr-workflow.md` — reframed rule prose
- `.claude/hooks/tests/test_block_unreviewed_merge.sh` — 12 cases covering the hook end-to-end
- AgDR-0011 / PR #152 — precedent for bundling two coupled tickets in one AgDR
- AgDR-0010 / PR #147 — precedent for bundling + manual second-issue closure
