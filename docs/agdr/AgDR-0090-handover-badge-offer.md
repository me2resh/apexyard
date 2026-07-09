# AgDR-0090 — `/handover` offers a "Governed by ApexYard" README badge (opt-in, idempotent, PR-delivered)

> In the context of `/handover` already having one sanctioned exception to its read-only-against-the-target-repo rule (the in-repo `AGENTS.md` from AgDR-0073) but nothing that makes an onboarded repo visibly credit the framework governing it, facing the choice of whether and how to surface "this repo is governed by apexyard" on the adopted repo itself, I decided to add a second opt-in, default-OFF, PR-delivered step that offers a shields.io "Governed by ApexYard" (or "Built with ApexYard") badge near the top of the target repo's README, idempotent against re-runs, accepting that this is explicitly a growth-loop mechanism for the framework and must therefore be even more conservative about consent than `AGENTS.md` — every run asks by name, defaults to No, and never appears in a bulk `--all` / `all` selection.

## Context

Every repo `/handover` onboards into apexyard's governance gets a registry entry, a derived role list, and a set of workflows/hooks/CI templates — but none of that is visible on the repo itself. A README badge is a well-understood, low-friction convention (CI status, license, code coverage) for signalling "this project follows convention X" and, as a side effect, is a backlink to the framework's own repo. Competing frameworks with a "used by N forks" visibility loop get this kind of signal for free; apexyard currently has no equivalent, and nothing in `/handover`'s output today creates one.

The precedent here is AgDR-0073 (`AGENTS.md` generation): the only place `/handover` writes into the **target repo** rather than the ops fork, delivered opt-in, default-OFF, via a branch + PR. Adding a badge is structurally the same shape — a small, reviewable write into someone else's repo — but the intent is different in a way that matters for the consent bar: `AGENTS.md` is a favour to the repo (its own operating manual); a badge is at least partly a favour to apexyard (visibility, backlink). That asymmetry means the badge needs the operator's explicit, per-run, named consent — not a "checked by default in an --all run" shape.

## Options Considered

### Axis 1 — Consent model

| Option | Pros | Cons |
|--------|------|------|
| Default-on, included in `--all` | Maximises badge adoption | Silently edits a third-party repo's public-facing README without a conscious yes — a mild but real trust violation, and inconsistent with `AGENTS.md`'s own default-OFF stance despite `AGENTS.md` being purely a favour to the adopter |
| **Opt-in, default-OFF, excluded from `--all` and bulk `all`, confirmed by name every run** | Consistent with Rule 1 (read-only against target repo) and its one existing exception; no risk of an unattended run editing someone's README | Lower adoption than default-on; the operator has to remember it exists |

Chosen: opt-in, default-OFF, excluded from bulk selection. The framework already accepted the corresponding tradeoff for `AGENTS.md` (a favour-to-the-adopter write); a favour-to-apexyard write deserves at least the same bar, arguably higher — hence "confirmed by name every run" rather than relying on the row being ticked once in a longer checklist session.

### Axis 2 — Delivery mechanism

| Option | Pros | Cons |
|--------|------|------|
| Direct commit to the target's default branch | Simplest | Violates "every change through a PR"; surprises the repo owner |
| **Branch + PR into the target repo (same mechanism as `AGENTS.md`, step 8.5)** | Repo owner reviews before merge; reuses an already-reviewed pattern; can piggyback on the `AGENTS.md` PR in the same run to avoid two trivial PRs | One more step; needs its own branch when `AGENTS.md` wasn't also selected |

Chosen: branch + PR, with an explicit offer to combine onto the existing `docs/agents-md` branch when both were selected in the same run (avoids two near-empty PRs landing back to back).

### Axis 3 — Idempotency and variant handling

| Option | Pros | Cons |
|--------|------|------|
| Always insert, let duplicates accumulate | Simple | A second `/handover` run (or a second badge-add request) on the same repo would stack multiple badges — visibly sloppy and easy to trigger by accident |
| **Scan the README for either badge variant first; skip with a clear status if already present; never swap variants automatically** | Safe against re-runs; a human who wants to change `governed_by` → `built_with` does it by hand, which is the right amount of friction for a wording change | Requires a small detection step (grep for the shields.io URL pattern) before writing |

Chosen: idempotent detection, skip-if-present, no auto-swap between variants.

### Axis 4 — One badge or two variants

| Option | Pros | Cons |
|--------|------|------|
| Single "Governed by ApexYard" wording only | Simpler | Wrong tense for a repo that was built with apexyard from day one rather than onboarded into it after the fact — "governed by" implies adoption, not origin |
| **Two variants — `governed_by` (the `/handover` case) and `built_with` (native-apexyard projects)** | Wording matches the repo's actual relationship to the framework; both point at the same upstream link and share one detection pattern | One extra sub-prompt |

Chosen: two variants, same brand color (`#2F6DF6`) and `flat-square` style, `governed_by` as the default pick (matches the `/handover` context this step runs in).

## Decision

Chosen on all four axes: **opt-in, default-OFF (excluded from `--all` and bulk `all`), branch + PR delivery (with an offer to combine with an in-flight `AGENTS.md` PR), idempotent detection against both variants, and two fixed badge variants (`governed_by` / `built_with`)** using the canonical shields.io markdown:

```markdown
[![Governed by ApexYard](https://img.shields.io/badge/governed_by-ApexYard-2F6DF6?style=flat-square)](https://github.com/me2resh/apexyard)
[![Built with ApexYard](https://img.shields.io/badge/built_with-ApexYard-2F6DF6?style=flat-square)](https://github.com/me2resh/apexyard)
```

Implemented as row 9 of the step 5.6 document-selection checklist and a new step 8.6 in `/handover`, structurally parallel to row 8 / step 8.5 (`AGENTS.md`).

## Consequences

- `/handover` Rule 1's exception note now names two sanctioned target-repo writes (`AGENTS.md`, the badge) instead of one; a new Rule 23 documents the badge's opt-in/idempotent/PR-delivered contract, mirroring Rules 21–22 for `AGENTS.md`.
- The badge is deliberately **not** part of any bulk-generation path (`--all`, interactive `all`) — an operator must select row 9 explicitly (or comma-list it) and then confirm the named prompt. This is stricter than most other opt-in rows and is intentional given the asymmetric-favour rationale above.
- Two badge variants now exist in the framework's public surface; adopters who want a different wording or color edit their README directly after the PR merges — `/handover` does not offer customisation beyond the two variants.
- Re-running `/handover` on an already-badged repo is a safe no-op for this step (idempotent skip), consistent with the never-overwrite posture already established for architecture stubs (Rule 11) and `AGENTS.md`/`CLAUDE.md` (Rule 21).

## Artifacts

- Ticket: me2resh/apexyard#796
- PR: feat(#796): /handover offers a Governed-by-ApexYard badge to onboarded repos
- `.claude/skills/handover/SKILL.md` — step 5.6 catalogue row 9, step 8.6 (badge offer + idempotent insertion + PR delivery), Rule 1 exception update, Rule 23
- `docs/multi-project.md` — `/handover` row addition describing step 8.6
