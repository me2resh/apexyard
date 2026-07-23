# Technical Decisions — AgDR Required for *Material* Decisions

**HARD STOP**: before making a **material** technical decision — one that is architectural, hard to reverse, or cross-cutting — run `/decide` and create an Agent Decision Record (AgDR).

The word doing the work is **material**. An earlier version of this rule said "before making any technical decision," which read as *every* implementation choice: which helper to extract, how to shape a loop, what to name a module. That bar is unmeetable, and trying to meet it produces the failure mode this framework already named elsewhere — ceremony that costs more than the work it guards. Worse, it compounds: every AgDR written lands a file under `docs/agdr/**`, which re-fires the Tech Lead activation trigger (and, for a migration AgDR, the Solution Architect trigger too), so an over-broad AgDR rule manufactures exactly the role-handover churn [`role-triggers.md`](role-triggers.md) and [`right-size-ceremony.md`](right-size-ceremony.md) exist to prevent. See me2resh/apexyard#995 and #997.

This rule is the decision-record sibling of [`right-size-ceremony.md`](right-size-ceremony.md): same instinct (match the ceremony to the blast radius), applied to *recording* rather than *reviewing*.

## The threshold

A decision needs an AgDR when **any** of these is true:

| Signal | Because |
|--------|---------|
| It adds a **new dependency, library, framework, or technology** | Someone inherits the maintenance, licensing, and upgrade cost |
| It creates a **new service, bounded context, or external integration** | It changes the system's shape and its failure modes |
| It changes the **data model or schema** | Migrations are expensive and data loss is not reversible |
| It touches a **security-relevant control** — auth, crypto, secrets, the trust chain | Getting it wrong is the costliest class of wrong |
| It designs **CI/CD, release, or infrastructure** | It's the machinery everything else ships through |
| It adopts a **pattern repo-wide or cross-cutting** | Reversing it later means touching everything at once |
| It is **hard to reverse** — externally visible, shared-state, or expensive to undo | The record is the only cheap artifact left afterwards |

A decision does **not** need an AgDR when it is a routine implementation choice, reversible inside a single PR:

- Local naming — variables, functions, files, modules
- Whether to extract a helper, split a function, or inline something
- Control flow, error-handling shape, or how a loop is written
- Test structure, fixture layout, or which assertions to make
- Calling an API from a dependency **already in the manifest** (adding the dependency is material; using it is not)
- One-off refactors, formatting, and comment or doc wording

**The practical test:** *would a competent teammate six months from now be confused, or repeat expensive work, because this reasoning wasn't written down?* If yes, `/decide`. If they'd just read the code and move on, write the code.

The older heuristic — "if someone asked why you chose X over Y, would you need to explain trade-offs?" — is **too sensitive on its own**, because almost every line of code has an unexplained alternative. Use it only *after* the threshold table above already says the decision is material; it helps you write a better AgDR, it does not decide whether you need one.

## The two rails (unchanged, non-negotiable)

Narrowing the rule does not narrow the rails from [`right-size-ceremony.md`](right-size-ceremony.md):

1. **Security, trust chain, and migrations are never exempt.** A decision touching `.claude/hooks/**`, `.claude/settings.json`, auth, crypto, secrets, or a migration is material regardless of how small the diff is. A one-line change to a merge gate is exactly where you want the record.
2. **Ambiguity rounds up.** If you genuinely can't tell whether a decision is material, write the AgDR. The tolerated failure is an occasional unnecessary record — never a silently unrecorded architectural call.

## Self-check before the Build phase

```
[ ] Did I make a decision that meets the threshold above?   YES → AgDR exists for each?
[ ] Is it security / trust-chain / migration related?       YES → material, no exceptions (rail 1)
[ ] Am I unsure whether it's material?                      → round UP, write it (rail 2)
[ ] Material decision made with no AgDR?                    → create it NOW before proceeding
```

## Self-check during implementation

```
[ ] Am I adding a new dependency, service, integration, or technology?  → /decide
[ ] Am I changing a data model, schema, or a security control?          → /decide
[ ] Am I designing CI/CD, release, or infra?                            → /decide
[ ] Am I adopting a pattern across the whole repo?                      → /decide
[ ] Is this a routine choice reversible in this PR?                     → just write the code
```

## What `/decide` does

Creates an **Agent Decision Record** (AgDR) that captures:

- What options were considered
- Why the chosen option was selected
- Context that influenced the decision

**AgDRs are stored at**: `{project}/docs/agdr/AgDR-NNNN-{slug}.md`. Each project has its own folder and its own ID sequence.

Before drafting one, run `/agdr search <term>` — the portfolio may have already settled this, and re-litigating a decided call is its own kind of waste.

## Enforcement — and the honest limits of it

| Layer | What it actually does |
|-------|----------------------|
| **Self-discipline** | The threshold above, applied before writing code. The primary mechanism. |
| **Workflow gate** | AgDR required before the Build phase for new features (Gate 2, [`workflow-gates.md`](workflow-gates.md)). |
| **Code Reviewer (Rex)** | Flags PRs with architecture changes that don't link an AgDR. |
| **Pre-commit hooks** | `require-agdr-for-arch-changes.sh` / `require-agdr-for-arch-pr.sh`. |

The two hooks fire at different moments and on **different, deliberately bounded** path sets — neither is a catch-all for "any decision":

| Hook | Fires on | Default trigger set |
|------|----------|---------------------|
| `require-agdr-for-arch-changes.sh` | `git commit`, against the **staged** diff | `*.tf`, `*.tfvars`, `docker-compose*.yml`, `Dockerfile*`, `.github/workflows/**` |
| `require-agdr-for-arch-pr.sh` | `gh pr create`, against the **PR** diff | `**/domain/**`, `**/infrastructure/**`, `**/migrations/**`, `infrastructure/**`, `template.yaml`, `**/*.tf(vars)`, `.github/workflows/**` — **plus dependency *additions*** to `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `Gemfile` |

Two details worth knowing, because both are easy to get wrong from the comments alone:

- The commit-time hook **deliberately omits a bare `infrastructure/` directory pattern** (its `ARCH_GLOBS` excludes it even though an older header comment mentions it). Testing found it false-positived on `docs/infrastructure/notes.md` and `src/types/infrastructure/foo.ts` — the word is ambiguous between IaC and library code. Terraform is caught unambiguously via `\.tf$` at any depth instead. CDK / Pulumi projects using plain `.ts` / `.py` under `infrastructure/` should override via `.architecture_paths`.
- Only the **PR-time** hook watches dependency manifests, and only for *additions* — a version bump of something already present does not trigger it.

Both are configurable: `.architecture_paths` for the commit-time hook, `.agdr_trigger_paths[]` / `.agdr_trigger_dep_files[]` for the PR-time one, and `<!-- agdr: not-applicable -->` in a PR body bypasses the PR gate with a visible warning.

That bounded shape is correct, and this rule is now written to match its spirit. A rule far broader than anything anyone would actually enforce doesn't produce more records — it produces ignored prose, and it burns the agent's ceremony budget on decisions nobody needed written down. The threshold above is still **wider** than the hooks, deliberately: it covers new technologies, security controls, and cross-cutting patterns that no path glob can see. But it is no longer unbounded.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
