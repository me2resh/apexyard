---
id: AgDR-0109
timestamp: 2026-07-25T10:00:00Z
agent: claude (orchestrator)
model: claude-opus-5
trigger: user-prompt
status: executed
---

# The marker-write gate is a backstop, not the control — block only on a resolved target, and activate the deferred meta-gate

> In the context of [AgDR-0104](AgDR-0104-trust-chain-controls-vs-backstops.md) deferring its anti-rot CI meta-gate "until a third *independent* incident proves the class recurs", facing exactly that third incident — two previously-unknown bypasses of `warn-review-marker-write.sh` found during review of the fix for the *previous* bypass — I decided to **label that hook a backstop per AgDR-0104, narrow its blocking behaviour to confidently-resolved marker targets while ambiguity warns instead of blocks, and activate the deferred CI meta-gate** — to achieve a gate that stops obstructing the flow it protects without re-opening the induced-impersonation hole that made it blocking, accepting that a determined actor can still reach the file locally because the real control is the per-PR human approval plus the merge-gate SHA check.

## Context

`warn-review-marker-write.sh` decides whether to block by pattern-matching the **text** of a Bash command to infer write intent. Its history is three rounds deep on one hook:

| Round | Change | Outcome |
|---|---|---|
| [#962](https://github.com/me2resh/apexyard/issues/962) → PR #970 | Narrowed from literal path matching toward resolved targets | Incomplete; false positives persisted |
| [#1000](https://github.com/me2resh/apexyard/issues/1000) → PR #1011 | Narrowed to actual write intent | **Introduced two new bypasses** |
| PR #1011 round 2 | Closed both | Pending re-review |

AgDR-0062 shipped this hook deliberately as **advisory — "exit 0 always"** — accepting that "the rex marker remains technically forgeable while every merge has a human-in-the-loop CEO nod." It was promoted to **blocking** in [#843](https://github.com/me2resh/apexyard/issues/843) after build-class sub-agents were observed writing their own approval markers (PRs #835, #842). That promotion addressed a real, exercised failure — it was not gratuitous.

AgDR-0104 then established the framing this decision applies:

> "a security gate implemented as regex/substring matching over bash command *text* **cannot be made sound** — the ways to express a path (`$VAR`, `$(…)`, concat, **here-doc**, symlink, `printf`) are unbounded."

and required every trust-chain hook be labelled *THE control* or *a backstop to a server-side gate*. That labelling was never applied to this hook.

### The third incident

AgDR-0104 deferred its CI meta-gate pending "a third *independent* incident" — its n=2 (#962, #965) being correlated, from one API-degraded session. During review of PR #1011, the code reviewer constructed and confirmed two new bypasses:

1. **Interpreter heredoc.** `python3 <<EOF` / `node <<EOF` / `bash <<EOF` with the write in the body — old hook blocked, new logic allowed. Heredoc bodies were stripped as *data*, but for an interpreter the body is *code naming the destination*; such writes also yield no extractable target, so the fallback ran with its only evidence removed.
2. **Mis-extracted target.** BSD-form `sed -i '' s/a/b/ <file>` returned the sed *expression* as the target; literal and non-matching, it was treated as conclusive and suppressed the fallback. Demonstrated rewriting a stale sign-off into a valid current-HEAD one, defeating the "new commits invalidate approval" property.

Different session, not degraded, different root causes. **`here-doc` appears verbatim in AgDR-0104's list of unbounded expressions** — the class recurred exactly where it was predicted. The trigger has fired.

### The cost being paid meanwhile

In one session the blocking behaviour produced roughly **fourteen false positives**: a read-only `grep` whose *pattern string* contained the trigger words; an `rm` cleanup; an `echo` whose prose mentioned them; the sanctioned reviewer's own sign-off write **with the session marker correctly set**; and a command that merely declared a variable named `MARKER_HOME` — the name the framework's own agent spec recommends. Reviewers worked around it by base64-encoding literals and splitting filenames across `printf` calls.

Two of those matter more than the count. A gate that **blocks its own review** pressures reviewers into obfuscation habits indistinguishable from evasion. And a gate that fires on the **framework's own documented variable name** is mis-tuned by its own standard.

Every one of those false positives shared a signature: the hook reported `detected role: unresolved, pr: unresolved`. It blocked while unable to identify any marker at all.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A — Status quo (block on ambiguity)** | No work; maximally cautious in one direction | ~14 false positives/session; blocks the sanctioned reviewer and the documented cleanup step; drives obfuscation; three rounds of whack-a-mole and counting |
| **B — Revert fully to advisory (AgDR-0062's original)** | Removes all false positives; restores the recorded design | Re-opens the induced-impersonation hole #843 shipped to close — a real, twice-exercised failure, not hypothetical |
| **C — Structure the Rex marker** (CEO-marker style fields) | Raises the forgery bar | **Rejected by AgDR-0062**: "a determined build agent can still type out the fields; gives false confidence" |
| **D — Require a posted forge review at HEAD** | Server-side, unforgeable locally | **Deferred by AgDR-0062/0104**: unsatisfiable in single-account setups, would block every merge |
| **E — Backstop labelling + resolved-target blocking + meta-gate (chosen)** | Keeps the block where it demonstrably works (a resolved marker target — the #843 shape); removes it where it only ever produced noise (unresolvable commands); applies AgDR-0104's required labelling; activates its deferred fixed point | Ambiguous-but-genuine forgery attempts now warn rather than block — accepted, because this is a backstop and the real control lies elsewhere |

## Decision

Chosen: **E.** Three parts, in order.

**1. Label `warn-review-marker-write.sh` a BACKSTOP, not THE control.** AgDR-0104 requires the label and its own reasoning forces the answer: a hook pattern-matching bash text "cannot be made sound," so it cannot be the thing integrity rests on. The control is, and remains, the per-PR human approval plus `block-unreviewed-merge.sh`'s SHA comparison against the forge-reported HEAD. Record the label in the hook header so the next contributor inherits the framing rather than re-deriving it.

**2. Block only on a confidently-resolved marker target; warn on ambiguity.** When the hook resolves a write target to a marker path, block — that is the #843 shape and it works. When it cannot resolve role and PR (`detected role: unresolved, pr: unresolved`), emit the advisory banner and exit 0.

This is not a weakening dressed as a fix. Failing open on ambiguity is *correct for a backstop* and wrong only for THE control — which, per part 1, this is not. It converts every false positive observed today into a warning while leaving the case that motivated blocking fully gated. A build agent writing a literal marker path is still blocked; a reviewer grepping for the word is not.

**3. Activate AgDR-0104's deferred CI meta-gate.** Its trigger has fired on its own stated terms. A trust-chain hook must ship with a paired **adversarial** test — one that attempts bypass shapes, not merely asserts the happy path. Seed it with the shapes now known: interpreter heredocs, BSD vs GNU `sed -i`, variable indirection (#962) — and the false-positive direction too, because a gate can fail by over-firing and today it mostly did.

The tests written in each of the three rounds all covered the shapes their author had thought of, which is definitionally the set not containing the next bypass. Only an adversarial pairing changes that.

## Consequences

- The ~14 false positives per session collapse to warnings; the sanctioned reviewer stops being blocked by the gate it is reviewing, and reviewers stop needing base64 workarounds that read as evasion.
- The #843 induced-impersonation case stays blocked. A build agent naming a marker path literally — the observed failure — is unaffected.
- **Accepted exposure:** a build agent that reaches a marker through indirection the extractor cannot resolve now gets a warning instead of a block. This is the exposure AgDR-0062 already accepted, re-affirmed deliberately rather than inherited: the per-PR human nod is the control, and the merge gate independently validates the SHA against forge-reported HEAD.
- Every future trust-chain hook costs one adversarial test. Intended; the alternative is a fourth round.
- AgDR-0104's deferred item is discharged. Its other deferral — compliance mapping, trigger-attached to an adopter request — is untouched.
- The honest-naming correction stands: absent a separate reviewer identity this is **structured self-review plus an audit trail**, not separation of duties. Narrowing a backstop does not change that claim, because the backstop was never what supported it.

## Artifacts

- Ticket: me2resh/apexyard#1015
- Live bypasses closed by PR #1011 (round 2) — this decision is about the gate's design, not those two fixes
- Supersedes the deferral in [AgDR-0104](AgDR-0104-trust-chain-controls-vs-backstops.md) § Consequences ("CI meta-gate, trigger: a 3rd independent bypass incident")
- Re-affirms [AgDR-0062](AgDR-0062-rex-marker-authenticity.md)'s accepted exposure and its rejection of the structured-marker and posted-review options
- Related: [AgDR-0075](AgDR-0075-code-reviewer-local-marker-is-gate-signal.md) (the local marker is the gate signal), #962, #965, #843, #1000
