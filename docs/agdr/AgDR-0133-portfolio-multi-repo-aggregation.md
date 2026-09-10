# Portfolio-view aggregation across a multi-repo project's repos

> In the context of the five portfolio-view skills reading one repo per
> registry entry while AgDR-0121's `repos:` schema lets a project hold
> several, facing a dashboard that silently under-reports every repo but
> the primary, I decided to fold per-repo results in one shared shell
> library, fetch them with the skills' existing commands in parallel under
> a concurrency cap, render one row with per-repo detail only on exception,
> and land `/handover`'s clones in a per-project container directory,
> accepting that the multi-repo path ships fixture-tested only and that two
> helpers outside the original surface must change.

## Context

AgDR-0121 made a multi-repo product one registry entry and taught every
*security* consumer to read the whole list — leak-scrub, the tracker
override, the multi-repo trace accessors. It deferred the five
portfolio-view skills (`/projects`, `/inbox`, `/tasks`, `/status`,
`/handover`), which still fetch from one repo per entry. me2resh/apexyard#1138
is that deferred half.

The ticket settled the per-field folds (counts sum, CI worst-of, activity
newest, harnessability never averaged, contributors union) and the rendering
option (C by default, D as an explicit `--by-repo` drill-down). It left five
points to design, and reviewing the first draft surfaced a sixth — the six
the design records as D1 through D6. This record covers the four of them
that meet the `.claude/rules/agdr-decisions.md` threshold.
The full design, with the measurements, is
[`docs/technical-designs/portfolio-multi-repo-aggregation.md`](../technical-designs/portfolio-multi-repo-aggregation.md).

Measurements were taken 2026-09-07 with `gh` 2.100.0 and git 2.55.0 on
macOS. The reference portfolio registers 32 projects, 30 with a singular
`repo:` and **none** with `repos:` — so nothing here was exercised against a
live multi-repo project.

## Options Considered

### 1. Fetch strategy

| Option | Pros | Cons |
|--------|------|------|
| One batched GraphQL query per project | 0.53 s for 8 repos in 1 call, measured | Changes the data source for **every** project, singular included — `totalCount` reports 40 where today's command reports 30, so singular output is no longer byte-identical. Re-forks the issue axis to GitHub-only, undoing AgDR-0093's tracker-agnostic `tracker_list`. Using it only at R ≥ 2 gives one field two resolvers — the shape #1182 is unwinding |
| **Parallel per-repo fetch under a concurrency cap** | Nothing changes about *what* is fetched or *how* it renders; R = 1 runs the identical command sequence. Latency scales with ⌈R / P⌉. Bash 3.2 clean | Multiplies calls by R; the hourly budget binds sooner on a large multi-repo portfolio |
| Short-lived cache keyed on repo + HEAD | Cheapest on repeat runs | HEAD is not a valid key for PR and issue counts, which move without HEAD moving, and learning HEAD costs a call. A TTL cache serves stale CI on a dashboard whose job is "what needs attention now" — the confidently-wrong failure AgDR-0120's correct-or-cold design exists to avoid |

### 2. Where the aggregation logic lives

| Option | Pros | Cons |
|--------|------|------|
| Inline in each of the five skills | No new file | Five copies of a fold, drifting independently; the duplication #1182 is paying down |
| **One shared library under `.claude/hooks/`** | One definition of every fold; the same home and shape as `_lib-tracker.sh` and `_lib-multi-repo-trace.sh`, which skills already source | Lands on a trust-chain path, so the Security Auditor fires on the implementation PR |

### 3. Where `/handover`'s clones land for a multi-repo project

| Option | Pros | Cons |
|--------|------|------|
| Sibling — `<workspace_dir>/<name>--<repo-name>/` | No nesting; registry shape untouched | The first path segment is `<name>--<repo-name>`, not the registry name. Both gate hooks and `briefing.sh` attribute a path to a project by that segment, so the per-project ticket marker is missed and the write falls through to the ops-level `current-ticket` — a ticket set for unrelated framework work would then authorise an edit inside a managed repo. Fixing it means a second project-resolution rule inside two trust-chain hooks |
| Nested — non-primary clones inside the primary's working tree | Attributes correctly; no hook change; converting a singular project moves nothing | The primary's tree gains an embedded repo per non-primary: `git status --porcelain` reports `?? <repo>/`, the exact command `/projects` uses for its Dirty column. One `.git/info/exclude` line clears that and also protects the clones from `git clean -ffd`, leaving only `git clean -ffdx` destructive (all measured). The deciding cost is different: `/handover` steps 2–6 read the project directory as one repo root, so a nested repo's files land in the **primary's** harnessability score unless every scan carries an exclusion it does not carry today — silently blending two repos' scores |
| **Container — one clone per repo under a plain project directory** | The first segment is `<name>` for every repo, so both gates and `briefing.sh` attribute correctly with no hook change. Each repo is a self-contained tree, so a per-repo scan cannot blend repos. No embedded repo, so no `git status` pollution and no `git clean` hazard | The multi-repo layout differs from the singular one, and converting an existing singular project means moving its clone down one level and rewriting `workspace:`. Forces two helper changes: `briefing.sh` branch resolution and `mrt_offer_clone`'s clone path |

### 4. Rendering

Settled by the ticket's operator, recorded here because the implementation is
built to it: **one row per project, per-repo detail only on exception
(option C), with an explicit `--by-repo` drill-down (option D)**. Option A
(one summed row) hides which repo is red — the actionable part. Option B
(always per-repo) is complete but noisy at 8 repos across N projects.

## Decision

Chosen, in order:

1. **Parallel per-repo fetch under a concurrency cap.** Each skill's
   existing per-repo commands, run once per repo from `mrt_repos_for`, with
   at most `P` in flight (`portfolio.fetch_concurrency`, default 4; `1` is
   serial). Results are collected and rendered in registry order, so
   parallelism never changes output. **Revisit trigger for GraphQL:** a
   measured `/projects` or `/status` run above 5 s attributable to one
   project's repo count. Adopt it **uniformly** then, in its own ticket,
   with the singular output change declared and asserted.
2. **One shared library, `.claude/hooks/_lib-portfolio-aggregate.sh`**,
   owning the fan-out scheduler, every fold, the stale rule, and the
   exception set. Two rules of its contract: repo enumeration is **not**
   wrapped (skills call `mrt_repos_for` / `mrt_primary_repo_for` directly),
   and there is **no averaging function** — `pa_mean` must never exist,
   because harnessability is rendered per repo and folded worst-of only.
3. **A container directory per project** for `/handover`'s clones:
   `<workspace_dir>/<name>/` holds one clone per repo at
   `<workspace_dir>/<name>/<repo-name>/`, the primary included, and is
   itself a plain directory. `workspace:` names the primary's clone
   explicitly. Singular projects do not move.
4. **Option C by default, option D as `--by-repo`**, with every per-repo
   exception path gated on R ≥ 2 so a singular project renders exactly
   today's strings.

Two supporting calls follow from (3) and are recorded so they are not read
as scope creep: at R ≥ 2 every repo's activity epoch comes from
`gh repo view --json pushedAt`, never a local clone — an unfetched clone is
remote state served from a cache with no TTL, the same failure class option
(1) rejects a TTL cache for. And `portfolio.stale_days` (default 30) is a
**new** threshold; `/projects` has no numeric staleness contract today, so
the value is introduced explicitly rather than presented as existing
behaviour.

## Consequences

- A multi-repo project's row reports the whole product. Counts sum, CI is
  worst-of, activity is newest, contributors are a union, harnessability is
  never averaged.
- Singular `repo:` projects render byte-identically. The R ≥ 2 gate is what
  makes that derivable rather than asserted, and it is asserted at the
  library layer against goldens captured before any skill changes.
- Calls scale with R. At R = 8, `/projects` costs 24 calls per project and
  `/inbox` about 72, bounded in burst by `P` but not in total. The hourly
  budget is the first thing to bind, and that is the same signal as the
  GraphQL revisit trigger.
- Two helpers outside the original surface must change: `briefing.sh`'s
  branch resolution (two bare `[ -d ]` branches would report the enclosing
  repo's branch for a container directory) and `mrt_offer_clone` (it ignores
  the registry's `workspace:`). The second is also a latent fix for any
  singular project with a custom `workspace:`.
- Both gate hooks keep working untouched. That is the property the container
  layout was chosen for, and the reason the sibling layout was rejected.
- **The multi-repo path ships fixture-tested only.** No live multi-repo
  project exists in the reference portfolio, so secondary-rate-limit
  behaviour at `P = 4` across many multi-repo projects, and `/handover`
  end-to-end on a real multi-repo product, are unverified.
- Reversing the container layout later costs adopters a directory move and a
  `workspace:` rewrite. No tracked file records the layout, so a reversal is
  scriptable — and this record is what makes it an argument against evidence
  rather than taste.

## Artifacts

- Ticket: [me2resh/apexyard#1138](https://github.com/me2resh/apexyard/issues/1138)
- Design: [`docs/technical-designs/portfolio-multi-repo-aggregation.md`](../technical-designs/portfolio-multi-repo-aggregation.md)
- PR: [me2resh/apexyard#1205](https://github.com/me2resh/apexyard/pull/1205)
- Builds on: [AgDR-0121](AgDR-0121-multi-repo-registry-project.md)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
