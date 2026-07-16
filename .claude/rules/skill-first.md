# Skill First — Reach for a Skill Before Doing It by Hand

ApexYard ships 62 slash commands, each one a focused workflow with its own template, structured export, and cross-checks — `/threat-model` produces a STRIDE writeup against `templates/audits/threat-model.md`, `/dfd` emits a Mermaid diagram plus optional Threat Dragon JSON, `/write-spec` fills out `templates/prd.md`. Skills are discoverable via `/help` and invoked explicitly, but nothing *suggests* one from intent alone. When a request clearly maps to a shipped skill, an agent relying on its own discipline can quietly do the work by hand instead — reasoning through a threat model in prose, drafting a PRD from scratch, sketching a data-flow diagram as an ad-hoc Mermaid block. The output can look similar at a glance, but it diverges from the template, skips the skill's built-in cross-checks, and doesn't land in the structured location (`docs/agdr/`, `templates/audits/`, `projects/<name>/prds/`) other tooling expects.

This rule is the **trigger heuristic** — the skill-side sibling of [`agent-role-selection.md`](agent-role-selection.md) (which role to spawn) and [`plan-mode.md`](plan-mode.md) (when to plan first). It defines when to stop and check "does a skill already own this?" before improvising.

## When to reach for a skill instead of ad-hoc work

Heuristic: before starting audit, diagram, spec, or ticket-shaped work, ask whether the request matches one of these families:

| Request shape | Reach for | Not: |
|----------------|-----------|------|
| "do a threat model", "STRIDE analysis" | `/threat-model` | Freehand STRIDE reasoning in a chat reply |
| "make a DFD", "data flow diagram" | `/dfd` | An ad-hoc Mermaid diagram with no trust-boundary structure |
| "accessibility audit", "WCAG check" | `/accessibility-audit` | A prose list of a11y observations |
| "compliance check", "GDPR audit" | `/compliance-check` | Improvised consent/privacy-policy commentary |
| "SEO audit" / "GEO audit" | `/seo-audit` / `/geo-audit` | A one-off meta-tag scan with no structured findings |
| "write a spec", "draft a PRD" | `/write-spec` | A PRD-shaped doc that doesn't follow `templates/prd.md` |
| "file a bug", "report a bug" | `/bug` | A GitHub issue with no Given/When/Then or repro section |
| "plan this initiative", "plan the quarter" | `/plan-initiative` | An in-chat milestone list with no topo-sorted ticket filing |
| "decide between X and Y", "let's decide" | `/decide` | Picking a library/approach with no AgDR recorded |

This list is illustrative, not exhaustive — the authoritative, extensible map lives at `.claude/project-config.defaults.json` → `skill_intent.map` (see "Backstop" below). If a request matches a skill not listed here, the same heuristic applies: check `/help` or the skill table in `CLAUDE.md` before reasoning it through by hand.

## When NOT to reach for a skill

- **No skill owns this shape of work.** Plenty of requests are genuinely bespoke — a one-off refactor, a targeted debugging session, a question about existing code. Don't force a skill where none fits.
- **The user already invoked the skill, or explicitly asked for ad-hoc work.** "Just sketch a quick DFD in the chat, don't file anything" is a legitimate, explicit override — respect it.
- **The skill's output shape genuinely doesn't match the need.** A skill produces a structured artifact for a reason; if the user wants a two-sentence gut-check, not a filed template, say so and proceed lightly rather than forcing the heavier flow.
- **Mid-skill work.** Once a skill is running (e.g. mid-`/write-spec` interview), don't re-litigate whether to have started it — finish the flow.

## Self-check before responding

Before doing audit, diagram, spec, or ticket-shaped work by hand, scan your planned response for:

```
[ ] Does this request match an intent family a shipped skill already owns?
[ ] Is there a specific reason NOT to use the skill (explicit ad-hoc request, no skill fits, mid-flow already)?
[ ] If a skill fits and no override applies, did I invoke it instead of improvising the output?
```

If the first box is checked and the second isn't, invoke the skill before producing the artifact by hand.

## Backstop

This rule is **primarily self-discipline**, same shape as `plan-mode.md` and `agent-role-selection.md`. The framework also ships a mechanical backstop: `.claude/hooks/detect-skill-intent.sh`, a `UserPromptSubmit` advisory hook that scans the prompt for intent phrases and prints a banner naming the owning skill + its template — the SKILL-side analog of `detect-role-trigger.sh` (which does the same for ROLE activation). Same advisory shape as every hook in this family: non-blocking, exit 0 always. It cannot force the skill, only surface it.

The phrase → skill map is **data-driven**, not hard-coded in the hook: it lives at `.claude/project-config.defaults.json` → `skill_intent.map`, an array of `{skill, template, phrases}` entries. Adopters extend or replace it via `.claude/project-config.json` (shallow-merge — defining `skill_intent` in the override replaces the whole subtree, so copy the entries you want to keep) without touching hook logic. See `.claude/hooks/tests/test_detect_skill_intent.sh` for the covered phrase families (audit, diagram, spec, ticket, decision).

The cost of invoking a skill and finding it's the wrong fit is a few seconds of an unnecessary flow. The cost of quietly reasoning through threat-model-shaped or PRD-shaped work by hand is a diverged artifact that doesn't match the template, doesn't land where other tooling expects it, and doesn't get the skill's built-in cross-checks.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
