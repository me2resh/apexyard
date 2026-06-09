# AgDR-0063: Portfolio UI golden path (Tailwind + shadcn)

**Date:** 2026-06-08  
**Status:** Accepted  
**Deciders:** Khalid (Head of Engineering), Maha (Head of Design), operator

## Context

Portfolio React apps were at risk of inconsistent, generic AI-generated UI ("slop") — mixed styling systems, invented components, default Inter/purple gradients. Operator requested a persistent standard: Tailwind CSS + shadcn/ui (not Material UI), codified for agents.

LUMA PWA (clinic marketplace, different client) runs Next.js + Tailwind + shadcn. blendavit / Smart Mom Labs (different client) remains vanilla HTML + its own `DESIGN.md`. **These brands must never share theme files.**

## Decision

1. **Default stack for React apps:** Tailwind CSS + shadcn/ui (Radix primitives, repo-local `components/ui/`).
2. **No MUI** on new greenfield work.
3. **Ship neutral scaffold** at `golden-paths/ui/` (neutral theme, seven primitives, `cn()` helper) — **no client tokens in shared theme**.
4. **Agent skill** at `.claude/skills/ui-standards/` with **project firewall**: blendavit ↔ LUMA cross-import forbidden.
5. **LUMA-only assets** isolated under `golden-paths/ui/integrations/luma-pwa/` (not in shared `theme/`).
6. **blendavit** uses only `projects/smartmomlabs/website/DESIGN.md` — no Tailwind/shadcn/LUMA unless explicit migration ticket.

## Consequences

- New React apps copy `golden-paths/ui/` instead of improvising.
- LUMA syncs toward golden path in phased PRs (opsUi extraction first).
- No published `@dr-kersho/ui` npm package in v1 — copy scaffold only. Revisit when 2+ apps need versioned shared components.

## Alternatives considered

| Option | Rejected because |
|--------|------------------|
| Material UI + Tailwind | Two styling systems; Material look |
| Published monorepo package | Overhead before second live consumer |
| Skill only, no scaffold | Agents still invent file contents |
| TD-001 brutalism as LUMA preset | Superseded by DESIGN-DIRECTION-SYSTEM-2026 |
