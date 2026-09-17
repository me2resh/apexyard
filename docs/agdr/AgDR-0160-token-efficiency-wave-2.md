# Load rule bodies on demand

## Status

Accepted

## Context

Wave 1 (AgDR-0044, #322) shortened skill blurbs and the CLAUDE.md skill table.
Wave 2 from that record did not ship.

On `dev` at `3953d50` the always-on catalogue is still about 53.7k tokens
(chars÷4). That figure is CLAUDE.md plus 22 rule files plus skill
`description:` strings. CLAUDE.md restates the long rules. It also uses
`@.claude/rules/<file>.md` references. Claude Code treats those as imports.

Hard gates already live in `.claude/hooks/*.sh`. #1317 and #1318 cut hook
latency. They did not cut this catalogue.

Parent record: AgDR-0044.

## Decision

Make CLAUDE.md an index. Do not auto-import rule bodies at session start.

- Keep every file under `.claude/rules/`.
- Name each rule in CLAUDE.md.
- Instruct the agent to Read a named file when the work needs it.
- Do not use `@.claude/rules/` paths in CLAUDE.md. Claude Code would import them.
- Keep a few one-line load-bearing formats in CLAUDE.md (branch, PR title,
  no `git add -A`, no push to `main`).
- Keep the Wave 1 skill table.
- Keep mechanical gates in hooks.
- Keep AGENTS.md as a short operator bridge plus a path table. Do not copy
  the full rule bodies into AGENTS.md.

## Consequences

Agents will not see the full text of every rule on every turn. They must
Read the named file when the work matches. A missed Read is a real risk.
Hooks still block ticket-first edits, merge without markers, secrets, leak
protection, and `git add -A`.

The always-on catalogue becomes CLAUDE.md plus skill `description:` strings.
Rule bodies drop out of the session-start load.

Cursor still runs `.claude/hooks/*.sh` when third-party configs are on. The
`.cursor/rules/apexyard.mdc` overlay stays a short pointer. It must not tell
the agent to ingest every rule file.

Wave 3 from AgDR-0044 (shared SKILL.md preamble extraction) stays out of
scope.

## Options considered

| Option | Result |
| --- | --- |
| Index in CLAUDE.md. Load rule bodies on demand. Keep none of the long bodies always-on. | Accepted. It cuts the catalogue without removing primitives. Hooks stay the gates. |
| Keep a core set of rule files always imported and defer the rest. | Rejected. Any always-imported body re-grows the tax. The index plus hooks already cover the floor. |
| Keep the current restatement and glob-style imports. | Rejected. Wave 1 already took the cheap compression. The remaining cost is structural. |

## References

- Issue #1319
- AgDR-0044
- AgDR-0157
- AgDR-0159
