# Product

## Register

product

## Users

Founders, CTOs, and engineering leads running a **portfolio of repos** with AI coding agents (Cursor, Claude Code). They work in the ops repo daily for `/inbox`, `/status`, tickets, PR gates, and cross-project docs. Context: shipping MVPs under strict SDLC, often solo or small squad, high trust bar for process and quality.

## Product Purpose

**ApexYard** is an SDLC-as-code ops framework: hooks, skills, roles, templates, and portfolio registry that turn AI-assisted development into production-ready shipping. The ops repo governs managed projects; `site/` is the public marketing surface at [yard.apexscript.com](https://yard.apexscript.com/).

Success: operators trust the gates (ticket-first, review, QA), reuse patterns across projects, and ship without process drift.

## Brand Personality

**Disciplined, expert, forge-like.** Confidence from mechanics (hooks, gates, checklists), not hype. The marketing site uses editorial mono typography and a single accent stamp — the product UI elsewhere follows `golden-paths/ui` (Tailwind + shadcn). Calm authority, not startup candy or purple-gradient AI slop.

## Anti-references

- Generic AI-dev-tool landing (purple gradients, Inter + three identical feature cards).
- Process theater without mechanical enforcement (docs-only SDLC).
- Bland monospace blogs with no hierarchy or accent discipline.
- Mixing consumer brand systems (blendavit, LUMA) into framework or site work.

## Design Principles

1. **Mechanics over manifestos** — If a rule matters, a hook or gate enforces it.
2. **Portfolio memory** — Projects learn from shared AgDRs, handbooks, and registry context.
3. **One ticket, one PR** — Scope stays reviewable; no drive-by refactors.
4. **Register-aware UI** — Marketing (`site/`) is brand register; managed app UIs are product register; never cross-pollinate tokens.
5. **Show the forge** — Site and docs demonstrate the stack (skills, workflows), not abstract "AI magic."

## Accessibility & Inclusion

- Target **WCAG 2.1 AA** on public `site/` pages (contrast on paper/ink palette, keyboard nav, focus states).
- Respect `prefers-reduced-motion` and `prefers-color-scheme` (site already supports dark via media query).
- Plain language in docs; jargon defined in PR glossaries.
