# Where Framework Self-Audit Artefacts Live

> In the context of ApexYard needing to audit **itself** (its own control-plane DFD, threat model, and other audits), facing the fact that all eleven audit skills resolve their output to `projects/<name>/` — the adopter's *private* portfolio in split-portfolio mode — I decided to **stay on the interim hand-publish approach (Option D, already shipped via #1115) and formally defer the durable `--self` mechanism (Option A) until the revisit trigger fires**, to achieve adopter-readable framework security docs without over-building an eleven-skill mechanism for a single-repo, ~once-per-release need, accepting that the interim drifts (someone must remember to re-publish) and that a real file-write leak-scrub gap is now on record but not yet closed.

## Context

ApexYard ships eleven audit skills (`/threat-model`, `/dfd`, `/security-review`, `/accessibility-audit`, `/compliance-check`, `/performance-audit`, `/monitoring-audit`, `/docs-audit`, `/seo-audit`, `/geo-audit`, `/analytics-audit`). All of them ultimately resolve output through one function — `portfolio_projects_dir()` in `.claude/hooks/_lib-portfolio-paths.sh` — which in split-portfolio mode points at the adopter's **private** portfolio repo. That is correct for a managed project but wrong for the framework itself: a threat model describing what the framework's own controls defend against is **adopter-facing documentation** and belongs in the public repo's `docs/`, next to `getting-started.md`.

This decision record is the formal AgDR the issue's AC #1 asks for. It supersedes-as-formal-record the interim decision already captured as a comment on #1093 (Option D, "for now"), and it captures the analysis from a decision packet (investigation → Solution Architect recommendation → Contrarian challenge) run on 2026-08-01 so future-us does not re-derive it.

Key facts established by the packet:

- **The artefacts already shipped.** PR #1115 (merged) hand-published `docs/architecture/dfd.md` and `docs/security/threat-model.md`. They were reviewed by Rex + Hakim (SECURE, controls-vs-backstops honestly labelled, leak-safe). ACs #2/#3/#4 are satisfied *for those two artefacts*.
- **The root-cause prerequisite is already fixed.** #1092 (`/dfd` discovery walking into `workspace/` and attributing other projects' dependencies to the target) is CLOSED (PR #1107). So the specific content-leak vector that surfaced this whole issue no longer ingests foreign `workspace/` content into a framework self-audit.
- **Option A is not one choke point.** Ten of the eleven skills route destination logic through the shared `audit_resolve_dir()` in `_lib-audit-history.sh`; `/dfd` bypasses that lib and resolves `portfolio_projects_dir` inline at five sites. So Option A = change the shared helper once **plus** a mirror change in `/dfd` **plus** flag-plumbing in all eleven `SKILL.md`.
- **A real, previously-unnoticed leak-scrub gap.** `block-private-refs-in-public-repos.sh` fires only on five `gh` write shapes (issue/PR create + comment, `gh api`), and **never on file writes** (`Write`/`Edit`/`>`redirect/`tee`/commit/push). So anything published into public `docs/` — including #1115's own output — goes out with **no mechanical scrub**. This is defense-in-depth-missing, not an active leak (#1115 was human-reviewed and #1092's root cause is fixed), but it is genuine and independent of the A-vs-interim question.
- **Zero accumulated drift.** The framework has self-published exactly once (#1115). The recorded revisit trigger for promoting to Option A — "the next time we need to publish/refresh… or when the manual-copy drift becomes painful" — has not objectively fired.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A — `--self`/`--framework` flag** redirecting audit output to public `docs/`, via the shared `audit_resolve_dir()` choke point (+ `/dfd` mirror + eleven-skill flag plumbing) | Durable; keeps default private (opt-in per-invocation); reuses the one function 10/11 skills share; smallest durable blast radius of the "build it" options; preserves the DFD-snapshot + trend-persistence guarantees | Threads a flag through eleven skills + `/dfd`'s five inline sites + a registry marker; a permanent `/dfd` dual-resolution drift risk; **requires** a new file-write leak-scrub first or it is a *worse* leak vector than the manual status quo; builds a mechanism for a single-repo, ~once-per-release need with no accumulated drift; **contradicts the recorded deferral** |
| **B — registry `visibility:`/`docs_root:` field** redirecting audit output | Most general (also serves a genuinely-public managed project) | Disproportionate blast radius (a schema field every registry reader inherits + per-skill honouring logic); worse leak posture — a silent, config-driven redirect vs. a human-typed per-run flag; serves a use case that does not exist in the registry today (YAGNI); the owner already did not choose it |
| **C — framework out of scope for audit skills; hand-author** | Cheapest; honest; exactly what #1115 did | Loses the templated DFD-snapshot property and audit-history trend persistence; re-authored by hand each cycle |
| **D — register normally + manually copy artefacts when they ship** (the recorded interim) | No code change; unblocks publishing by hand | "Relies on someone remembering" and *will* drift — acknowledged as a deliberate stopgap, not the final answer |

The Solution Architect (Tariq) recommended **A + two hardening additions** (the file-write leak-scrub, and an inert `self: true` registry marker) as the eventual shape. The Contrarian (Naqid) accepted the leak-scrub finding as the genuinely valuable, non-deferred output but challenged **building A now**: the owner already deferred A on this very issue with a named revisit trigger that has not fired; the scrub is worth building on its own and should not be held hostage to the deferred ergonomics feature; and the proposed registry-name-only scrub would miss the real content-class leak (dependency names, paths, hostnames) that surfaced the issue. Verdict: **proceed-with-changes — split the work; hold the mechanism.**

## Decision

Chosen: **Stay on the interim (Option D, shipped) and formally defer Option A**, because nothing has changed the revisit trigger the owner recorded — the framework has self-published once, there is no accumulated drift, and #1092's root cause (the content-leak source) is already fixed. Building the eleven-skill mechanism now would contradict the recorded deferral and over-build for a single-repo, ~once-per-release need.

Concretely, this record:

1. **Closes AC #1** — this is the formal AgDR the issue asked for; the interim decision is now recorded here, not only in an issue comment.
2. **Closes AC #5 (registry expression)** by taking the AC's own "or it is documented why that is acceptable" path: the framework is deliberately **not** a normal registry entry. The ops repo *is* the working copy, so there is no `workspace/<name>/` clone to point a registry entry at; `workspace:` is already an optional field, so omitting it is legal and expected. We do **not** add an inert `self: true` marker — an unused key that nothing consults is a worse answer than documenting the exception. If registry-aggregated visibility of the framework (in `/projects`/`/status`) is ever wanted, that is its own scoped work, not a decorative box-tick here.
3. **Records the recommended eventual shape** (Option A + the leak-scrub, per the packet) so a future promotion does not re-derive it — see Consequences.
4. **Puts the file-write leak-scrub gap on the record** as genuine, non-deferred future work that is *independent* of the A-vs-interim question — it should be built as a standalone guard whenever a public file-write publication path is next touched, and it **must** land in or before any PR that ever introduces the `--self` mechanism (an unscrubbed `--self` is strictly worse than the reviewed-by-hand interim it would replace).

## Consequences

- **The framework's own DFD + threat model stay public and adopter-readable** (via #1115), and the decision on how it audits itself is now formally recorded. ACs #1, #2, #3, #4 (for the shipped artefacts), and #5 are satisfied; the issue can close on this record.
- **The interim drifts by design.** The next time the framework's threat model / DFD needs a refresh, it is re-published by hand (re-run the audit against the framework registered normally, copy the artefact into `docs/`). That manual step is the recorded revisit trigger: when it becomes painful, promote to Option A.
- **Recommended eventual mechanism (Option A), when the trigger fires:** add a `--self`/`--framework` flag resolving "self" to the ops-fork root's own `docs/` (architecture → `docs/architecture/`, threat-model → `docs/security/`, findings-audits → a `docs/audits/<dimension>/` tree to be named); implement the destination branch once in `audit_resolve_dir()` (`_lib-audit-history.sh`), mirror it at `/dfd`'s five inline sites, and add flag-parsing to the eleven `SKILL.md`. Guard `--self` so it is refused off the canonical framework fork — and note the `.apexyard-fork`/`onboarding.yaml` anchor **cannot** distinguish `me2resh/apexyard` from an adopter's own `org/apexyard` fork, so a public-adopter-fork leak path must be closed explicitly (either refuse `--self` off the canonical upstream, or make the scrub's public-class test include "this fork is itself a public GitHub repo").
- **Known gap on the record (independent of A):** `block-private-refs-in-public-repos.sh` never fires on file writes, so public `docs/` publication has no mechanical scrub today. A future guard must (a) fire at the real publication boundary — cover Bash writes via `_lib-detect-bash-write.sh` or move to commit/push time like `check-secrets.sh`, not a `Write`/`Edit`-only matcher; (b) widen its threat model beyond registry `name`/`repo`/`workspace` to the content class that actually leaks (dependency names, file paths, internal hostnames, contributor names) or explicitly state that content-class leakage remains a human-review responsibility; and (c) scope to public-class destinations only, so `/dfd --scope-all`'s legitimate project labels on a *private* fork are not stripped.
- **No code changed in this PR.** This is a decision record only (Lean tier) — no behaviour change, trivially reversible.

## Artifacts

- Issue: me2resh/apexyard#1093 (the driver + the recorded interim decision comment)
- Shipped interim: PR #1115 (`docs/architecture/dfd.md`, `docs/security/threat-model.md`)
- Root-cause prerequisite, fixed: me2resh/apexyard#1092 (PR #1107)
- Decision packet (investigation → Solution Architect recommendation → Contrarian challenge), run 2026-08-01
- This PR: docs-only, records AgDR-0119
