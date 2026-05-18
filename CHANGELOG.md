# Changelog

All notable changes to ApexYard are documented here.

## [1.3.0] — 2026-05-18

### Architecture-doc family + audit persistence + split-portfolio v2 + multi-tracker gate

v1.3.0 adds the **architecture-doc family** — eight new skills that read the codebase and produce maintained design artefacts (`/c4`, `/dfd`, `/process`, `/tech-vision`, `/journey`, `/extract-features`, `/agdr`, plus `/threat-model --format=dragon` for OWASP Threat Dragon export). Audit outputs gain a canonical persistence shape (paired JSON + MD per run, dated subdirs) so trend across runs is finally legible. Split-portfolio mode reaches v2 (private repo absorbs `onboarding.yaml` + `workspace/` alongside the registry). Mechanical enforcement deepens: the ticket-first gate now extends past `gh issue create` to Linear / Jira / Asana / custom trackers (#268), Mermaid blocks are parse-validated at write time (#266), and `/threat-model` inlines the DFD as a point-in-time snapshot so historical audits stay self-consistent (#270).

**9 new skills, 4 new hooks (28 total), 16 new AgDRs** (AgDR-0014 → AgDR-0028, plus AgDR-0030; 0029 is the parked packaging proposal in PR #267).

### Highlights

- **Architecture-doc family** — 8 new read-the-code-and-produce-an-artefact skills:
  - `/c4` (#185 earlier; refined here) — System Context (L1) + Container (L2) Mermaid diagrams
  - `/dfd` (#257) — Data Flow Diagram with trust boundaries + classifications; Mermaid + optional OWASP Threat Dragon v2 JSON. **Single source of truth** that `/threat-model` and `/compliance-check` consume rather than re-deriving (AgDR-0026)
  - `/process` (#256) — Anchor-scoped, reachability-bounded BPMN 2.0 extraction across 7 process-discovery axes; lint-clean BPMN that opens in Camunda Modeler
  - `/tech-vision` (#246) — Interactive section-by-section author for the architecture vision template — Scope / Principles / Target-state / Current-vs-Target gap table / multi-quarter Migration / explicit Anti-scope / Review cadence (AgDR-0028)
  - `/journey` (#179) — Single self-contained HTML user-journey map; clickable modal-per-page graph (AgDR-0016)
  - `/extract-features` (#249) — Six-axis Feature Inventory for greenfield rewrites
  - `/agdr` (#181) — Searchable, categorised library across the portfolio (browse / search / show / stats)
  - `/threat-model --format=dragon` (#255) — OWASP Threat Dragon v2 JSON export (AgDR-0024)
- **Audit-artefact persistence** (#218, AgDR-0019) — paired JSON + MD per run, `projects/<name>/audits/<dim>/<ts>.md` canonical path, shared lib `_lib-audit-history.sh` with 4 functions. Backfilled across all 10 audit skills (#221). Backward-compatible with `/launch-check`'s pre-existing JSON history (read both, write only to new).
- **Split-portfolio v2** (#242, AgDR-0021) — moves `onboarding.yaml` AND `workspace/<name>/` to the private sibling repo (was: only registry + projects). Public fork now holds only framework files + your customisations to skills/hooks/rules. Migration path automated via extended `/update`.
- **Private repo houses company custom skills + cross-org handbooks** (#243, AgDR-0022) — adopters drop proprietary slash commands at `custom-skills/<name>/SKILL.md` + company-confidential coding standards at `custom-handbooks/{architecture,general,language/<lang>}/*.md`. Discovered via SessionStart-hook symlinks (skills) + Rex's dual-glob (handbooks).
- **Custom templates layer** (#244, AgDR-0023) — path-mirror override semantics. Drop your version at `<private_repo>/custom-templates/<path>` and it wins over the framework default. Every template-consuming skill routes through `portfolio_resolve_template`.
- **Adopter handbooks consumed by Rex** (#232, AgDR-0020) — `handbooks/{architecture,general,language/<lang>}/*.md` discovered by path-convention; advisory by default, opt in to blocking via `ENFORCEMENT: blocking` marker.
- **Skill-gated ticket-create hook** (#268, AgDR-0030) — `PreToolUse:Bash` matcher blocks raw `gh issue create` (and Linear / Jira / Asana shapes) unless one of the 7 structured ticket skills is in flight. Tracker-agnostic by construction; adopters extend the matcher list via project-config for their tracker.
- **`/threat-model` inlines DFD as snapshot at audit time** (#270) — historical threat models stay internally consistent after the live DFD evolves. Refuses if no DFD exists (was: degraded fallback). Inlined output passes through `_lib-mermaid-lint.sh`.
- **Mermaid lint per emitting skill** (#266) — `_lib-mermaid-lint.sh` + thin per-skill wrappers under `/c4`, `/dfd`, `/tech-vision`. Catches broken Mermaid at write time, not when a human opens the file on GitHub. Graceful Node-missing degrade per the `/process/lint.sh` pattern.
- **Architecture page on the marketing site** (#271) — `site/architecture.html` shows the canonical 5-layer mental model + optional split-portfolio sibling repo. Diagram recoloured to the site's terminal-native brutalism palette with muted info-graphic hues per layer.
- **Investigation skill + template** (#245, AgDR-0027) — sustained root-cause work (incident retros, bug archaeology, regression hunts, performance mysteries, competitive analyses). Hypothesis-tree methodology, live-doc workflow. Distinct from `/spike` (forward-looking with budget) and `/bug` (immediate-fix). Closes when every follow-up action lands.
- **Spike skill + close gate** (#180, AgDR-0017) — hypothesis-driven, time-boxed, throw-away exploration. Spike PRs exempt from AgDR + 80% coverage gates; Rex + security auditor still apply. `/spike-close --promote` files a follow-up `[Feature]`; `/spike-close --discard` writes a memo.
- **Role-trigger detection** (#206) — mechanical advisory hook injects a "role X should activate for this work" reminder when triggers fire. Plus role-activation visibility markers convention (#205) and Arabic persona names across all 19 roles (#204, AgDR-0018).
- **Plan-mode usage rule** (#219) — when to enter plan mode (multi-step coordination, unclear path, hard-to-reverse action upcoming, validating a `/fan-out` split). Self-discipline rule with no mechanical backstop (harness-owned).
- **Architecture templates** (#224) — vision, DFD, and sequence-diagram templates added to `templates/architecture/`.
- **Pre-release sync mode** (#250) — `/update --from-dev` pulls from `upstream/dev` instead of latest tag. Hidden flag; not a supported general-adopter path.

### Added

- `feat(#181)` `/agdr` — searchable, categorised AgDR library across the portfolio (#186)
- `feat(#179)` `/journey` — single-file user-journey HTML with modal-per-page (#200)
- `feat(#180)` `/spike` — hypothesis-driven throw-away ticket type (#202)
- `feat(#245)` `/investigation` — structured ticket + live-doc for sustained root-cause work (#262)
- `feat(#246)` `/tech-vision` — interactive section-by-section architecture-vision author (#263)
- `feat(#249)` `/extract-features` — six-axis Feature Inventory for greenfield rewrites (#252)
- `feat(#256)` `/process` — anchor-scoped, reachability-bounded BPMN 2.0 extraction (#259)
- `feat(#257)` `/dfd` — Data Flow Diagram with trust boundaries + classifications (#260)
- `feat(#255)` `/threat-model --format=dragon` — OWASP Threat Dragon v2 JSON export (#258)
- `feat(#266)` Mermaid lint per emitting skill (`/c4`, `/dfd`, `/tech-vision`) — shared `_lib-mermaid-lint.sh` + thin per-skill wrappers (#269)
- `feat(#268)` Skill-gated ticket-create hook — multi-tracker matcher list, bootstrap exemption, env-var escape hatch (#276)
- `feat(#270)` `/threat-model` inlines DFD as point-in-time snapshot at audit time; refuses if no DFD exists (#273)
- `feat(#271)` `site/architecture.html` — 5-layer diagram recoloured to site palette (#272)
- `feat(#218)` Audit-skill artefact persistence + canonical structure — paired JSON+MD, shared `_lib-audit-history.sh` (#222)
- `feat(#242)` Split-portfolio v2 — `workspace/` + `onboarding.yaml` move to private sibling repo (#248)
- `feat(#243)` Private repo houses company custom skills + cross-org handbooks (#253)
- `feat(#244)` Custom templates layer with override semantics (#251)
- `feat(#232)` Adopter handbooks consumed by Rex during code review (#233)
- `feat(#250)` `/update --from-dev` — hidden flag for pre-release sync (#254)
- `feat(#208)` `/setup` auto-enables LSP — language detection + install + env var + plugin (#210)
- `feat(#206)` Mechanical role-trigger detection — non-blocking reminder injection (#209)
- `feat(#205)` Role-activation visibility markers convention (#213)
- `feat(#188)` `/handover` offers clone-first deep-dive prompt (#192)
- `feat(#182)` `/status --briefing` + `bin/apexyard status` CLI shim (#187)
- `feat(#177)` `/update` detects deprecated config keys + offers cleanup (#199)
- `feat(#183)` `/launch-check` trend tracking (#185)
- `feat(#224)` Architecture vision + DFD + sequence templates (#226)

### Fixed

- `fix(#275)` `require-design-review-for-ui.sh` false-positives on non-UI `.jsx` files — additive `ui_paths_exclude` carve-out (#277)
- `fix(#227)` Greedy body extractor — no more truncation at embedded quotes (#264)
- `fix(#229)` Align merge gates + agent + skill on ops-fork marker path (#240)
- `fix(#207)` `verify-commit-refs` + `validate-pr-create` consult upstream remote (#211)
- `fix(me2resh/apexyard#194)` Validation hooks read git context from command, not `$PWD` (#198)

### Changed

- `refactor(#204)` Every role + agent gets an Arabic persona name (#212, AgDR-0018)
- `chore(#221)` Retrofit 7 audit skills onto `_lib-audit-history.sh` (#239)
- `chore(#223)` Add Data Flow Diagram section to threat-model template (#225)
- `chore(#215)` `/setup` emits verified LSP plugin-install commands (#216)
- `chore(#168)` Accept `release/vN.N.N` branches + `release(...)` PR titles (#169)
- `chore(#170)` Exempt `release/vN.N.N` from `validate-pr-create`'s branch-id check (#171)

### Docs

- `docs(#219)` Plan-mode usage rule — when to enter (#220)
- `docs(#189)` Document `ENABLE_LSP_TOOL` opt-in + per-language LSP plugin install (#193)
- `docs(#190)` Annotate LSP-aware skills with opt-in callouts (#191)

### Spikes (closed, memo'd)

- `spike(#241)` `/learn` feasibility — dry-run report (#247)
- `docs(#197)` Claude tier-routing spike — measurement + recommendation (#201)
- `docs(#195)` Local-model routing spike — measurement + recommendation (#196)
- `docs(#178)` LSP integration spike — measurement + recommendation (#184)

### AgDRs (new)

- `AgDR-0014` Launch-check trend tracking
- `AgDR-0015` Command-context-over-PWD in hooks
- `AgDR-0016` Journey HTML rendering
- `AgDR-0017` Spike-skill schema + exemptions
- `AgDR-0018` Persona-naming convention
- `AgDR-0019` Audit-artefact persistence (paired JSON+MD, shared lib API)
- `AgDR-0020` Adopter handbooks for Rex
- `AgDR-0021` Split-portfolio v2 path resolution
- `AgDR-0022` Private custom-skills + handbooks name-collision semantics
- `AgDR-0023` Custom-templates override semantics (path-mirroring)
- `AgDR-0024` Threat Dragon export
- `AgDR-0025` Process-skill BPMN + discovery
- `AgDR-0026` DFD-skill as source of truth (consumed by `/threat-model` + `/compliance-check`)
- `AgDR-0027` Investigation skill + template
- `AgDR-0028` Tech-vision skill design
- `AgDR-0030` Skill-gated ticket-create (mirror of bootstrap-exemption pattern)

### Notable behaviour changes

- **`gh issue create` (and Linear / Jira / Asana equivalents) now require a structured ticket skill in flight.** The `require-skill-for-issue-create.sh` hook blocks raw ticket-create CLIs unless `.claude/session/active-issue-skill` is present. The 7 ticket skills (`/task`, `/feature`, `/bug`, `/spike`, `/migration`, `/investigation`, `/idea`) write the marker on entry and clean it on exit. Operator escape hatch: `APEXYARD_ALLOW_RAW_TICKET_CREATE=1`. See AgDR-0030.
- **`/threat-model` refuses to run if `dfd.md` is missing** (was: degraded "inline discovery" fallback). The audit artefact now inlines a DFD snapshot at audit time — historical threat models survive subsequent DFD changes. Re-run `/threat-model` to refresh the snapshot.
- **Split-portfolio adopters: v1 → v2 migration via `/update`.** `/update` detects the v1 layout (only registry + projects/ in the sibling) and offers (default-yes) to move `onboarding.yaml` + `workspace/` to the sibling too. Per-file-class confirmable; idempotent; non-destructive (stages but doesn't commit). See `docs/multi-project.md` § "Migrating from split-portfolio v1 to v2".
- **Audit outputs now live at `projects/<name>/audits/<dim>/<ts>.md`** (paired with `runs/<ts>.json`). `/launch-check`'s legacy `projects/<name>/launch-check/runs/` path is read-merged, not migrated. Adopters can `mv` the old dir when convenient.
- **Mermaid blocks now linted at write time** in `/c4`, `/dfd`, `/tech-vision`. First run pulls `@mermaid-js/mermaid-cli` via `npx`; graceful degrade with exit 3 + advisory message when Node is unavailable. Pass `--skip-lint` to bypass.

## [1.2.0] — 2026-05-04

### Mechanical-enforcement hardening + portfolio polish + landing-site refresh

v1.2.0 doubles down on apexyard's "rule-as-code, not advisory prose" thesis. Nine new hooks plus two upgrades wire the SDLC's safety claims tighter to the runtime; four new skills (`/debug`, `/validate-idea`, `/tickets-batch`, `/fan-out`) extend the operator surface; portfolio mode ships a first-class config block plus a destructive-migration helper; and the landing site picks up a multi-tab terminal demo, a full skills reference page, and a permanent changelog link.

Two adopter-visible behaviour changes worth reading before you sync — the `/approve-merge` flow now auto-merges in the same turn (with a structured marker that's harder to forge), and `Bash` file writes (`echo > file`, `tee`, `python -c '...write_text...'`, etc.) are now gated by the same ticket-first hook that already covered `Edit` / `Write` / `MultiEdit`. See "Notable behaviour changes" below.

### Highlights

- **Bootstrap-skill exemption + Bash-write coverage** close the ticket-first gate's two known failure modes (#150 + #151, AgDR-0011)
- **`/approve-merge` hardened + streamlined** — structured CEO marker prevents `echo SHA > file` bypass; default flow auto-merges in the same turn (#132 + #48, AgDR-0012)
- **Portfolio mode polish** — `portfolio:` config block, `/split-portfolio` migration helper, self-healing path resolution (#143 + #145, AgDR-0010)
- **Four new skills** — `/debug` (structured hypothesis-driven debugging), `/validate-idea` (pre-spec gate), `/tickets-batch` (bulk-file flow), `/fan-out` (parallel agents)
- **Release-cut branch model adopted** — framework now uses `dev` for daily PRs, `main` for release tags only (#116, AgDR-0007)
- **Landing site refresh** — multi-tab terminal demo (`one ticket / /handover / /setup / /fan-out`), full 39-skill reference page at `/skills.html`, persistent `changelog →` link in the nav

### Added

- `feat(#108)` `/tickets-batch` — bulk-file 5–20 structured tickets in one flow with shared-context micro-interview (#127)
- `feat(#117)` `/fan-out` — spawn N parallel `Agent` calls in one assistant message, optional worktree isolation, foreground / background mode (#128)
- `feat(#130)` `/validate-idea` — lightweight 5-question pre-spec gate (#131)
- `feat(#141)` `/debug` — structured hypothesis-driven debugging that forces architecture-first reading and evidence-before-fix (#142)
- `feat(#145)` Portfolio config block (`portfolio.{registry,projects_dir,ideas_backlog}`) + self-healing SessionStart banner + `/split-portfolio` migration helper (#147, AgDR-0010)
- `feat(#150)` Bootstrap-skill exemption — `/setup`, `/handover`, `/update`, `/split-portfolio` write `.claude/session/active-bootstrap` markers; `require-active-ticket.sh` exempts them. Plus Bash-write coverage in `require-active-ticket.sh` and `require-migration-ticket.sh` (#152, AgDR-0011)
- `feat(#132)` `/approve-merge` writes a structured CEO marker (`sha=`, `approved_by=user`, `skill_version=2`) AND runs `gh pr merge --squash --delete-branch` in the same turn by default; `--no-merge` opt-out preserves the deferred case; bare-SHA legacy markers rejected by the merge gate (#158, AgDR-0012)
- `feat(#160)` Multi-tab terminal demo on the landing site — four flows (`one ticket`, `/handover`, `/setup`, `/fan-out`) with auto-advance + click-to-jump (#162)
- `feat(#165)` Skills reference page at `site/skills.html` covering all 39 skills + permanent `changelog →` link in the homepage nav (#167)

### Fixed

- `fix(#106)` CHANGELOG fallback in upstream-drift hook for squash-merged forks (#129)

### Changed

- `chore(#107)` `validate-issue-structure.sh` PreToolUse hook — issue-body schema verified at create time (#122)
- `chore(#109)` Project-configurable ticket / branch / commit / PR schema in `.claude/project-config.{defaults,}.json` (#118)
- `chore(#110)` `block-private-refs-in-public-repos.sh` — leak protection on outgoing PR / issue / comment bodies (#119)
- `chore(#111)` `pre-push-gate` upgraded from advisory reminder to blocking check-runner (#121)
- `chore(#112)` `require-agdr-for-arch-pr.sh` — flag arch-class PRs that don't link an AgDR (#123)
- `chore(#113)` `## Testing` section now required in PR body, project-configurable (#124)
- `chore(#114)` Single `Closes #N` keyword per PR body enforced (#125)
- `chore(#115)` `warn-stale-review-markers.sh` PostToolUse hook — surfaces stale review markers after pushes (#120)
- `chore(#116)` Release-cut branch model — `dev` for daily PRs, `main` for release tags only. Framework-only; managed projects stay trunk-based (#126, AgDR-0007)
- `chore(#153)` Extended Bash-write matcher beyond first-version coverage — additional patterns for archive / network / interpreter shapes (#155)
- `chore(#163)` Default the split-portfolio sibling repo name to `<fork>-portfolio` (e.g. `your-org/apexyard-portfolio`) instead of generic `your-org/ops` (#164)
- `chore(#77)` Hook + skill counts in `CHANGELOG.md` and `CLAUDE.md` corrected to current reality (24 hooks, 39 skills) (#161)
- `chore(#168)` `validate-branch-name.sh` now recognises the `release/vN.N.N(-rcN)?` pattern as a valid branch name; `release` added to `pr.title_type_whitelist` so a PR title `release(#160): v1.2.0` passes the validator (#169)
- `chore(#170)` `validate-pr-create.sh`'s independent branch-id check now also exempts `release/vN.N.N` (completes the #168 fix) (#171)

### Tests

- `test(#154)` Mock `gh` in test sandboxes — removes live-tracker dependency from `test_single_closes_per_pr.sh` and `test_validate_pr_required_sections.sh` (#156)

### Docs

- `docs(#143)` Document split-portfolio mode (public framework + private sibling portfolio) + add the `/setup` privacy gate (#144)
- `docs(#148)` Correct privacy-gate wording — adopter action, not framework auto-publish (#149)

### Notable behaviour changes (read before upgrade)

1. **`/approve-merge` auto-merges by default.** The skill now writes the CEO marker AND runs `gh pr merge --squash --delete-branch` in the same turn. Use `/approve-merge <pr> --no-merge` to preserve the old "stop after marker" flow. AgDR-0012 has the rationale.
2. **Legacy bare-SHA CEO markers are rejected.** Any in-flight `<pr>-ceo.approved` written by the pre-#48 skill must be re-issued via `/approve-merge` (one re-run per stale marker). The new format is structured key/value (`sha=`, `approved_by=user`, `skill_version=2`).
3. **Bash file writes are gated.** `echo > file`, `tee`, `sed -i`, `python -c '...write_text...'`, `node -e '...writeFileSync...'`, `ruby -e '...File.write...'` now hit `require-active-ticket.sh` / `require-migration-ticket.sh` when no ticket is active. Bootstrap skills get an exemption via the active-bootstrap marker.
4. **PR body must include `## Testing` section.** PR creation is blocked otherwise. Override via `.claude/project-config.json` → `pr.required_sections` if your team uses different conventions.
5. **Single `Closes #N` per PR body / commit message.** Multi-Closes is blocked. Use `Refs #N` for cross-references; release PRs use the `<!-- multi-close: approved -->` skip marker.
6. **Release-cut branch model.** The framework's `main` now only receives release PRs from `dev`. Adopter forks stay trunk-based on `main`.

### Stats

- **24 hooks** wired in `.claude/settings.json` (up from 18 in v1.1.0)
- **39 skills** available as slash commands (up from 35 in v1.1.0)
- **10 modular rule files** in `.claude/rules/`
- **13 AgDRs total** (AgDR-0006 through AgDR-0013 — eight new AgDRs added in this cycle)
- **Test coverage**: 196+ cases across 12 hook test files

### Migration notes

- **Stale CEO markers** — re-run `/approve-merge` on any in-flight PR with a pre-#48 marker. One re-run each.
- **Custom `/approve-merge` invocation** — if you customised the skill to skip the merge, pass `--no-merge` to preserve that behaviour.
- **PR body templates** — make sure your local templates include `## Testing` and `## Glossary` sections (the two `pr.required_sections` enforced by `validate-pr-create.sh`; `## Summary` is conventional but not validator-enforced). See [`pr-quality.md`](.claude/rules/pr-quality.md).
- **Bash bypass paths** — any tooling that relied on `echo > file` to circumvent the ticket-first gate now needs a real active ticket via `/start-ticket`. Bootstrap skills (`/setup`, `/handover`, `/update`, `/split-portfolio`) are exempt automatically.

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
- **18 hooks** wired in `.claude/settings.json` (up from 15 in v0.2).
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
