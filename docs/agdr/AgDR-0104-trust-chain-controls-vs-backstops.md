---
id: AgDR-0104
timestamp: 2026-07-22T05:30:00Z
agent: claude (Tech Lead — Hisham)
model: claude-opus-4-8[1m]
trigger: user-prompt
status: executed
---

# Trust-chain governance: controls vs. backstops, honestly named

> In the context of apexyard enforcing security-critical principles (author ≠ reviewer, no-unreviewed-merge) via shell hooks that pattern-match bash command text, facing two live bypasses discovered in one session — [#962](https://github.com/me2resh/apexyard/issues/962) (the marker-write gate is evaded by passing the marker path through a shell variable instead of a literal) and [#965](https://github.com/me2resh/apexyard/issues/965) (the merge gate exits 0 / fails **open** when `jq` is unavailable) — we decided to **narrow what the shell hooks are *trusted* to enforce and lean the real control onto the forge's server-side gate**, fix both holes fail-closed, and **name each principle honestly** against external standards (only claiming separation-of-duties where a separate reviewer identity actually exists) — rather than the initially-drafted "add a bypass-test to every control" program — to achieve durable, non-over-claimed integrity, accepting that we defer a CI meta-gate and the full compliance mapping until they're earned.

## Context

- apexyard's stated philosophy is **"self-discipline primary; shell hooks are the mechanical backstop."** The trust chain (`.claude/hooks/**`) gates merges and review-marker writes.
- Two bypasses surfaced in one (API-degraded) session: #962 (string-match evadable via variable indirection — the exact #843 self-review-bypass class, and it was **exercised**, not hypothetical) and #965 (`jq`-absent fail-open in `block-unreviewed-merge.sh`).
- These are two samples of one structural fact: **a security gate implemented as regex/substring matching over bash command *text* cannot be made sound** — the ways to express a path (`$VAR`, `$(…)`, concat, here-doc, symlink, `printf`) are unbounded.
- A decidable choke point already exists: `block-unreviewed-merge.sh` compares the review-marker SHA against the PR/MR **HEAD reported by the forge**, resolved forge-aware via `_lib-tracker.sh` (`gh` / `glab`). The forge's server-side controls (branch protection / MR approval rules) run where local string tricks can't reach.
- **Identity reality (AgDR-0062):** in the default single-maintainer / single-account setup, the "author" and "reviewer" are the *same* human and the *same* `gh`/`glab` account — so author-independence "can never be satisfied." Tonight the same agent under the same account both reviewed code and wrote its own approval marker: that is the *definition* of a separation-of-duties failure, not an implementation of one.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A — Bypass-test every control, tracked in a `rule-audit.md` column** (original draft) | Directly targets the found holes; no new artifact | Tests the wrong layer (a single test patches one evasion; the substrate stays unsound); the anti-rot rule itself rots in a markdown column; risks stamping "SoD/SLSA" on single-account self-review |
| **B — New "Principle Record" artifact type** | First-class, greppable invariants | New doc machinery duplicating rules + `rule-audit.md`; against apexyard's minimalism |
| **C — Compliance-mapping-first (ISO/SOC2/SLSA)** | Immediate regulated-adopter story | Not credible while controls are bypassable — badges on a colander |
| **D — Just fix #962/#965 as isolated bugs** | Cheapest now | Guarantees a rediscovery of the class per-incident; no honest naming |
| **A′ — Narrow trust + honest naming (chosen)** | Fixes the substrate framing not just the symptom; corrects a real audit-liability; forge-aware; defers the unearned parts | The "narrow trust" reframing is a labeling/discipline act, not itself mechanically enforced |

## Decision

Chosen: **A′ — narrow what the shell hooks are *trusted* to enforce, fix the two holes fail-closed, and name principles honestly** — a hybrid that keeps the enforce-first instinct of (A) and the cheapness of (D) while dropping (A)'s premature bypass-test *program* and (A)'s over-claim risk. This reflects The Contrarian's (Naqid) `proceed-with-changes` verdict: the substrate (string-matching bash text) can't be made sound, so the fix is to *shrink what it's trusted for* and lean on the server-side choke point, not to test it harder.

Concretely, in order:

1. **Fix #962 and #965 fail-closed** (a gate that can't evaluate its precondition must *block*, not allow), and **relocate real trust to the forge's server-side gate**. Per trust-chain hook, decide and **label** it: *THE control* (must sit where it sees structured state — e.g. the forge-reported HEAD SHA) or *a backstop* to a server-side gate (then say so, and stop calling it enforcement). Ship the two specific regression tests.
2. **Name the principles honestly, immediately** (nearly free): "author ≠ reviewer" = **separation of duties (SoD)** — but **only when a separate reviewer identity is configured**. In the default single-account mode, label it precisely as **"structured self-review + audit trail"** (a real but strictly weaker property), *not* SoD. The SoD/SLSA/ISO-27001-A.5.3/SOC-2 mapping's precondition is *"a separate reviewer identity exists,"* never *"the control is bypass-tested"* — bypass-testing doesn't turn one identity into two.
3. **Anti-rot as a CI meta-gate** (a build failure if any trust-chain hook lacks a paired adversarial test) is the right fixed point — but **deferred** until a third *independent* incident proves the class recurs (tonight's n=2 are correlated, same degraded session). For now: one durable guidance line in `rule-audit.md`.
4. **Compliance mapping** (apexyard → ISO/SOC2/SLSA + GitHub/GitLab control config) is **trigger-attached** (next adopter compliance ask), not a vague "later."

## Consequences

- **Forge-aware server-side gate.** The "control vs backstop" labeling and adopter config docs are per-forge: **GitHub** = branch protection (required reviews/checks); **GitLab** = protected branches + **MR approval rules** (`prevent-author-approval`, required approvals from a group — a *stronger*, purpose-built SoD control than GitHub's). The SHA-match choke point stays forge-agnostic via the existing `_lib-tracker.sh` `gh`/`glab` dispatch. Honest naming (consequence 2) is forge-independent.
- **#962, #965, #964** are the concrete near-term fixes under this direction — each must ship fail-closed + a regression test.
- A new **task** captures the labeling + honest-naming + forge-aware-server-side-gate docs work (filed alongside this AgDR so it isn't lost).
- `docs/rule-audit.md` gains a one-line "trust-chain hooks are backstops to a server-side gate; fail-closed + adversarial regression test expected" guidance note (not yet a CI gate).
- **Deferred, with explicit triggers:** the CI meta-gate (trigger: a 3rd independent bypass incident) and the compliance mapping (trigger: an adopter compliance request). Recorded here so they surface when their triggers fire.
- **Risk accepted:** the "narrow trust / honest naming" is a labeling discipline, not mechanically enforced — but it's a one-time correction (rename + scope), not an ongoing self-discipline burden, so the rot exposure is low.

## Artifacts

- Challenged by Naqid (The Contrarian) — verdict **proceed-with-changes**; three HIGH findings absorbed: (1) test the wrong layer → narrow trust to the server-side gate; (2) anti-rot column would itself rot → CI meta-gate (deferred); (3) SoD over-claim in single-account mode → scope the claim to a separate-identity config. The GitLab forge-awareness refinement was added on top during ratification.
- Related: #962, #964, #965 (the concrete holes/drift), AgDR-0062 (author-independence deferred in single-account setups), AgDR-0038 (jq as hard dependency).

## Update (me2resh/apexyard#1086, AgDR-0114) — first executed protected-branch application

This record's "narrow what's trusted, label each hook THE control or a backstop, then say so" framing sat as labeling guidance until #1086 gave it a concrete, executed case: protected-branch enforcement (`.claude/hooks/block-main-push.sh` vs the git-native `.githooks/pre-push` / `.githooks/pre-commit` pair).

[AgDR-0114](AgDR-0114-block-main-push-honest-naming-blocking-backstop.md) resolves that case in three PRs:

1. **#1090 (step 2, merged)** — `.githooks/pre-push` ships as the git-native, ground-truth control for terminal `git push`, reading git's own resolved stdin refs instead of parsing command text.
2. **#1117 (step 3, PR-1, merged)** — `.githooks/pre-commit` ships as the git-native control for terminal `git commit` (`git symbolic-ref --short HEAD`, no parsing at all), and the shared `_lib-protected-branches.sh` gains a fail-closed `is_protected_branch()` predicate both git-native hooks call.
3. **#1086 step 3, PR-2 (this update)** — `block-main-push.sh` migrates onto the same shared predicate (removing the inline duplicate this AgDR's "narrow trust" framing would otherwise leave standing as a second, drift-prone copy), gains a `--no-verify`-aware blocking check (the one shape with no git-native replacement — see AgDR-0114's Context), and is relabelled in its own header comment as a **blocking backstop**, honestly, per this record's original vocabulary.

This is the first case where this AgDR's "control vs backstop" distinction was applied to a NEW hook family rather than to the two originating bypasses (#962, #965). It is also the case AgDR-0114 uses to **narrow** this record's own "backstop → advisory" leap: that step is only safe when a strictly *stronger* control already covers everything the backstop covered (true for `block-unreviewed-merge.sh` leaning on the forge's branch protection, the case this record was written for). It is not true here — `--no-verify` and unconfigured `core.hooksPath` on managed-project clones are real gaps the git-native hooks cannot close — so `block-main-push.sh` stays blocking rather than following the merge-gate precedent all the way to advisory. See AgDR-0114's Context section for the full reasoning.
