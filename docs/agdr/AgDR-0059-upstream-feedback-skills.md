# Two skills for filing framework feedback upstream (`/report-apexyard-bug`, `/request-apexyard-feature`)

> In the context of adopters hitting bugs in — or wanting features for — the apexyard framework itself with no in-session path to report them, facing the fact that the existing `/bug` and `/feature` skills file into the adopter's OWN project tracker, I decided to add two thin sibling skills that file a structured issue UPSTREAM to `me2resh/apexyard`, with mandatory leak-scrubbing of private project names, to achieve a closed feedback loop from adopter to maintainer, accepting two more skills on the surface (mitigated by namespaced `apexyard-` names that make the distinction obvious).

## Context

`/bug` and `/feature` create structured GitHub issues in the **adopter's managed-project repo** — the right target for a bug/feature in *their* code. But an adopter who hits a framework bug (a hook misfires, a skill is broken, a rule produces a wrong result) or has a framework feature idea has **no in-session path** to report it upstream; they'd have to leave the session and navigate to GitHub manually. The feedback loop from adopter → framework maintainer was missing.

The motivating signal: across heavy framework use, real framework bugs surfaced (hook false-positives, gate-level mismatches, packaging gaps) that an adopter would want to report — but the only structured-issue skills filed into the wrong repo.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Reuse `/bug` + `/feature` with a "which repo?" prompt | No new skills | Overloads project-scoped skills with an upstream mode; the default target ambiguity is exactly the leak risk we want to avoid |
| One `/feedback` skill (asks bug-or-feature) | Single command | Conflates two different templates + labels; less discoverable than named intent |
| **Two named skills `/report-apexyard-bug` + `/request-apexyard-feature` (chosen)** | Intent is explicit in the name; clearly distinct from `/bug`/`/feature`; each carries the right template + label; namespaced `apexyard-` signals "about the framework" | Two more skills on the surface |

## Decision

Chosen: **two named skills filing upstream, with leak-scrubbing.**

1. **Target is always upstream `me2resh/apexyard`** — resolved via `git remote get-url upstream` with a fallback to the canonical slug, regardless of the adopter's fork origin. (Confirmed via AskUserQuestion: file upstream, not the adopter's fork.)
2. **Named, not a single `/feedback`** — `/report-apexyard-bug` and `/request-apexyard-feature` make the intent explicit and carry the correct template (bug = Given/When/Then + repro + severity + affected-part; feature = problem-first + proposed behaviour + adopter benefit) and label (`bug` / `enhancement`).
3. **Mandatory leak-scrubbing** — both skills write to a PUBLIC repo, so private registered-project names must never appear. The skills instruct authoring-time scrubbing and rely on `block-private-refs-in-public-repos.sh` as the mechanical backstop, consistent with `.claude/rules/leak-protection.md`. The `<!-- private-refs: allow -->` escape is used only on explicit user confirmation.
4. **Framework-version capture** — both record the fork's version (`git describe`/short SHA) so the maintainer knows which version the report is against.
5. **Reuse existing plumbing** — the active-issue-skill marker (per #268 / AgDR-0030) gates the `gh issue create`; the require-skill-for-issue-create hook checks only that the marker is non-empty, so the new skill names work without an allowlist change.

## Consequences

- Two new skills: `.claude/skills/report-apexyard-bug/SKILL.md`, `.claude/skills/request-apexyard-feature/SKILL.md`.
- Skill count 57 → 59 (`CLAUDE.md` + `site/*` updated; `test_site_counts.sh` green). No new hook/role/agent.
- Adopters get a one-command path to send framework feedback; the maintainer sees adopter bug reports + feature requests in the canonical repo.
- The leak-protection backstop now covers a new write path (framework feedback) in addition to the existing tracker-write paths — same rule, additional surface.

## Artifacts

- Issue: me2resh/apexyard#482
- New: `.claude/skills/{report-apexyard-bug,request-apexyard-feature}/SKILL.md`
- Edited: `CLAUDE.md` (skills table + counts), `site/*` (counts)
- Related: `/bug` + `/feature` (the project-scoped siblings), `.claude/rules/leak-protection.md` (the scrubbing rule + backstop hook), AgDR-0030 (#268 issue-skill marker), the `/onboard`→`/setup` alias-redirect precedent for how thin intent-named skills coexist.
