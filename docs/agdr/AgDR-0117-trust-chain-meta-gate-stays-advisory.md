---
id: AgDR-0117
timestamp: 2026-08-01T10:00:00Z
agent: claude (Platform Engineer — Adel)
model: claude-sonnet-5
trigger: user-prompt
status: executed
---

# The CI meta-gate stays unbuilt; a lightweight advisory nudge ships instead

> In the context of me2resh/apexyard#1057 asking for a blocking CI check that fails when a
> trust-chain hook has no paired adversarial test — the one acceptance criterion from #1015
> that never shipped — I decided to **reject the blocking meta-gate a second time and ship a
> lightweight, non-blocking advisory nudge instead** to achieve a cheap reminder at PR-creation
> time without adding a new hard-to-satisfy gate to every future trust-chain edit, accepting
> that a contributor who ignores the nudge (or removes it) faces no mechanical consequence, and
> that AgDR-0104's meta-gate deferral stays formally deferred and undischarged.

## Context

- **The unshipped AC.** #1015 (closed after v5.3.0) had six acceptance criteria; five shipped.
  The sixth — "CI fails when a trust-chain hook has no paired adversarial test" — was split out
  into #1057 rather than dropped, because it is the AC that matters most for the future: every
  trust-chain bypass found so far (AgDR-0104's #962/#965, then #1026, then the extraction bug
  behind #1032) was found by a human reading the hook, not by a test failing.
- **AgDR-0104 already deferred this exact gate**, with an explicit trigger: "a third *independent*
  bypass incident proves the class recurs." **AgDR-0111 later narrowed that trigger further**, to
  "a new **control** (not a backstop) is added to the trust chain" — and explicitly declined to
  build the meta-gate at that time, on the grounds that a resolver capable of deciding "is this
  marker write confidently resolved" had just demonstrated it could not be trusted to decide
  correctly, and a permanent CI cost was the wrong price to pay to manage a defect class a
  different decision (making the marker-write hook plain-advisory) was simultaneously removing.
- **AgDR-0111's narrowed trigger has NOT fired.** No new CONTROL-class hook has been added to the
  trust chain since AgDR-0111. #1057 is not evidence the trigger fired; it is a re-ask of the same
  question AgDR-0104 and AgDR-0111 already answered, absent new evidence.
- **A Solution-Architect design pass + a Contrarian (Naqid) challenge on #1057's proposed gate
  surfaced three independent problems with building it now:**
  1. **Zero current coverage gap.** All four CONTROL-labelled merge-gate hooks
     (`block-unreviewed-merge.sh`, `block-merge-on-red-ci.sh`, `require-architecture-review.sh`,
     `require-design-review-for-ui.sh`) already ship adversarial tests — tests that try to defeat
     the control (variable indirection, missing `jq`, stale SHA, wrong role marker), not just
     confirm the happy path. The gate #1057 asks for would pass, silently, on the exact tree it
     was filed against. There is nothing to catch today.
  2. **The spec'd gate is defeatable by construction — the same "text-matching cannot be made
     sound" finding AgDR-0104 already recorded, one layer up.** #1057's own scope section asks for
     an "explicit, reviewable list" of trust-chain hooks (to avoid a path glob silently pulling in
     everything) — but a hand-maintained list is defeated by simple omission: add a new CONTROL
     hook, forget the list entry, the gate never evaluates it. And "a naming convention plus a
     required marker comment in the test file" (#1057's own suggested definition of "paired
     adversarial test") is defeated by a strawman: a test file with the right name and the right
     marker comment that asserts nothing more than a token string appears in the hook's source.
     Both holes are the identical shape AgDR-0104 named for `warn-review-marker-write.sh`: a
     control implemented as pattern-matching over text (a config list, a marker string) cannot be
     made sound against an adversary who knows the pattern.
  3. **It duplicates a stronger existing signal.** me2resh/apexyard#871 ships a scheduled,
     credentialed conformance job that drives a *real agent turn* through opencode, pi, and Codex
     and asserts the delegated trust-chain hook actually fires — proving the control works in a
     live harness, not just that a same-named test file exists beside it. A meta-gate that checks
     "is there a file claiming to be an adversarial test" is a strictly weaker proxy for "does this
     control actually hold" than a job that already checks the real thing.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Hard CI meta-gate** (#1057 as filed — blocking, fails when a CONTROL hook has no paired adversarial test) | Directly satisfies the unshipped #1015 AC; matches its own stated bar ("gets the same treatment it imposes") | Zero current gap to close (all 4 CONTROL hooks already covered); defeatable by list-omission and by a strawman marker-comment test; duplicates #871's stronger live-conformance signal; permanent tax on every future trust-chain PR — exactly the "ceremony contributors route around" risk #1015's own Risks section warned against |
| **Label-derived gate** (skip the hand-maintained list; require every `.claude/hooks/tests/test_*.sh` whose target hook has a CLASS header to also carry a matching marker comment, enforced in CI) | Removes the list-omission hole specifically | Still defeatable by the strawman-test hole; still a new permanent CI requirement; still duplicates #871; the label-derivation trick this option borrows is exactly what the shipped nudge below reuses, but as an *advisory* signal, not a blocking one |
| **Advisory nudge — CHOSEN** (non-blocking hook on `gh pr create`, derives the CONTROL set from each hook's own `# CLASS: CONTROL` header at grep time, prints a one-line reminder when a touched hook is in that set) | No new hard gate; costs nothing when it doesn't fire; the CONTROL set can't be defeated by omission because it isn't a separate list — a hook can only escape detection by removing its own header, which is a loud, reviewable, self-incriminating edit; matches the "self-discipline primary, cheap mechanical reminder secondary" lineage of AgDR-0104/AgDR-0111 | Provides no mechanical consequence if ignored; doesn't prove a test is genuinely adversarial (no gate does, without executing an adversarial harness — see #871) |
| **Stay deferred, ship nothing** | Cheapest; honest about the trigger not having fired | #1057 asked for *something*; a pure no-op leaves the acceptance-criteria question unanswered a second time and gives future readers no artifact explaining why |

## Decision

Chosen: **the advisory nudge**, with the blocking meta-gate rejected a second time on its merits
(not merely "deferred by default").

1. **The blocking CI meta-gate is not built.** AgDR-0104's deferral is **not discharged** by this
   decision — it remains deferred under AgDR-0111's narrowed trigger ("a new CONTROL is added to
   the trust chain"), which has not fired. #1057 is closed by this AgDR as answered-on-the-merits,
   not left open awaiting the gate.
2. **A new advisory hook ships**: `.claude/hooks/nudge-control-adversarial-test.sh`, wired to
   `PreToolUse` on `Bash(gh pr create *)` in `.claude/settings.json`. On every `gh pr create`, it
   computes the PR's changed-file diff vs. its base branch; if any changed file is a
   `.claude/hooks/*.sh` file whose own header carries `# CLASS: CONTROL`, it prints one line to
   stderr naming the touched hook(s) and pointing at AgDR-0104/AgDR-0117, then **always exits 0**.
   It never blocks, never writes a marker, and is silent in every other case (wrong command,
   unresolvable base, no CONTROL hook touched, empty diff).
3. **The CONTROL set is derived from the hooks' own headers, not a config list** — directly
   closing the Contrarian's list-omission finding. The hook greps every `.claude/hooks/*.sh` file
   for `^# CLASS: CONTROL` at invocation time; there is no second place to keep in sync, and no
   silent-omission failure mode. A hook can only stop being flagged by removing its own header,
   which is visible in the diff the nudge is reacting to.
4. **A paired test ships with the hook** (`.claude/hooks/tests/test_nudge_control_adversarial_test.sh`),
   asserting the nudge fires on a CONTROL-hook diff, stays silent on a non-CONTROL diff, and —
   the load-bearing property — **never exits non-zero**, including in the case where it fires.

## Consequences

- Contributors touching `block-unreviewed-merge.sh`, `block-merge-on-red-ci.sh`,
  `require-architecture-review.sh`, or `require-design-review-for-ui.sh` (today's CONTROL set) get
  a one-line reminder at PR-creation time to add or update an adversarial test. Nothing stops the
  PR if they don't.
- Adding a fifth CONTROL hook in the future requires no config update to be picked up by the
  nudge — only the new hook's own `# CLASS: CONTROL` header, which its author is already writing
  per AgDR-0104's labelling convention.
- **AgDR-0104's meta-gate deferral remains open**, narrowed by AgDR-0111 to "a new control is
  added to the trust chain." This AgDR does not change that trigger. If it fires, the meta-gate
  question should be re-litigated fresh against whatever the new control actually is — not
  resolved by analogy to this decision.
- **Accepted exposure:** a contributor can ignore the nudge, or edit the hook to remove its own
  `# CLASS: CONTROL` header to silence it, with no mechanical consequence either way. Both are
  visible, reviewable diffs — the same "visible rule violation, not an invisible one" trade-off
  AgDR-0104 and the framework's other advisory hooks already accept.
- me2resh/apexyard#1057 is closed as answered by this AgDR: the requested gate is rejected on the
  merits described above, and the lighter artifact that ships instead is this hook + its test.

## Artifacts

- Ticket: me2resh/apexyard#1057 (this AgDR's driver), me2resh/apexyard#1015 (the parent, closed at
  v5.3.0), me2resh/apexyard#871 (the conformance framework this would have duplicated)
- Hook: `.claude/hooks/nudge-control-adversarial-test.sh`
- Test: `.claude/hooks/tests/test_nudge_control_adversarial_test.sh`
- Settings wiring: `.claude/settings.json` — `PreToolUse` → `Bash(gh pr create *)`
- **Re-affirms, does not discharge**: [AgDR-0104](AgDR-0104-trust-chain-controls-vs-backstops.md)'s
  deferred CI meta-gate, under [AgDR-0111](AgDR-0111-marker-gate-plain-advisory.md)'s narrowed
  trigger ("a new control is added to the trust chain") — unfired as of this decision.
- Informed by: a Solution Architect design pass and a Contrarian (Naqid) challenge on #1057's
  originally-proposed gate design.
