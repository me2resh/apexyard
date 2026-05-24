# Handbooks — `domain/<area>/`

Domain handbooks capture review knowledge about a **specific problem domain** the codebase deals with — GitHub EMU migration semantics, Stripe webhook validation, SAML SSO claim shapes, payment-reconciliation invariants, etc. They live at:

```
handbooks/domain/<area>/*.md           ← public layer (this directory)
<private>/custom-handbooks/domain/<area>/*.md   ← split-portfolio private layer
```

Both layers are discovered together by Rex via the same path-convention as the other handbook buckets (`architecture/`, `general/`, `language/`). Design rationale: [`AgDR-0037`](../../docs/agdr/AgDR-0037-rex-domain-handbooks.md).

## Why a separate bucket

The existing buckets answer different questions:

| Bucket | Answers |
|---|---|
| `architecture/` | How is the code structured? (DDD layers, dependency direction, value objects) |
| `general/` | How do we communicate? (commit messages, comment density, naming) |
| `language/<lang>/` | How do we write this language? (strict-mode, error shapes, type rules) |
| **`domain/<area>/`** | **What does this domain require of us?** (EMU migrations must handle private-fork access; Stripe webhooks must verify the `Stripe-Signature` header) |

Mixing domain rules into `architecture/` makes architecture handbooks bloated; mixing into `language/` doesn't fit because domain knowledge is language-agnostic.

## Path-match frontmatter — the `paths:` field

Unlike the other buckets, **domain handbooks support an opt-in `paths:` frontmatter field** so Rex only loads them when the PR diff intersects the domain's code:

```markdown
---
paths:
  - "scripts/github-emu-migration/**"
  - "**/emu-*.{ts,js,py}"
  - "src/auth/emu/**"
---

ENFORCEMENT: blocking

# Handbook: GitHub EMU migration safety

**Scope:** PRs that touch the GitHub EMU migration scripts or EMU-related auth code.

## The rule
...
```

Rex evaluates: *does any file in the PR diff match any glob in `paths:`?* If yes → load this handbook. If no → skip it. This keeps Rex's per-PR token cost bounded — a handbook on Stripe webhooks doesn't pollute reviews of unrelated infrastructure work.

### Always-load (foundational domain rules)

If you **omit** the `paths:` field, or leave it empty, the handbook loads on **every** review. Use this for cross-cutting domain rules that don't have a clean file-path boundary — e.g. a handbook on "tenant isolation" that applies to any PR even if no specific path matches.

```markdown
---
# no paths: field → always load
---

ENFORCEMENT: blocking

# Handbook: Tenant isolation

**Scope:** all PRs in this multi-tenant codebase.
...
```

## File format

Same shape as the other buckets — see [`../README.md`](../README.md) § "File format". The frontmatter block is the only addition; the rest of the file is flat markdown with `## The rule` / `## Why` / `## What Rex flags` / `## Sample finding` / `## What's NOT a violation` sections.

`ENFORCEMENT: blocking` works the same way — place the literal phrase at the top of the file (after the frontmatter block, before the H1 title). Without it, findings are advisory.

## Authoring

Same `cp` + edit flow as the other buckets:

```bash
mkdir -p handbooks/domain/github-emu
cp handbooks/architecture/clean-architecture-layers.md handbooks/domain/github-emu/migration.md
$EDITOR handbooks/domain/github-emu/migration.md
# Add the frontmatter `paths:` block at the top, then write the rule.

git add handbooks/domain/github-emu/migration.md
git commit -m "docs(#NN): handbook on GitHub EMU migration safety"
```

For private domain handbooks (split-portfolio adopters), use the same flow under `<private_repo>/custom-handbooks/domain/<area>/`.

## Enrichment over time

A domain handbook is most valuable when it grows from the **misses** Rex makes against the actual codebase. The intended workflow:

1. **Seed** with the canonical facts you already know (one short bullet list).
2. **Capture lessons** — when a PR ships a bug that Rex didn't catch but the domain handbook *could* have flagged, add a rule to the handbook. Future PRs benefit.
3. **Prune** — when a rule no longer applies (the underlying domain constraint went away), remove it. Stale rules generate noise and tune the layer out.

Two follow-up skills make this cheaper (tracked in this same feature ticket as Stages 2 and 3):

- `/codify-rule` — turn a human review comment into a handbook entry, with operator Y/N approval per finding
- `/enrich-domain <area>` — walk recent merged PRs that touched the area and propose additions Rex would have benefited from

Neither is shipping in this MVP. The path-glob discovery is the foundation; the enrichment skills layer on once it's proven.

## What's NOT a domain handbook

- A general-purpose architecture rule. → `handbooks/architecture/`
- A language-specific rule. → `handbooks/language/<lang>/`
- A cross-cutting team-communication rule (commit messages, glossary discipline). → `handbooks/general/`
- A one-time decision record. → `docs/agdr/` (an AgDR, not a handbook)
- A skill spec. → `.claude/skills/<name>/SKILL.md`

If you find yourself writing a domain handbook that has no `paths:` field AND no obvious domain boundary, it probably belongs in `architecture/` or `general/` instead.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
