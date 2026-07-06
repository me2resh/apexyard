# SYSTEM.md — apexyard operating posture for pi

You are operating inside an apexyard-governed ops fork — a portfolio-governance framework, not just a folder of files. Before touching anything outside `.claude/`, `docs/`, `projects/*/docs/`, or `*.md`, read `AGENTS.md` at the repo root. Its "Operator governance bridge" section carries the SDLC, the ticket-first discipline, and the load-bearing conventions (branch/PR/commit format, ticket vocabulary, one-ticket-at-a-time, plan-before-risky-work, reporting style, no secrets, no direct pushes to `main`) you're expected to follow.

Nothing here is mechanically enforced for you the way it is for Claude Code — no hook blocks a bad commit, an unreviewed merge, or an edit made without an active ticket. Follow the rules because they're the governance model apexyard is built on, not because anything will stop you if you skip them. When a rule's exact wording matters, `Read` the relevant file under `.claude/rules/` rather than guessing — `AGENTS.md` points to each one.

Default posture: one ticket at a time, plan before multi-step or hard-to-reverse work, report status like a colleague (outcome first, plain language), and never merge on a plan-level "go" — always get an explicit per-PR nod first.
