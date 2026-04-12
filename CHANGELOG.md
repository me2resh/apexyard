# Changelog

All notable changes to ApexStack are documented here.

## [0.2.0] — 2026-04-12

### Mechanical enforcement layer

ApexStack's SDLC rules are no longer advisory prose — they're mechanically enforced by shell hooks that the Claude Code harness executes on every tool call.

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

ApexStack now runs its own CI:
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

ApexStack — a multi-project forge for Claude Code. Fork it, register your projects, and every managed repo gets shared memory, strict SDLC gates, and 19 role definitions that activate automatically.

- 19 role definitions across 5 departments (engineering, product, design, security, data)
- Workflows: SDLC, code review, deployment
- Templates: PRD, technical design, ADR, AgDR
- 6 enforcement hooks (block git-add-all, block main push, validate branch name, check secrets, pre-push gate, validate PR create)
- 13 slash-command skills (/decide, /code-review, /security-review, /audit-deps, /write-spec, /idea, /handover, /projects, /inbox, /status, /tasks, /roadmap, /stakeholder-update)
- 5 agents (code reviewer, security reviewer, dependency auditor, PR manager, ticket manager)
- 7 golden-path CI pipeline templates
- Fork-first install model (no submodules, no symlinks)
- Multi-project portfolio registry (`apexstack.projects.yaml`)
- `onboarding.yaml` for company configuration
- Landing page at `site/index.html`
