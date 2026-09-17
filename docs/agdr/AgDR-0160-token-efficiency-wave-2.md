# Load rule bodies on demand

## Status

Accepted

## Context

Wave 1 (AgDR-0044, #322) shortened skill blurbs and the CLAUDE.md skill table.
Wave 2 from that record did not ship.

On `dev` at `3953d50` Claude Code always-on load was about 43.1k tokens
(chars÷4). That figure is CLAUDE.md (7,720) plus 15 `@`-imported rule files
(33,286) plus skill `description:` strings (2,145). The 15 files are:

`agdr-decisions`, `agent-role-selection`, `evidence-grounding`,
`git-conventions`, `glossary-lookup`, `isolated-builds`, `loop-mode`,
`plan-mode`, `pr-workflow`, `reconcile-before-build`, `reporting-style`,
`right-size-ceremony`, `role-triggers`, `skill-first`, `ticket-vocabulary`.

The other seven rule files were already on-demand. CLAUDE.md also restated
the imported rules in the Quality Rules block. The `@.claude/rules/*.md`
string in CLAUDE.md sat inside backticks. It did not glob-import 22 files.
A 53.7k figure that summed CLAUDE.md plus all 22 rule files overstated the
Claude Code load by about 10k tokens. Ticket #1319 inherited that error.

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
  the full rule bodies into AGENTS.md. Cursor, pi, Codex, and opencode load
  AGENTS.md. That file must stay an index, not a second restatement.

## Consequences

Agents will not see the full text of every rule on every turn. They must
Read the named file when the work matches. A missed Read is a real risk.
Hooks still block ticket-first edits, merge without markers, secrets, leak
protection, and `git add -A`. Advisory rules with no hook (evidence
grounding, plan mode, right-size ceremony, reporting style) now depend on
that Read.

The Claude Code always-on catalogue becomes CLAUDE.md plus skill
`description:` strings. Rule bodies drop out of the session-start load.
Chars÷4 does not measure prompt-cache hits. The per-turn marginal cost of
the old imports is unverified.

Cursor still runs `.claude/hooks/*.sh` when third-party configs are on. The
`.cursor/rules/apexyard.mdc` overlay stays a short pointer. It must not tell
the agent to ingest every rule file.

The Wave 2 test caps CLAUDE.md plus skill descriptions at 9,000 tokens. It
caps AGENTS.md at 5,000 tokens. Those caps bind near the measured values.

Wave 3 from AgDR-0044 (shared SKILL.md preamble extraction) stays out of
scope.

Naqid challenged this record (advisory). Verdict: proceed-with-changes.
This file now uses the 43.1k composition, a binding test cap, and a shorter
AGENTS.md index.

## Options considered

| Option | Result |
| --- | --- |
| Index in CLAUDE.md. Load rule bodies on demand. Keep none of the long bodies always-on. | Accepted. It cuts the catalogue without removing primitives. Hooks stay the gates. |
| Keep a core set of rule files always imported and defer the rest. | Rejected. Any always-imported body re-grows the tax. The index plus hooks already cover the floor. |
| Keep the current restatement and glob-style imports. | Rejected. Wave 1 already took the cheap compression. The remaining cost is structural. |
| Delete the restatement and keep the 15 `@` imports. | Rejected as a stopping point. It leaves the import tax. It is the control arm that shows the adherence risk is worth watching after merge. |

## References

- Issue #1319
- AgDR-0044
- AgDR-0157
- AgDR-0159
