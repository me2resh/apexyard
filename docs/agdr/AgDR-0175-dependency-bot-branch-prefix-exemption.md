# Exempt dependency-bot branch prefixes from the branch-name gate, on both sides

> In the context of the branch-name gate blocking Dependabot and Renovate pushes, facing branch names no bot will ever give a ticket ID, I decided to **exempt the `dependabot/` and `renovate/` prefixes in the hook and in the CI title check together** to achieve the alignment the CI file already claims, accepting that an agent can name human work with a bot prefix and skip the branch-name check at push time.

**Status**: Accepted
**Date**: 2026-09-28
**Ticket**: me2resh/apexyard#1362
**Related**: me2resh/apexyard#1364 (this PR) · [AgDR-0129](AgDR-0129-handover-branch-exemption-and-shadowed-skill-recovery.md) (the exact-literal exemption in this same hook, and the cost it names) · me2resh/apexyard#588 (the CI exemption this aligns with)

## Context

`validate-branch-name.sh` requires `{type}/{TICKET-ID}-{description}`. Dependency bots name their own branches — `dependabot/npm_and_yarn/undici-6.21.1`, `renovate/node-22.x` — and no ticket exists for a bump the bot opened. The gate blocked those pushes.

`.github/workflows/pr-title-check.yml` already exempted `dependabot/`, `sync/` and `release/`, and states that its pattern is "intentionally aligned with the local hooks … so anything that passes the hooks also passes this CI check". The hook exempted `sync/` and `release/` but neither bot prefix, so the claim was already false in one direction.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Exact-literal allowlist, as AgDR-0129 used | Narrowest possible surface | A bot's branch name is not fixed. `dependabot/npm_and_yarn/<pkg>-<version>` is generated per bump, so no literal list can be complete |
| Prefix exemption in the hook only | One-file change | Leaves the CI check disagreeing for `renovate/`. A Renovate PR then passes the local gate and fails CI on a title it was never going to carry |
| Prefix exemption on both sides | The two lists agree, so the CI file's stated promise holds | Widens a gate-relaxing surface: the segment after the prefix is the bot's to choose, so the exemption cannot be pinned to a known value |
| Require an ecosystem segment for Dependabot (`^dependabot/[a-z0-9_-]+/`) | Narrower still for that one bot | Renovate lets a user change `branchPrefix`, so the same tightening cannot apply to it. Asymmetry for little gain |

## Decision

Chosen: **prefix exemption on both sides**, `^(dependabot|renovate)/[^/]` in the hook and `^(dependabot\/|renovate\/|sync\/|release\/)` in the CI check.

A prefix rather than a literal, because the bot generates the rest of the name. A trailing `[^/]` so a bare `dependabot/` is not exempt — git rejects a ref ending in `/`, so accepting it would widen the surface for nothing.

Both sides change in this PR. Changing only the hook would leave the disagreement the ticket exists to remove, merely pointing the other way.

## Consequences

- A Dependabot or Renovate push is no longer blocked on its branch name, and its PR is no longer failed on its title.
- The two lists must now be edited together. Each side carries a comment naming the other, because nothing mechanical binds them — a future prefix added to one and not the other reintroduces exactly this defect.
- **Residual risk, stated plainly.** An agent can name human work `dependabot/<anything>` and skip the branch-name check at push time. The exemption is about the branch NAME only, and the backstops are unchanged: `validate-pr-create.sh` does not exempt bot prefixes and still requires a ticket ID in the branch, and the ticket-first, secrets, commit-format and merge gates all still apply to whatever is pushed. This is the same cost AgDR-0129 recorded as "slightly widens a gate-relaxing surface", and it is wider here because the suffix is open rather than literal.
- Near-miss shapes are pinned by tests — `dependabotx/`, `renovate-fix`, `feature/dependabot-x`, `Dependabot/npm/x`, and both bare-prefix forms — so a future edit to the anchor fails rather than silently widening it.

## Artifacts

- me2resh/apexyard#1364
