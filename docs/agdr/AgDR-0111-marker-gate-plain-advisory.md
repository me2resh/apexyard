---
id: AgDR-0111
timestamp: 2026-07-28T08:00:00Z
agent: claude (orchestrator)
model: claude-opus-5
trigger: user-prompt
status: executed
---

# Ship the option AgDR-0109 rejected: the marker-write gate becomes plainly advisory, and the CI meta-gate is not built

> In the context of [AgDR-0109](AgDR-0109-marker-write-gate-is-a-backstop.md) sitting at `status: executed` for three days with none of it implemented, facing 13 false positives across 2 hooks in a single session, I decided to **ship its rejected option B — plain advisory, exit 0 always — instead of its chosen option E, and to not build the CI meta-gate it activated** — to achieve a trust chain whose backstop stops taxing honest work, accepting that a build agent reaching a marker through any spelling now gets a warning rather than a block, because the control was never the backstop.

## Context

AgDR-0109 decided three things: label this hook a backstop; **block only on a confidently-resolved
marker target while ambiguity warns** (option E); and activate AgDR-0104's deferred CI meta-gate.
It reached `status: executed`. **None of the three was built.** No hook carried the label, the gate
still blocked on ambiguity, and no meta-gate existed.

That unimplemented state is what produced the evidence below, which was not available when
AgDR-0109 was written.

### New evidence: the resolver cannot report "confidently resolved"

Option E's whole design rests on distinguishing *resolved* (block) from *ambiguous* (warn). That
distinction is only as good as the extractor computing it. In one session it:

- Blocked a **read-only `grep`** whose search *pattern* contained a marker path.
- Blocked a **`git commit`** whose *message* described the bug being fixed.
- Blocked a **code reviewer writing its own review prose** to a scratch file.
- Blocked **`/approve-merge`'s own documented step 7** (`tracker_pr_merge … > "$VAR"`), because a
  variable named `MARKER_HOME` — the name this framework's skills tell you to use — tripped the
  indirection heuristic.
- Blocked a **JSON payload being piped to another program**, and reported the extracted role as the
  literal string `me2resh__apexyard__7777-rex.approved"}}` — it swallowed the JSON braces into the
  role field and blocked on the result.
- Reported role `rex` for a **`ceo`** write, because the documented flow reads the rex marker to
  verify it before writing the ceo one, and extraction was first-call-wins (#1032).

A resolver that returns `…approved"}}` as a role, and that misidentifies which of two markers in one
command is being written, is not a component whose confidence should decide whether to block.

### The safety argument that makes B viable now

AgDR-0109 rejected B as "re-opens the induced-impersonation hole #843 shipped to close." Two facts
retire that objection:

1. **#843's root cause is already repaired.** Build agents forged markers to comply with
   `auto-code-review.sh`'s "Invoke Rex NOW" instruction, which they cannot follow. That banner now
   has an explicit build-class branch telling sub-agents to stop and hand back. The inducement is
   gone; the block was belt-and-braces on a fixed cause.
2. **The deterrent survives the change.** The banner's build-agent paragraph is retained verbatim;
   only the exit code moves. What a build agent reads is unchanged.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **E — block on resolved target, warn on ambiguity** (AgDR-0109's choice) | Keeps a block on the #843 shape | Rests on a resolver demonstrably capable of returning garbage; retains a text matcher in a blocking path, so the defect class survives at higher complexity; more code than B |
| **B — plain advisory, exit 0 always (chosen)** | Removes every false positive; restores AgDR-0062's recorded design; one line plus banner wording; keeps the deterrent | A forgery attempt of any spelling now warns rather than blocks |
| **F — relocate to PostToolUse / marker-read time** | Sees the real file, so spelling stops mattering | More machinery; and the merge gate already reads the file and compares its SHA to forge HEAD — this would duplicate the control that already exists |
| **G — do nothing (leave AgDR-0109 unimplemented)** | No work | The status quo that produced 13 false positives in one session, while still not detecting the split-path shape |

## Decision

Chosen: **B**, with the CI meta-gate deliberately not built.

**1. Plain advisory.** `warn-review-marker-write.sh` exits 0 on every path. It is a backstop; the
control is the per-PR human approval plus `block-unreviewed-merge.sh` comparing each marker's SHA
against forge-reported HEAD — structured state a local file write cannot fake.

**2. No CI meta-gate.** AgDR-0109 activated AgDR-0104's deferred meta-gate (fail CI when a
trust-chain hook lacks a paired adversarial test). It is not built here. It imposes a permanent cost
on every future trust-chain hook in order to *manage* a defect class this decision *removes* — and
the risk section of #1015 itself warns it "should not be so heavy that contributors route around it."
**AgDR-0104's deferral is therefore NOT discharged**; it remains deferred, with the trigger narrowed
to: *a new **control** (not a backstop) is added to the trust chain*. #1015 stays open at that scope.

**3. One limit stays open on purpose.** The split-path shape (#1026) is not detected and will not be
patched. A fifth pattern would be one spelling behind the sixth. Variable indirection, interpreter
heredocs and BSD/GNU `sed -i` **are** detected and do warn — earlier rounds closed them; the header
and tests say so, and they must not be cited as evidence the hook is blind.

## Consequences

- All 13 observed false positives become warnings. The reviewer of a trust-chain change stops being
  blocked by the gate it is reviewing.
- The #843 deterrent text is unchanged; what a build agent reads is identical.
- **Accepted exposure:** a build agent that ignores the banner can write a marker by any spelling.
  This is AgDR-0062's exposure, re-affirmed a second time. The human merge nod and the forge-HEAD
  SHA comparison remain the control, and both were verified unmoved.
- `auto-code-review.sh`'s banner was corrected in the same change: it claimed the write "will BLOCK
  anyway," which this decision makes false. A framework that misstates its own enforcement teaches
  agents to discount the rest of the banner.
- AgDR-0104's meta-gate stays deferred under a narrowed trigger, rather than being discharged.

## Artifacts

- Ticket: me2resh/apexyard#1026 (direction), #1032 (extraction bug), #1015 (meta-gate, re-scoped)
- **Supersedes** [AgDR-0109](AgDR-0109-marker-write-gate-is-a-backstop.md) § Decision parts 2 and 3.
  Part 1 (the backstop label) stands and is implemented here.
- **Reverses** AgDR-0109's rejection of option B, on evidence unavailable when it was written.
- **Restores** [AgDR-0062](AgDR-0062-rex-marker-authenticity.md)'s original advisory design and
  re-affirms its accepted exposure for the second time.
- **Un-discharges** [AgDR-0104](AgDR-0104-trust-chain-controls-vs-backstops.md)'s CI meta-gate
  deferral, narrowing its trigger to "a new control is added."
- Related: #843 (the promotion this reverses), #962, #1000, #1011, AgDR-0075
