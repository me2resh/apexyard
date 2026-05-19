# AgDR-0040 — /codify-rule skill design

> In the context of Stage 2 of #293 (Rex domain-aware handbooks), facing the failure mode that Stage 1 shipped a place for adopters to encode domain knowledge (`handbooks/domain/<area>/`) but no cheap path from "Rex missed something a human caught" to "next review benefits from the miss", I decided to ship `/codify-rule` as a four-step operator-curated capture skill — resolve source PR, prompt for comment text + file:line, route to bucket (domain / architecture / general / language), Y/N gate the full draft — to achieve a handbook layer that compounds on Rex's actual misses rather than only the rules an operator thought to write proactively, accepting that the curation gate (no file written without explicit Y) puts a small per-capture friction on the operator that auto-promotion would have removed.

## Context

### The steering loop the framework was missing

Stage 1 of #293 (PR #294, AgDR-0037) shipped the `handbooks/domain/<area>/` bucket with opt-in `paths:` frontmatter. Rex now has a *place* to look for domain-specific review knowledge — but the load-bearing question Stage 1 left open was: **how do adopters actually populate that place?**

Three paths are theoretically available:

1. **Up-front authoring.** Adopter writes the handbook before they've ever seen Rex miss anything in this domain. Works for canonical facts ("Stripe webhook signature uses HMAC-SHA256") but doesn't scale to the long tail of "the gotcha you only discover by shipping the bug".
2. **Operator-curated capture.** When a human (or Copilot, or any second-pass reviewer) catches a bug Rex missed, the operator codifies that miss as a handbook entry. The capture is cheap because the rule is already in the review comment — the skill just structures it and writes it.
3. **Automated mining.** Walk recent merged PRs, propose handbook additions Rex would have benefited from. Higher leverage but higher false-positive rate; needs a curation gate too.

Stage 2 (this skill) ships path 2. Stage 3 (`/enrich-domain`) will ship path 3 as a separate ticket.

### Industry harness-engineering precedent

Industry harness-engineering articulates the **steering loop**: "whenever an issue happens multiple times, the feedforward and feedback controls should be improved". Rex is the feedforward (rules applied during review); handbooks are the layer of rules; `/codify-rule` is the operator-side hook into the feedback edge of the loop. Without this skill, the loop is open — Rex reviews, misses fire, humans catch them, and the next PR re-makes the same miss. With this skill, the operator closes the loop in 5 minutes per capture, and the handbook layer becomes a learning surface.

### What we're NOT trying to solve here

- **Auto-mining historical PRs** for proposed rules. That's Stage 3; deferred until Stage 2 is proven.
- **Cross-project rule propagation.** A handbook captured in project A doesn't auto-apply to project B. Multi-project handbooks were already deferred in Stage 1's "out of scope" list; this skill respects that boundary.
- **Multi-handbook bulk capture** from one review session (3 misses → 3 captures in one invocation). v1 is one capture per invocation; if bulk shows demand, file a follow-up.
- **A hook that auto-runs `/codify-rule` on every PR close.** Auto-running defeats the curation gate that makes this skill load-bearing. Operator-invoked only.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| **A. Operator-curated interactive capture with Y/N gate before any file write** (chosen) | Low false-positive rate (operator confirms every entry); source attribution is built into the flow; conversational shape matches sibling ticket-creating skills (`/feature`, `/task`, `/bug`); aligns with the framework's "every destructive op is operator-gated" convention | Operator must invoke the skill per miss — won't capture what the operator never notices; per-capture friction is real (1-2 minutes of prompts) |
| **B. Auto-promote: hook on PR close inspects review comments, writes handbook entries directly** | Zero per-capture friction; catches misses the operator might forget | Handbook clutter compounds fast; false-positive comments ("nit: rename foo") become handbook noise; defeats the curation gate; impossible to attribute correctly when multiple reviewers comment on the same line |
| **C. Hybrid: hook proposes drafts to a queue; operator runs `/codify-rule --review-queue` later** | Bridges the friction gap of A and the noise of B; operator still gates | Adds a queue file as a new framework primitive; needs queue eviction policy; doubles the surface area; v1 should stay simple |
| **D. Manual `cp` + edit (no skill, just docs)** | Zero framework code; aligns with the `handbooks/README.md` § "Adding a new handbook" pattern that's already documented | The framework already shipped 50 skills — adopters expect skilled flows for repeated operations; manual `cp` doesn't pre-populate the `_Source:_` footer, the `paths:` frontmatter, or route to the right bucket |

## Decision

Chosen: **Option A — operator-curated interactive capture with mandatory Y/N gate**, because:

1. **Curation is the load-bearing property.** A handbook layer that compounds with noise tunes adopters out within weeks. A handbook layer that compounds with operator-approved entries earns its keep on the next review. The gate is the difference.
2. **Source attribution comes for free.** The flow already needs the PR number to find the comment; reusing it as a `_Source:_` footer is a one-line addition that buys huge traceability ("where did this rule come from?" → click the link).
3. **Shape matches existing skills.** `/feature`, `/task`, `/bug`, `/spike-close`, `/migration` — every ticket / artefact-creating skill in the framework follows the same shape: gather inputs, show the preview, gate on Y/edit/no. Operators don't have to learn a new convention.
4. **Stage 3 is the right place for automation.** `/enrich-domain` (mining PRs) is the high-leverage automation play. Doing automation here would conflate "capture one specific miss" with "find candidates" — different problems with different failure modes.

## Consequences

### Positive

- The handbook layer becomes a **learning surface** that compounds on Rex's misses, not just the rules an operator thought to write proactively.
- Source attribution is built in. Future readers asking "why does this rule exist?" find the original PR + comment in two clicks.
- Routing to the right bucket is handled by the skill — adopters don't need to internalise the architecture/general/language/domain distinction; the skill walks them through it.
- Public vs private (split-portfolio) write target is offered automatically when the adopter has a private layer configured.
- Re-runs on the same area / slug are handled (append vs overwrite vs cancel), so iterative capture in a high-traffic domain doesn't accidentally clobber prior entries.

### Negative

- **Per-capture friction.** The skill takes ~1-2 minutes of prompts. For misses the operator considers borderline, that friction may prevent capture. Mitigated by Stage 3 (`/enrich-domain`) catching the long tail in a separate flow.
- **Operator must remember to invoke.** No hook auto-runs the skill; if the operator forgets, the miss is lost. Acceptable v1 trade-off; auto-running was rejected as Option B for the noise reason. If forgetting shows up as a real pattern, file a follow-up for the hybrid Option C.
- **Frontmatter convention is bucket-specific.** Only the domain bucket uses `paths:` frontmatter; the other three buckets stay frontmatter-free per `handbooks/README.md`. The skill handles this routing internally, but new authors copying handbook entries by hand need to understand the bucket distinction. Documented in step 7 of the SKILL.md and the bucket-picker prompt.

### The five required sections + source footer — file shape

The shape mirrors the standard from `handbooks/README.md` § "File format":

```markdown
{frontmatter — domain bucket only}

{ENFORCEMENT_LINE — only when --blocking}

# Handbook: <Title>

**Scope:** <derived>
**Enforcement:** <advisory|blocking>

## The rule
## Why
## What Rex flags
## Sample finding
## What's NOT a violation

---

_Source: PR #N comment by @author on YYYY-MM-DD_
_See: <comment-url>_
```

The `_Source:_` footer is the only addition over the existing handbook shape — it's a two-line italic block separated from the body by `---` so it stays visually distinct from the rule content while remaining grep-able for audit (`grep -r "_Source: PR" handbooks/`).

### Why operator-approval is mechanically a markdown preview, not a config flag

The gate could in theory be `--auto-write` opt-out. It deliberately isn't:

- Auto-write inverts the framework's "every artefact write is operator-gated" convention. Sibling skills (`/feature`, `/migration`, `/spike-close`) all confirm before writing. Inverting here would be surprising.
- The preview is the rule — once the operator sees the full text, they catch typos / scope creep / overlap with existing rules in a way the in-flight prompts can't surface.
- The cost of "yes" after reading is one keystroke. The cost of fixing a bad auto-written handbook is a separate PR and a re-review cycle.

### Future work (tracked under #293's Stage 3)

- **`/enrich-domain <area>`** (Stage 3) — walk recent merged PRs that touched the area; propose handbook additions Rex would have benefited from. Operator-approved per finding via the same Y/N gate this skill establishes.
- **Cross-project propagation.** If multi-project adopters ask, surface a way to share a handbook entry across projects in the registry. Deferred per Stage 1's out-of-scope.

## Artifacts

- `.claude/skills/codify-rule/SKILL.md` — the skill spec
- `.claude/skills/codify-rule/tests/smoke.sh` — shape-contract smoke test
- `CLAUDE.md` — skill table updated to 51 entries
- `docs/multi-project.md` — skill-behaviour table updated
- Ticket me2resh/apexyard#296 — feature spec for Stage 2
- Parent feature ticket me2resh/apexyard#293 — three-stage Rex domain-handbooks plan
- AgDR-0037 — Stage 1 (path-glob discovery foundation)
- PR me2resh/apexyard#294 — Stage 1 implementation
