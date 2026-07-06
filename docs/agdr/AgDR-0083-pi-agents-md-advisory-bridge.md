# AgDR-0083 — `AGENTS.md` becomes the dual-purpose pi advisory bridge, not a new file

> In the context of pi (pi.dev) auto-loading `AGENTS.md` from cwd instead of `CLAUDE.md`, and apexyard's root `AGENTS.md` already serving a different, established audience (framework-repo orientation for contributors, per AgDR-0073), facing the need to deliver the same advisory SDLC governance to pi operators that `CLAUDE.md` delivers to Claude Code, I decided to **extend the existing `AGENTS.md` in place with a new "Operator governance bridge" section** (Chief-of-Staff framing + SDLC + inlined load-bearing rules + pointers to `.claude/rules/*.md`) rather than create a separate file or replace `AGENTS.md`'s contents, to achieve pi-compatible governance delivery through the one file pi actually auto-loads, accepting that `AGENTS.md` now serves two audiences in a single file and that mechanical enforcement for pi remains explicitly out of scope (deferred to the sibling spike, me2resh/apexyard#804).

## Context

Two prior decisions collide here:

1. **`CLAUDE.md` is the governance-delivery mechanism.** Claude Code auto-loads it every session; it imports `.claude/rules/*.md` and carries the full Chief-of-Staff/SDLC framing. This is the load-bearing content an apexyard operator needs, regardless of harness.
2. **`AGENTS.md` already exists and already has a job** (AgDR-0073): a tool-agnostic, in-repo orientation doc — project structure, key files, sandbox/test info, rate limits, conventions — aimed at an agent *contributing to apexyard's own source* (or, via `/handover`, aimed at whoever later works inside an *adopted* repo). It explicitly frames itself as "distinct from `CLAUDE.md`."

pi (pi.dev) doesn't resolve `CLAUDE.md` at all. It auto-loads `AGENTS.md` (cwd, or `~/.pi/agent/`) and an optional `SYSTEM.md`. So a pi user landing in an apexyard ops fork today gets whatever `AGENTS.md` says — which, before this decision, was framework-contributor orientation, not governance. The two files' audiences (Claude-Code operators via `CLAUDE.md`, non-Claude-Code operators via whatever they auto-load) were never reconciled, because until pi, "AI agent working in this repo" and "Claude Code" were effectively the same population.

## Options Considered

### Axis 1 — Where does pi-facing governance content live?

| Option | Pros | Cons |
|--------|------|------|
| New file (e.g. `PI.md`, `AGENTS_PI.md`) | Keeps `AGENTS.md`'s existing single-purpose framing intact | pi doesn't auto-load anything except `AGENTS.md` / `~/.pi/agent/` — a new file is invisible unless the operator manually points pi at it, which defeats "the same way `CLAUDE.md` delivers them to Claude Code" |
| Overwrite `AGENTS.md` with governance content only | Simplest possible file; single clear purpose | Destroys the existing framework-contributor orientation content that README, `docs/multi-project.md`, and AgDR-0073's `/handover` generation flow all reference and build on |
| **Extend `AGENTS.md` in place — add an "Operator governance bridge" section, retain the existing content under "Framework repo orientation"** | The one file pi actually loads now carries both; no new load convention to teach; existing callers (README, `/handover`) still resolve correctly since the file still exists at the same path with its prior content intact | The file now serves two audiences and is longer; a reader has to route themselves via the intro table |

### Axis 2 — How much of `CLAUDE.md`'s content to inline vs. reference

| Option | Pros | Cons |
|--------|------|------|
| Duplicate every rule file's full text into `AGENTS.md` | Zero extra reads for a pi agent | Massive duplication; the two copies drift the moment one is edited; defeats the point of `.claude/rules/*.md` being modular |
| **Inline only the load-bearing rule statements concisely; point to `.claude/rules/*.md` for full text/rationale/edge cases** | No duplication of the actual rule prose; pi *can* `Read` files on request, so the reference is cheap; matches how `CLAUDE.md` itself works (imports, doesn't inline, the rule files) | A pi agent that never reads the referenced files gets the condensed version only — acceptable, since the condensed version already states the actionable rule |

### Axis 3 — Mechanical enforcement scope

| Option | Pros | Cons |
|--------|------|------|
| Attempt to wire real enforcement now (e.g. a pi extension shelling out to the bash hooks) | Would close the advisory/mechanical gap in one pass | Unproven — pi's extension API surface for blocking tool calls, propagating exit codes, and exposing the tool/command string is unverified; conflating a documentation change with an unproven mechanical integration risks shipping neither cleanly |
| **Advisory only in this change; mechanical enforcement is the explicit, separately-tracked next step** | Ships the cheap, high-value slice (governance-as-instructions) now; keeps the two concerns — "can pi read the rules" vs. "can pi's tool calls be blocked" — decoupled and independently reviewable | Pi operators get no gate enforcement until the follow-up spike lands (or proves the pattern non-viable) |

## Decision

Chosen on all three axes:

- **Axis 1 — extend `AGENTS.md` in place.** A new top-of-file routing table tells a reader which of the two sections applies to them; the existing framework-contributor content is retained verbatim under "Framework repo orientation," just retitled and cross-referenced. No new load-order convention for pi to learn — it already auto-loads this file.
- **Axis 2 — inline the load-bearing rule *statements*, reference the rule *files*.** `AGENTS.md`'s new section states each rule's actionable content in one or two sentences (branch/PR/commit format, ticket vocabulary, one-ticket-at-a-time, plan-mode heuristic, reporting style, no secrets, no direct-`main`, AgDR requirement, PR quality, per-PR merge approval) and links to the corresponding `.claude/rules/*.md` file for full text.
- **Axis 3 — advisory only, explicitly.** `AGENTS.md`'s new section opens with a boundary callout: nothing here mechanically blocks a tool call for pi. Mechanical enforcement is out of scope for this change and is the subject of the sibling spike me2resh/apexyard#804 ("prove the governance-gate-as-pi-extension-over-bash pattern").

A short `SYSTEM.md` was added alongside `AGENTS.md` — pi's optional custom-system-prompt file — as a brief operating-posture primer that points back at `AGENTS.md` rather than duplicating its content, since the two files serve different layers (identity/behaviour priming vs. reference manual). A new `docs/harnesses/pi.md` documents the full today/not-yet breakdown and the install shape, so operators (and future contributors extending harness support further) have one place to check what's real.

## Consequences

- `AGENTS.md` is no longer single-purpose. Future edits to either section must keep the intro routing table accurate — a contributor adding framework-orientation content should not accidentally land it in the operator-governance section, and vice versa.
- The existing `/handover`-generated in-repo `AGENTS.md` convention (AgDR-0073) is unaffected: that flow generates a project-specific `AGENTS.md` for an *adopted* repo, a different file in a different repo. This AgDR only concerns apexyard's own root `AGENTS.md`.
- Mechanical enforcement for pi remains a known, explicitly-scoped gap until me2resh/apexyard#804 resolves (promote to a real feature, or disposition-discard with a documented alternative).
- If pi's own conventions evolve (e.g. it adds native project-instruction imports), this bridge should be revisited — the inline-vs-reference balance in Axis 2 was chosen against pi's *current* lack of an import mechanism.

## Artifacts

- PR: feat(#805): pi.dev AGENTS.md bridge (advisory rules for pi)
- Sibling spike: me2resh/apexyard#804
- Related: AgDR-0073 (`/handover`-generated in-repo `AGENTS.md`)
