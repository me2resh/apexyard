# Changelog

All notable changes to ApexYard are documented here.

## [1.1.0] — 2026-04-19

### Tag-based upstream drift detection

The SessionStart drift banner and the `/update` skill now treat a **new upstream release (tag)** as the actionable signal, not every single commit on `upstream/main`. Small upstream work (README typos, CI tweaks, docs-only PRs) stops nagging every downstream fork.

### Why

Each commit to `me2resh/apexyard:main` used to trigger every fork's banner with "N commits behind upstream/main. Run /update". For a framework repo with many forks, that's noise — it trains people to tune out the banner and miss real releases. The fix: make the banner fire only when there's a new tag.

### What changed

- **`check-upstream-drift.sh`** — now compares the latest upstream tag (sorted by semver, `--merged upstream/main`) against the fork's latest merged tag. If they differ, the banner names the release: `ApexYard: v1.1.0 available. Run /update to sync.` Same tag → silent, even if `upstream/main` has unreleased commits.
- **`/update` skill** — preview now distinguishes "new release available" (default **yes** to sync) from "unreleased main commits, no tag drift" (default **no** — typically docs/CI noise the user can ignore).
- **Fallback** — if upstream has never been tagged (brand-new project, pre-release), the hook falls back to the previous commit-count behaviour so early-stage forks still get useful signal.

### Migration notes

- **No config to change.** Tag-based is the new default; no opt-in or opt-out flag to set.
- **First session on v1.1.0** — the banner will name the first upstream tag higher than your fork's last merged tag.
- **Forks with never-merged-a-tag history** — fall through to the commit-count fallback on the first run, then the tag-based path after they sync once.
- **Cache interaction**: existing installs may have a `.claude/session/last-upstream-fetch` file from pre-1.1.0. That cache still applies — so the first v1.1.0 session may wait up to 10 minutes before the new `--tags` fetch runs. Force an immediate re-check with `rm .claude/session/last-upstream-fetch`.

## [1.0.0] — 2026-04-18

### Rebrand: ApexStack is now ApexYard

The project has been renamed from **ApexStack** to **ApexYard**. Same framework, same people, same license, same philosophy — only the name changed.

### Why

Pre-launch trademark research surfaced conflicts with the original name in the software class. Rather than fight them, we picked a new name that clears UK IPO, USPTO, and EUIPO in the relevant classes. **ApexYard** also pairs cleanly with the existing `ApexScript` consultancy brand — ApexScript is the playbook, ApexYard is the yard where projects get built and governed.

### Migration notes

- **Repo rename:** `me2resh/apexstack` → `me2resh/apexyard`. GitHub preserves redirects so old URLs keep working, but update your `upstream` remote at your leisure:

  ```bash
  git remote set-url upstream https://github.com/me2resh/apexyard.git
  ```

- **Registry file rename:** `apexstack.projects.yaml` → `apexyard.projects.yaml`. The `.example` renamed too. Anyone with an existing ops fork should rename their local copy in the same commit as their next `git pull upstream main`.

- **Email contact:** `hello+apexstack@me2resh.com` → `hello+apexyard@me2resh.com`. Both plus-aliases are monitored; prefer the new one going forward.

- **Command interfaces are unchanged.** Every skill (`/handover`, `/update`, `/decide`, `/c4`, etc.), hook, agent, and rule keeps the same name, arguments, and behaviour. No code changes outside text / filenames.

- **Prior releases (v0.1.0, v0.2.0, v0.3.0)** were shipped under the ApexStack name. Their git tags stay intact as the historical record. CHANGELOG prose below has been retro-renamed to ApexYard for reader consistency; if you need the name as-shipped at the time, check the release on GitHub by tag.

### What's in v1.0.0 (beyond the rename)

Nothing functional. Deliberately scoped to name-only changes so the upgrade is safe to merge without reviewing any logic. Any feature work since v0.3.0 lives in separate PRs.

### Upgrade effort

- Local fork: `git pull upstream main` + rename your `apexstack.projects.yaml` to `apexyard.projects.yaml`. Done.
- No data migration. No config migration. No skill / hook interface changes.

---

## [0.3.0] — 2026-04-18

### Multi-project comes alive

v0.2 made forking apexyard the supported install path. v0.3 makes the **multi-project workflow** that fork enables actually work end-to-end: per-project context for the hooks, an upstream-drift signal at session start, and a one-command sync skill so keeping the fork current isn't archaeology.

- **Per-project active-ticket markers** (#41) — `require-active-ticket.sh` now resolves the active ticket per-project (one marker per `workspace/<name>/`), so working in two project clones in the same session no longer cross-contaminates ticket state.
- **`/update` skill** (#58) — sync the ops fork with `me2resh/apexyard` from one prompt: previews the commit delta, creates a sync branch (because direct push to main is blocked), merges or rebases, walks per-file conflicts, and leaves the branch ready to push as a PR.
- **SessionStart drift banner** (#63) — `check-upstream-drift.sh` runs at session start (cached to once per 10 minutes), prints a one-line banner when your fork is behind. Silent if up-to-date, silent on network failure, silent when no `upstream` remote is configured.

### Architecture diagrams as a first-class artefact

- **Mermaid C4 templates** (#50) — Level 1 (System Context) and Level 2 (Container) templates at `templates/architecture/`. ApexYard itself dogfoods the convention at `docs/architecture/apexyard-context.md` and `apexyard-container.md`.
- **`/handover` generates a stub C4 L2 container diagram** (#67) — onboarding an external repo now seeds a starter Mermaid diagram alongside the assessment, so new projects don't begin with an empty `docs/architecture/`.
- AgDR-0003 captures the choice of Mermaid C4 over Structurizr DSL / PlantUML / D2 — GitHub renders Mermaid inline, zero build step, no proprietary tooling.

### Database migrations get their own gate

Migrations are high-blast-radius work that sit awkwardly inside the standard build flow: rollback plans, downtime windows, lock contention, and cross-service consumers are easier to spec **before** the SQL is written than during PR review.

- **`require-migration-ticket.sh` hook** (#59) — fires on `Edit` / `Write` / `MultiEdit` against migration paths (`**/migrate-*.{ts,js,py,sql}`, `**/migrations/**`, `prisma/schema.prisma`, etc.). Verifies the active ticket has the `migration` label and references a migration AgDR. Project-config-overridable.
- **`/migration` skill** — guided flow that asks for migration type, affected tables, rollback plan, downtime estimate, cross-service consumers, data volume, testing plan, and observability — then creates the labelled ticket AND writes the AgDR in one step.
- **`templates/agdr-migration.md`** — migration-specific AgDR template that prompts for the rollback steps, the tested-against environment, and the consumers that need a pre-deploy heads-up.
- **Workflow gate 3a** added to `.claude/rules/workflow-gates.md`.

### Site refresh

- **Whole-framework positioning** (#73) — `site/index.html` retired the v0.1-era "rules + hooks" framing and now leads with the multi-project / portfolio model, the SDLC walkthrough, and the role-activated workflow as the headline.

### Hook robustness

- **`gh api .../merge` bypass closed** (#47) — all three merge-gate hooks now match both `gh pr merge` and the raw REST shape `gh api repos/.../pulls/N/merge`. Discovered after `me2resh/curios-dog#190` was merged via `gh api` while CI was still running. The shared PR-number extractor at `.claude/hooks/_lib-extract-pr.sh` recognises both forms.
- **Absolute-path exemptions in `require-active-ticket.sh`** (#56) — `/docs/`, `/projects/<name>/docs/`, and `*.md` paths are now exempt regardless of whether they're passed as relative or absolute. Closes a class of false-positive blocks when an editor passed absolute paths.
- **Rex marker format enforcement** (#62 → fix #66) — the code-reviewer agent definition now requires markers to be a bare 40-character SHA + newline. Earlier informal formats (`PR: 61\nSHA: ...`) silently broke the merge gate.
- **Merge gates resolve PR HEAD via `gh pr view`** — earlier hooks compared marker SHAs against `git rev-parse HEAD` (the local working tree), which forced a `gh pr checkout` dance before every merge. The hooks now resolve the PR's real HEAD on GitHub and fall back to local HEAD only with a visible warning when the gh call fails.
- **Reject closed-issue refs in PR + commit hooks** — `validate-pr-create.sh` and `verify-commit-refs.sh` now reject titles / commit messages referencing closed issues, not just non-existent ones.
- **Hooks resolve ops root from any workspace directory** — every hook now walks up from `$PWD` looking for `onboarding.yaml`, so they fire correctly when invoked from `workspace/<name>/` (the most common case in multi-project work).

### New skills

- `/migration` — guided migration ticket + AgDR creation (see migrations section above).
- `/update` — fork sync (see multi-project section above).
- `/feature`, `/bug`, `/task` — structured ticket templates with user-story / Given-When-Then / driver-scope-ACs scaffolds.

### Stats

- **17 commits** on `main` since v0.2.0 (9 features, 8 fixes), all PR-merged.
- **17 hooks** wired in `.claude/settings.json` (up from 15 in v0.2).
- **32 skills** available as slash commands (up from 27 in v0.2).
- **9 modular rule files** in `.claude/rules/` (unchanged).

### Upgrade notes

- `apexyard.projects.yaml` is unchanged from v0.2 — your registry continues to work.
- The new migration gate (`require-migration-ticket.sh`) is a no-op for projects that don't touch migration paths. If you have non-default migration locations, override `migration_paths` in `.claude/project-config.json`.
- The new `check-upstream-drift.sh` runs on every session start. It will be silent unless your fork is behind upstream — no action needed unless you see the banner. To skip the upstream check entirely, remove the SessionStart entry from `.claude/settings.json`.

---

## [0.2.0] — 2026-04-12

### Mechanical enforcement layer

ApexYard's SDLC rules are no longer advisory prose — they're mechanically enforced by shell hooks that the Claude Code harness executes on every tool call.

**15 hooks** (up from 6 in v0.1):

- `require-active-ticket.sh` — blocks code edits without an active ticket
- `auto-code-review.sh` — auto-invokes the code-reviewer agent after PR creation
- `block-unreviewed-merge.sh` — two-marker merge gate (Rex + CEO approval required, both SHAs must match HEAD)
- `onboarding-check.sh` — prompts `/setup` on unconfigured forks
- `verify-commit-refs.sh` — blocks commits referencing non-existent issues
- `validate-commit-format.sh` — enforces conventional commit format (with project-config override)
- `require-agdr-for-arch-changes.sh` — requires AgDR when architecture files change
- `require-design-review-for-ui.sh` — blocks merge on UI PRs without design approval
- `block-merge-on-red-ci.sh` — blocks merge when any CI check is failing or pending
- `validate-branch-name.sh` — **now blocks** (was warning-only in v0.1)
- `validate-pr-create.sh` — **now blocks** on format errors + verifies referenced issues exist
- `block-git-add-all.sh` — blocks `git add -A / . / --all` (unchanged from v0.1)
- `block-main-push.sh` — blocks push to main/master (unchanged)
- `check-secrets.sh` — scans for hardcoded secrets (unchanged)
- `pre-push-gate.sh` — reminds to run CI checks locally (unchanged)

### New skills

**27 skills** (up from 13 in v0.1):

- `/setup` — first-run bootstrap: "describe your stack, accept defaults, done in 3 exchanges"
- `/start-ticket` — declare an active ticket before coding (required by the ticket-first hook)
- `/approve-merge` — record per-PR CEO approval (required by the merge gate)
- `/approve-design` — record per-PR design-review approval (required for UI PRs)
- `/launch-check` — 8-dimension production readiness audit at milestone boundaries (go/conditional-go/no-go verdict)
- `/threat-model` — STRIDE threat modelling exercise
- `/accessibility-audit` — WCAG 2.1 AA compliance audit
- `/compliance-check` — GDPR + ePrivacy analysis
- `/analytics-audit` — event taxonomy and funnel coverage
- `/seo-audit` — technical SEO against Google best practices
- `/performance-audit` — bundle and Core Web Vitals analysis
- `/monitoring-audit` — observability and incident readiness
- `/docs-audit` — Diataxis documentation framework audit
- `/onboard` — deprecated, redirects to `/setup` (framework) and `/handover` (project)

### New rules

- `ticket-vocabulary.md` — reserves "Ticket", "#N", and dependency notation for real GitHub issues only. Prevents the vocabulary-collision failure mode where planning items wearing tracker notation are mistaken for tracker state.

### Agent Decision Records

- `AgDR-0001` — rule mechanization: which hooks to ship, which paths count as architecture/UI, which rules stay advisory
- `AgDR-0002` — warning-to-blocker upgrade for branch-name and PR-title validation

### CI dogfooding

ApexYard now runs its own CI:

- `pr-title-check.yml` — enforces ticket ID in PR titles
- `markdown-lint.yml` — lints all markdown files
- `shellcheck.yml` — static analysis on all hook scripts
- `link-check.yml` — validates URLs in docs and landing page (with weekly cron)

### Documentation

- `docs/rule-audit.md` — 73-row audit table mapping every MUST/NEVER/HARD-STOP rule to its enforcement mechanism (mechanized / partial / advisory / deferred)
- `.claude/hooks/README.md` — comprehensive documentation of all 15 hooks, session-state directory, testing instructions, and how to add new hooks
- Updated CLAUDE.md with all 27 skills, 15 hooks, and the explicit per-merge approval rule

### Breaking changes

- `validate-branch-name.sh` now **blocks** non-conforming branch names (was warning-only in v0.1)
- `validate-pr-create.sh` now **blocks** malformed PR titles, missing glossary, and missing branch ticket IDs (was warning-only in v0.1). Also blocks when the title's issue number doesn't exist in the tracker.
- `/onboard` skill is deprecated — use `/setup` for framework configuration, `/handover` for project onboarding
- `onboarding-check.sh` now checks `onboarding.yaml` for placeholder values instead of a gitignored session marker. Existing `.claude/session/onboarded` markers are no longer read.

### Key design principles introduced in v0.2

- **Prose rules the model drops under pressure → mechanical hooks.** If a rule is important, put it in a hook (exit 2 blocks the action). If it's a preference, put it in a rule file. If it's context, put it in CLAUDE.md.
- **Plan-level "go" is NOT merge approval.** Every `gh pr merge` requires its own per-PR, per-action explicit nod. Mechanically enforced by the two-marker merge gate.
- **Tracker vocabulary is reserved.** "Ticket", "#N", and dependency notation refer only to real GitHub issues. Planning items use "Step N" / "Item A" / plain bullets.
- **Describe, propose, confirm.** The `/setup` first-run UX collapses 7 sequential questions into 3 exchanges.
- **Overview → deep dive.** `/launch-check` is the 30-second sweep; each dimension has a dedicated expert skill for investigation.

---

## [0.1.0] — 2026-04-09

### Initial release

ApexYard — a multi-project forge for Claude Code. Fork it, register your projects, and every managed repo gets shared memory, strict SDLC gates, and 19 role definitions that activate automatically.

- 19 role definitions across 5 departments (engineering, product, design, security, data)
- Workflows: SDLC, code review, deployment
- Templates: PRD, technical design, ADR, AgDR
- 6 enforcement hooks (block git-add-all, block main push, validate branch name, check secrets, pre-push gate, validate PR create)
- 13 slash-command skills (/decide, /code-review, /security-review, /audit-deps, /write-spec, /idea, /handover, /projects, /inbox, /status, /tasks, /roadmap, /stakeholder-update)
- 5 agents (code reviewer, security reviewer, dependency auditor, PR manager, ticket manager)
- 7 golden-path CI pipeline templates
- Fork-first install model (no submodules, no symlinks)
- Multi-project portfolio registry (`apexyard.projects.yaml`)
- `onboarding.yaml` for company configuration
- Landing page at `site/index.html`
