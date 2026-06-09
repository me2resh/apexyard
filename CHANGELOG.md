# Changelog

All notable changes to ApexYard are documented here.

## [3.1.4] — 2026-06-09

Patch release — game polish.

### Fixed

- (#619) game (`site/game.html`): outro footer no longer points players at LangGraph / unrelated tools — repointed to ApexYard's "Loop Engineering" read + yard.apexscript.com; fixed stale intro copy/chips missed when the 11th level landed ("Ten quick rounds" → "Eleven … loop engineering last", added the "Loops" chip); added a dedicated game OG share card (`site/og/game.png`, 1200×630) and pointed `og:image`/`twitter:image` at it instead of the generic site OG (cb701c7)

### Closes

- Closes #619

## [3.1.3] — 2026-06-09

Patch release — game scoring fix.

### Fixed

- (#614) game (`site/game.html`): total score could exceed the 1100 max (share text showed "1188/1100"). `level1` and `levelTemp` called `addScore()` per round but recorded only the per-level average; `levelTemp` also double-divided, capping it at ~33. Each level now adds its 0–100 once — total maxes at 1100 and matches the breakdown, and Temperature scores correctly (2224a53)

### Closes

- Closes #614

## [3.1.2] — 2026-06-09

Patch release — game mobile fix.

### Fixed

- (#609) game (`site/game.html`): the Embeddings level was unplayable on a phone (free-form drag of words into a 2D plane). Replaced with a tap-the-meaning-group picker (reuses the mobile-proven `cut-*` card pattern); removed the dead `.emb-*` drag CSS (583e8a6)

### Closes

- Closes #609

## [3.1.1] — 2026-06-09

Patch release — CI fix + marketing-site game improvements shipped to production.

### Fixed

- (#601) pin `ossf/scorecard-action@v2.4.3` — the floating `@v2` major tag stopped resolving, failing the Scorecard supply-chain workflow on every push to `main` (771e2ea)
- (#602) game (`site/game.html`): mobile-responsive pass so every round plays on a ~360–390px phone, a universal `via #apexyard` share message (works across X / LinkedIn / WhatsApp / Copy, not just X), and a new capstone level **"Engineer the loop"** — toggle the guardrails that make an agent loop safe to run unattended (b3e9f4a)

### Added

- (#606) game: **Skip level** option for stuck players — a footer SKIP button (tap-to-confirm) that forfeits the current level (scores 0) and advances, so a hard level never blocks finishing the game (ebd3582)

### Closes

- Closes #601, #602, #606

## [3.1.0] — 2026-06-09

Post-v3.0.0 cycle — a new governed-looping pattern, an interactive marketing-site game, and a batch of hook / release-tooling fixes shaken out while cutting and syncing v3.0.0. The headline feature is **governed looping**: a trigger-heuristic rule that recommends a bounded, self-verifying loop for repetitive multi-item work and binds every loop to apexyard's existing merge gates as its eval.

### Added

- (#594) governed looping — `loop-mode.md` trigger rule + AgDR-0068 (when to OFFER a closed loop, which primitive, and the halt-at-CEO-gate / verify-with-tests guardrails) (9797a29)
- (#585) interactive "You vs. the LLM" game on the marketing site, with social score-sharing (X / LinkedIn / WhatsApp / Copy) and a play-the-game CTA across the site (fe743f9)

### Fixed

- (#549) `block-main-push` checks the operation's target branch, not the session cwd — no longer false-blocks a push to a feature branch from a `dev` checkout (eaa0fa9)
- (#547) git-push hook parses the destination ref and ignores redirection tokens + tag pushes (2b41158)
- (#548) pre-push markdownlint lints tracked files only (98a0aba)
- (#568) PR-number extractor ignores redirection tokens + unexpanded `$VAR` args (7da5984)
- (#569) bash-write ticket gate exempts `.claude/`, `/tmp`, `rm`, and `$VAR` targets (be50036)
- (#550) `/release` tags the squash commit on `main` + adds an ancestry guard before pushing the tag (63b72bf)
- (#559) Rex + `/approve-merge` resolve the review-marker home pin-first (split-portfolio marker lands where the gate reads it) (50b54a5)
- (#562) durable guard for the hero pill + releases-shipped metric against site/CHANGELOG version drift (a7f5f34)

### Changed

- (#588) dependabot + sync branches are exempt from the PR-create ticket-ID check; dependabot targets `dev` (207a761)
- (#590) bump `upload-artifact` v4→v7 + `codeql-action` v3→v4 (38dcf45)
- (#543, #542, #540) dependabot bumps — markdownlint-cli2-action 16→23, github-script 7→9, gitleaks-action 2→3 (4c8352a, 4c2a3cb, 4b69896)
- (#545) exempt `sync/` branches from the PR-create ticket-ID rule (f2ed536)
- (#560) re-fork & data-preservation guide added to `docs/upgrading.md` (28b34fe)

### Closes

- Closes #594, #585, #549, #547, #548, #568, #569, #550, #559, #562, #588, #590, #545, #560

## [3.0.0] — 2026-06-06

Large catch-up release — 181 commits since v2.3.0 (81 feat, 31 fix, 32 chore, plus docs/test/refactor/ci). Highlights this cycle: a Swift CI golden-path, onboarding-config-out-of-git + commit guard, framework security hardening (CodeQL/Scorecard/Dependabot/SECURITY.md/release-artifact guard), a per-worktree ticket-marker tier, and a CI-gated hook test suite.

### Breaking

- (#347) Hatim→Hakim consolidation — the Security Auditor agent was consolidated; adopters referencing the old `hatim`/Hatim agent name should move to `security-reviewer`/Hakim. (bcbb121)

### Added

- harden framework security scanning (code parts) (#523) (f617039)
- per-worktree ticket marker tier (fix same-project concurrent-agent collision) (#524) (5c0b8ee)
- keep onboarding config out of git (example-file + gitignore + guard) (#522) (3c1e728)
- add reusable Swift CI golden-path pipeline (#520) (b4ba5ab)
- fire the MCP-search advisory on Read/Glob/Grep for workspace paths (#490) (fdad663)
- /report-apexyard-bug + /request-apexyard-feature (upstream framework feedback) (#484) (7b39bcc)
- suggest MCP reindex after a workspace clone is pulled/updated (#483) (fb367b8)
- /handover checklist-first doc selection + template pick (#481) (b66fcf6)
- /launch-check --workflow — opt-in parallel + adversarially-verified audit (#474) (ec0727f)
- Solution Architect — independent design-review role/agent (Rex for non-code) (#472) (f86f843)
- /release-sync carries forward CHANGELOG.md from main to dev (#451) (95fd084)
- Rex semantic handbook supplement via MCP search_docs (#450) (d7519f4)
- Ollama/LiteLLM agent routing — reachability + model-pulled checks + session-wide ANTHROPIC_BASE_URL (#440) (add9c79)
- clone repo immediately at step 1.5 when URL given in /handover (#432) (587048a)
- auto-reindex MCP search after /handover clones a project (#429) (4a3e7bb)
- enforce MCP search-first pattern with advisory hooks (bbf4453)
- /release-sync — main→dev sync after each release (#406) (39f4b6e)
- rewrite site/ for outcomes-led positioning to non-tech founders (#387) (b9ed8cd)
- /plan-initiative — initiative → milestones → tasks (DAG + topo-sort + two-pass filing) (#379) (ac087b7)
- /handover offers to file Next Steps as tracker tickets (#378) (7879c0d)
- site AI-readiness polish — agent-permissions, llm:* meta, Copy-for-AI button (#369) (ada6836)
- clean URLs without .html via Netlify _redirects rewrites (#367) (8c86328)
- local-routing — Claude default + 4 commented candidates by hardware (Wave 2 PR 4) (#365) (dc83764)
- /setup seeds agent-routing.yaml + 8th portfolio config key (Wave 2 PR 3) (#363) (8be449c)
- class-aware role-trigger banner — HYBRID spawn vs in-thread (Wave 2 PR 5) (#362) (4ca8f30)
- promote utility agents to per-agent model: frontmatter (Wave 2 PR 4) (#361) (4baae6d)
- Hatim→Hakim consolidation + security + data sub-agents (Wave 2 PR 3) (#360) (bcbb121)
- agent-routing sync hook + pre-commit/pre-push drift guards (Wave 1 PR 2) (#357) (12484a0)
- promote product + design roles to sub-agents (Wave 3 PR 2) (#356) (5b37d69)
- promote engineering-dept roles to sub-agents + Activation mode (Wave 1 PR 1) (#355) (1e78cfd)
- agent-routing.yaml schema + portfolio_agent_routing resolver (Wave 1 PR 1) (#353) (cfdac35)
- audit-pack + safety-hooks marketplace plugins (#344) (5fe91d4)
- harness templates by topology — TS NextJS / Python FastAPI / Go data pipeline (#346) (6c0dc3f)
- /mutation-test skill + behaviour-quality sensor (#338) (8cca818)
- /generative-engine-audit — LLM/agent SEO sibling to /seo-audit (#315) (5ab092c)
- PR summary narrative-quality rule + Rex advisory check (#314) (550322d)
- /handover scores harnessability + warns on low blast-radius (#307) (dc81460)
- /codify-rule — turn human review comments into draft handbook entries (#305) (20ac99b)
- /extract-features --with-mockups (AI-inferred ASCII wireframes) (#292) (bc4b56b)
- standardise self-correction guidance across blocking hooks (shape + 5 retrofits) (#301) (4cebf94)
- declare jq as a hard dependency — Option A (#300) (bd5c29e)
- Rex domain-aware code review — handbooks/domain/ Stage 1 (#294) (2d514cf)
- tracker-aware hooks + _lib-tracker.sh dispatcher (#289) (ac89541)
- /feature-diagram skill for per-feature Mermaid sub-graphs (#291) (5b7ece9)
- /update walks intermediate-release migration chain (#286) (39bbaa4)
- /pdf — export any framework-generated doc to PDF, with destination prompt (#287) (40552c6)
- uniform ticket templates + custom-templates/ override (#285) (a4efbf2)
- skill-gated ticket-create hook (multi-tracker) (#276) (456272b)
- /threat-model inlines DFD as point-in-time snapshot at audit time (#273) (2aae484)
- mermaid lint per emitting skill (/c4, /dfd, /tech-vision) (#269) (94ed7a7)
- add site/architecture.html — 5-layer diagram, recoloured to site palette (#272) (43a5970)
- /tech-vision skill — interactive author for architecture vision (#263) (7de6b64)
- /investigation skill + template for sustained root-cause work (#262) (999e1b7)
- /dfd skill — extract Data Flow Diagram with trust boundaries + classifications (#260) (7c33016)
- /process skill — extract process from code, BPMN 2.0 output (#259) (3d8b75c)
- /threat-model --format=dragon for OWASP Threat Dragon JSON export (#258) (7c5f49d)
- private repo houses company custom skills + cross-org handbooks (#253) (40439ff)
- /update --from-dev hidden flag for pre-release sync (#254) (1020e01)
- /extract-features skill for greenfield rewrite inventories (#252) (df5b006)
- custom templates layer with override semantics (#251) (3dafe92)

### Fixed

- block build-agent self-review — require a real GitHub review behind the rex marker (#504) (471a74a)
- release site-version bump + correct issue-filing version on dev + tracker shape-only fallback (#505) (b149c4e)
- repo-qualify review markers to prevent same-PR-number collision across repos (#486) (417e326)
- make code-reading sub-agents MCP-first (#477) (42c8fb5)
- suggest-mcp-search surfaces to the agent + install-gates (#470) (d8862f1)
- PR-create hooks resolve PR origin repo, not session ops-fork (#465) (5638132)
- require --merge for sync PRs; guard --squash in hook (#463) (2961d4d)
- replace truncating sed extractor in require-agdr-for-arch-pr.sh with greedy awk (#462) (dfe35ba)
- inline helper-source in /dfd write blocks + strengthen Write targets rule (#445) (d12c460)
- warn at SessionStart when Ollama routing is INACTIVE; promote shell-profile step in docs (#444) (3848cb1)
- catch split-portfolio v2 silent fallbacks for workspace_dir and projects/ (#441) (d638dbf)
- route SETUP step 1 onboarding.yaml through portfolio helper (#437) (84eae45)
- promote /handover MCP reindex to named step + add advisory hook (#439) (03ed05a)
- configure branch protection on private portfolio repo after split-portfolio (#431) (1d107d8)
- update wrapper test to v2 shape + guard against v1 regression (#430) (c98a262)
- merge hook handles compound marker-write + merge commands (#427) (be1479c)
- hook walker reads session pin before walk-up (#425) (a2e7c36)
- guard bootstrap exemption scope — /handover only (#423) (d24c762)
- reorder case patterns to satisfy shellcheck SC2221 (3b217f9)
- remove stale --pdf-output-folder flag from md-to-pdf dispatch (#405) (47a438f)
- mobile UX regressions — nav main pages + eyebrow + content polish (#394) (0ba64e1)
- pin ops-root via CLAUDE_CODE_SESSION_ID SessionStart hook (#385) (fbc1cff)
- refine gh api matcher to only block POST on /issues (#384) (1f86db3)
- replace `|| echo "0"` with `|| true` in code-quality.yml (#375) (3942789)
- hook wrappers silent no-op outside an apexyard fork (#371) (fa327e0)
- /split-portfolio produces v2 layout + copy-onboarding semantics (#335) (a075c9a)
- resolve config from ops-fork root, not workspace clone (#313) (4b81bde)
- additive ui_paths_exclude carve-out for require-design-review-for-ui (#277) (14b651b)
- greedy body extractor — no more truncation at embedded quotes (#264) (227b3b4)
- align merge gates + agent + skill on ops-fork marker path (#240) (c419666)
- make verify-commit-refs and validate-pr-create consult upstream remote (#211) (02eeb1a)
- validation hooks read git context from command, not $PWD (#198) (ffb44b0)
- CHANGELOG fallback in drift hook for squash-merged forks (#129) (dd85a13)

### Changed

- rename /generative-engine-audit to /geo-audit (#339) (7567739)
- token-efficiency Wave 1 — ~2.9k tokens saved at session start (#328) (2ccefa4)
- sweep all 40 hook wrappers to v2-anchor-aware shape (#306) (ad42d0d)
- give every role + agent an Arabic persona name (#212) (88f9dae)

### Changed (chore)

- onboarding guard — literal filename match (grep -Fxq) (#525) (1822767)
- relax release-gated semgrep to fail-on-ERROR (#521) (2422927)
- reset onboarding.yaml to template placeholders (9730435)
- wire pre-push-gate to the framework CI checks + add git pre-push hook (#507) (94a6a0f)
- bump marketing-site framework version to 2.2.0 (#492) (e93562c)
- whitelist `sync` type across branch/commit/PR validators (#460) (02dc105)
- main→dev sync after v2.2.0 release (#457) (2314e2f)
- add split-portfolio v2 marker + sync onboarding.yaml from portfolio (de9069c)
- sync CHANGELOG.md from main to dev (#447) (e8208bd)
- ship 6 site/ binary assets — OG previews + favicons (#383) (0526aac)
- wave-2 cleanup bundle — drop allowed_tools_override + push-gate scope + multi-line drift (#364) (47b557a)
- site/ count refresh + meta-tag polish + content-shape + markdown alternates (#340) (7668e91)
- site/ AI-readiness + classic SEO infrastructure (#337) (cb00fa9)
- generic cleanup (#304) (e4aa82a)
- retrofit 7 audit skills onto _lib-audit-history.sh (#239) (c8b292e)
- add Data Flow Diagram section to threat-model template (#225) (fc54ace)
- /setup emits verified LSP plugin-install commands (#216) (526e9b7)
- sync CHANGELOG.md from main → dev (#174) (85fe794)
- exempt release/vN.N.N from validate-pr-create's branch-id check (#171) (9873c25)
- accept release/vN.N.N branches + release(...) PR titles (#169) (f28096a)
- default the split-portfolio sibling repo name to <fork>-portfolio (#164) (9517b19)
- remove voice-prompts feature + correct hook/skill counts (#161) (327a297)
- extend Bash-write matcher beyond first-version coverage (#155) (690ada8)
- adopt release-cut branch model (dev/main + tags) — framework only (#126) (3c53ff8)
- enforce single Closes-keyword per PR body (#125) (5a03d9e)
- require Testing section in PR body (config-driven) (#124) (e4c09a3)
- add require-agdr-for-arch-pr.sh PreToolUse hook (#123) (f23f784)
- add validate-issue-structure.sh PreToolUse hook (#122) (6920060)
- upgrade pre-push-gate from advisory reminder to blocking check-runner (#121) (e98633c)
- add warn-stale-review-markers.sh PostToolUse hook (#120) (6e86b95)
- add block-private-refs-in-public-repos.sh hook (#119) (a4edb89)
- project-configurable ticket / branch / commit / PR schema (#118) (1586d44)

### Docs

- open-source community-health files (CONTRIBUTING, issue/PR templates, SECURITY) + README refresh — share banner, corrected component counts, framework-feedback skill guidance (#536) (#537) (6ac3373)
- /debug 'when to invoke' sidebar in workflows/sdlc.md Phase 3 (#366) (008aaf0)
- AgDR-0050 — agent runtime overhaul (cross-cutting design for #347 + #348 + #351) (#352) (17942fc)
- align v1→v2 manual recipe in docs/multi-project.md with AgDR-0021 § H copy-onboarding semantics (#350) (5d54641)
- AgDR-0047 for framework packaging & distribution (#343) (e6a6d71)
- plan-mode usage rule — when to enter (#220) (5eccc0f)
- Claude tier-routing spike — measurement + recommendation (#201) (e435719)
- local-model routing spike — measurement + recommendation (#196) (20d9974)
- document ENABLE_LSP_TOOL opt-in + per-language LSP plugin install (#193) (8e753f6)
- annotate LSP-aware skills with opt-in callouts (#191) (fa72b0a)
- LSP integration spike — measurement + recommendation (#184) (9615dea)
- correct privacy-gate wording — adopter action, not framework auto-publish (#149) (20b071e)
- document split-portfolio mode + add /setup privacy gate (#144) (344da88)

### Performance

- drop @docs/multi-project.md auto-import from CLAUDE.md (#380) (0f6ca08)

### CI

- gate the hook test suite in CI (#527) (1027dbc)
- release-gated security scan on the framework repo (dog-food the Shield pipeline) (#488) (4509ebf)

### Tests

- drain quarantine — pin-escape audit fix + handover rewrite (#533) (afbb26c)
- fix + un-quarantine agent_routing_sync_and_drift (#530) (41d1051)
- fix + un-quarantine 3 of 5 hook-test failures (#529) (9bd0e17)
- multi-project workspace + conflict-skip + README preservation (Case 5) (#368) (9ddbe2b)
- /setup + /update step 8a test infrastructure (#349) (e135a0b)
- mock gh in test sandboxes to remove live-tracker dependency (#156) (d4ed533)

## [2.3.0] — 2026-06-04

### Added

- **Solution Architect role + `/design-review` (#471)** — an independent design-review role (Tariq) reviews technical designs, migration AgDRs, and feature specs *before* the Build phase, gated at merge (Gate 3b). The non-code analog of the Code Reviewer. Ships `/design-review` + `/approve-architecture`.
- **`/launch-check --workflow` (#473)** — opt-in mode that fans the 10 readiness dimensions out in parallel and adversarially verifies the findings.
- **`/handover` checklist-first doc selection (#480)** — choose which docs to generate per handover, each with its own template pick.
- **`/report-apexyard-bug` + `/request-apexyard-feature` (#482)** — file framework bugs / feature requests upstream (leak-scrubbed), distinct from project-level `/bug` and `/feature`.

### Changed

- **Pre-push gate runs the framework CI locally (#506)** — `.pre_push.commands` wired to the CI checks (markdownlint, shellcheck, count-drift, sub-packs) + a committed `.githooks/pre-push` for terminal pushes, so failures are caught before push.
- **`/release` auto-bumps the marketing-site version (#493)** — with a drift guard so the site version can't silently fall behind the CHANGELOG again.
- **Release-gated security scan (#487)** — the framework repo now runs its security pipeline at release time.
- **`sync` accepted as a commit / branch / PR type (#458)** — validators whitelist it for the release-sync flow.

### Fixed

- **Build-agent self-review blocked (#494)** — build-class sub-agents can no longer frame their output as a code review or fabricate approval markers; guardrails + an advisory warn hook (a stricter mechanical gate is available as an opt-in).
- **Issue-filing version on `dev` (#493)** — the upstream-feedback skills read the current version from the CHANGELOG instead of a stale `git describe` tag.
- **Tracker hooks shape-only fallback (#493)** — PR / commit ticket hooks no longer hard-block when a non-GitHub tracker (Jira / Linear) can't be queried; they fall back to format validation.
- **Repo-qualified review markers (#485)** — markers are namespaced by repo, preventing same-PR-number collisions across repos.
- **PR-create hooks resolve the PR's origin repo (#464)** — not the session ops-fork, fixing cross-repo false-positives.
- **Sync PRs require `--merge` (#459)** — the release-sync flow guards against `--squash`, which would discard the ancestry link.
- **AgDR-arch-PR body extractor (#461)** — replaced a truncating `sed` extractor with a greedy `awk` one.

## [2.2.0] — 2026-05-29

### Local agent routing + split-portfolio v2 hardening + release-cycle plumbing

Minor release bundling three themes:

1. **Local agent routing pipeline** — when `agent-routing.yaml` configures an Ollama/LiteLLM endpoint, the framework now verifies reachability and model availability at SessionStart, exports `ANTHROPIC_BASE_URL` session-wide so routed traffic actually lands on the local endpoint, and warns at SessionStart when routing is configured but INACTIVE (shell-profile snippet not yet sourced).
2. **Split-portfolio v2 hardening** — partial-config detection (registry pointing at sibling but `workspace_dir` falling back to in-fork default is now a structured SessionStart error, not a silent split), SETUP step 1 routed through the portfolio helper, and 10 prompt-based skills tightened to source the helper inline before any write block so `projects_dir` never falls back to literal paths.
3. **Release-cycle plumbing** — `/release-sync` now carries forward `CHANGELOG.md` from `main` to `dev` as a separate atomic commit on top of the `-X ours` merge, closing the silent drift gap that previously required occasional manual resync PRs.

Plus a handful of correctness fixes around hook walkers, merge-gate parsing, branch protection on split-portfolio sibling repos, and a regression guard against legacy v1 walker hooks.

### Added

- `feat(#417)` **`/handover` clones the target repo at step 1.5** — when given a Git URL, the skill clones immediately before any reads, so steps 2–6 run against a local checkout instead of the GitHub API. Subsequent reads are 3–15× cheaper per query; failure paths preserved. (PR #432)
- `feat(#438)` **Ollama / LiteLLM local agent routing** — single source of truth replaces three ad-hoc env-var setups across skills. SessionStart verifies endpoint reachability (a), confirms each configured model is pulled (b), exports `ANTHROPIC_BASE_URL` session-wide (c) so routed traffic actually lands on the local endpoint. (PR #440)
- `feat(#448)` **`/release-sync` carries forward `CHANGELOG.md` from main to dev** — adds a step 5b that runs after the existing `-X ours` merge: if dev's CHANGELOG drifted from main's, restore main's version via a separate atomic commit on the sync branch. Path-specific (only `CHANGELOG.md`), idempotent via `git diff --quiet upstream/main -- CHANGELOG.md` guard, audit-trail-visible in the sync PR. Closes the silent drift gap that required occasional manual chore PRs to resync. 14/14 tests pass (11 original + 3 new). (PR #451)
- `feat(#449)` **Rex handbook discovery — additive supplement** — opt-in, fail-soft enhancement to the path-convention handbook matching Rex already performs. When unavailable or unconfigured, Rex's review behaviour is byte-for-byte unchanged. Adopters who don't configure it see zero impact. (PR #450)

### Fixed

- `fix(#373)` **Split-portfolio v2 partial-config detection** — when adopters' `.claude/project-config.json` has the registry / projects / onboarding keys pointing at a sibling repo but leaves `workspace_dir` falling back to the in-fork default, `portfolio_validate()` now emits a structured SessionStart error naming `.portfolio.workspace_dir` and the fix instead of letting clones silently accumulate in the public ops fork. Plus 9 prompt-based skills (`/extract-features`, `/feature-diagram`, `/handover`, `/journey`, `/plan-initiative`, `/process`, `/roadmap`, `/stakeholder-update`, `/tech-vision`, and `/dfd`) tightened to source the portfolio helper before any write block so they cannot drift back to literal `projects/<name>/...` paths. (PR #441)
- `fix(#414)` **Regression guard against v1 walker hooks** — adds a wrapper-test that asserts no v1 hook surfaces in CI, covering the `gh issue edit` / `gh issue create` blockers that v1 walker hooks reintroduced if a stale install was layered on top of v2. (PR #430)
- `fix(#415)` **`/split-portfolio` configures branch protection on the private portfolio repo** — after a fresh split, the private sibling repo's `main` branch is now protected (required reviews, no force-push) instead of being left wide open. (PR #431)
- `fix(#419)` **Bootstrap exemption scope guard** — narrows `require-active-ticket.sh`'s bootstrap exemption to `/handover` only (was previously broad enough to leak through to other bootstrap-listed skills mid-session). (PR #423)
- `fix(#424)` **Hook walker reads session pin first** — the hook walker now checks the `CLAUDE_CODE_SESSION_ID` session pin before walking the cwd up the tree, so edits made inside `workspace/<project>/` correctly resolve to the project's marker file under the ops fork. Closes a class of "ticket marker not found" failures for managed-project work. (PR #425)
- `fix(#426)` **Merge hook handles compound marker-write + merge commands** — the merge-gate hook now correctly parses `cmd_a && cmd_b` shapes where the first half writes the CEO marker and the second half is the actual `gh pr merge`. Previously the marker write was treated as the gated command and the merge slipped through unguarded. (PR #427)
- `fix(#434)` **SETUP step 1 routes `onboarding.yaml` through portfolio helper** — first-run `/setup` was reading the in-fork copy unconditionally; split-portfolio v2 adopters now correctly see the sibling repo's copy on SETUP step 1 without manual workaround. (PR #437)
- `fix(#442)` **SessionStart warns when local agent routing is INACTIVE** — when `agent-routing.yaml` configures a local endpoint but the current shell has not exported `ANTHROPIC_BASE_URL` (e.g. shell-profile snippet not yet sourced), SessionStart now prints an INACTIVE warning naming the missing env vars and the shell-profile step. (PR #444)
- `fix(#443)` **Per-block helper-source preamble across 10 skills** — each `bash` write block in `/dfd`, `/extract-features`, `/feature-diagram`, `/handover`, `/journey`, `/plan-initiative`, `/process`, `/roadmap`, `/stakeholder-update`, `/tech-vision` now sources the portfolio helper at the top of the block. Eliminates the cross-block scoping bug where `projects_dir` from an earlier block was undefined in a later one and writes silently fell back to literal `projects/<name>/...`. The Write-targets rule in each SKILL is strengthened with a "REQUIRED per-block preamble" note. (PR #445)

### Changed

- `chore(#446)` **`CHANGELOG.md` on `dev` resynced with `main`** — v1.3.0 → v2.1.0 release-notes entries were missing on dev due to accumulated `-X ours` merge drift over 5 release cycles. One-off content fix; the follow-up #448 closes the underlying mechanism so this won't recur. (PR #447)

### Compatibility

No breaking changes. Adopters running purely on Anthropic's hosted API see no behaviour change. Adopters who use local agent routing get correctness improvements (reachability checks, INACTIVE warnings) instead of silent fallbacks. Split-portfolio v2 adopters whose configs are complete see no behaviour change; those whose configs are partial now get a clear SessionStart error directing them to set `.portfolio.workspace_dir`.

## [2.1.0] — 2026-05-24

### `/release-sync` closes the dev/main divergence loop + one small bug fix

Minor release. Adds a new `/release-sync` skill that automates the main→dev sync after each release-PR merge, so the squash-merge divergence stops compounding from one release to the next. After this release, the next `dev → main` release cycle can run the canonical flow instead of cherry-picking.

### Added

- `feat(#403)` **`/release-sync` skill** — runs as Step 9 of `/release`. Creates a sync branch from `upstream/dev`, merges `upstream/main` with `--no-ff -X ours` (dev wins on conflicts because dev already has the un-squashed equivalents), opens a sync PR. Stops at PR creation; normal Rex + CEO merge gate applies. Framework-only (refuses on managed projects). Defensive cases handled: already-in-sync (no-op exit 0), going-backwards (refuse exit 1). 11 unit tests, AgDR-0052 documents the design trade-offs.

### Fixed

- `fix(#404)` **`/pdf` `convert.sh` fallback path** — removed stale `--pdf-output-folder` and `--dest-name` flags from the md-to-pdf dispatch branch (md-to-pdf removed both flags in a breaking API change). New strategy: stage source into a temp dir under the desired output stem, run `npx md-to-pdf`, move the result to the requested destination. Pandoc preferred-path unchanged; graceful-degrade (exit 3) on no converter installed preserved. New regression test (`test_md_to_pdf_fallback.sh`) pinned against npm `latest` to catch future upstream API drift.

### Compatibility

No breaking changes. Adopters using `/pdf` on systems without pandoc see the fallback path work again. Adopters using `/release` get a new optional Step 9; existing release flow unchanged unless `/release-sync` is invoked.

## [2.0.2] — 2026-05-24

### GA4 + consent banner on all 4 site pages

Patch-only release. v2.0.0 + v2.0.1 left Google Analytics + the cookie consent banner only on `site/index.html`. Any visitor landing directly on `/how-it-works`, `/architecture`, or `/skills` (Twitter/LinkedIn shares, search results, LLM citations from `llms.txt`) was invisible to GA4 — and worse, never saw the consent UI at all, a GDPR gap. This release closes that. No framework changes — site-only.

### Fixed

- `fix(#399)` **GA4 tag on all 4 site pages** — copied gtag.js + Consent Mode v2 default block from `index.html` to `how-it-works.html`, `architecture.html`, `skills.html`. Each block wrapped in `<!-- begin: gtag --> ... <!-- end: gtag -->` markers for greppable future sync (static site, no build step). Every share-driven visit now tracked (subject to consent).
- `fix(#399)` **Cookie consent banner on all 4 site pages** — same Accept/Decline/Escape flow + `localStorage.ay-consent` persistence as the existing index.html implementation. A user landing on `/how-it-works` first now gets the consent choice; the choice is honoured site-wide on subsequent navigation.
- `fix(#399)` **Removed dead `anonymize_ip: true` config** — no-op in GA4 (Universal Analytics carryover; GA4 anonymizes all IPs by default).
- `fix(#399)` **Refreshed `<meta name="llm:token-count">` + `<meta name="llm:doc-length">`** on all 4 pages to reflect new sizes after the GA4 block additions.

### Compatibility

No breaking changes. No framework code touched. Adopters see no changes to hooks, skills, rules, agents, templates, or workflows — only `site/` files modified.

## [2.0.1] — 2026-05-24

### Mobile UX hotfix for the v2.0.0 marketing site

Patch-only release fixing 7 mobile UX regressions surfaced after v2.0.0 shipped. No framework changes — site-only.

### Fixed

- `fix(#393)` **Main-page nav restored on mobile** — `architecture`, `skills`, and `how it works` links were hidden by the `<700px` collapse rule on all 4 site pages. Added `class="always"` so they stay visible. Mobile readers can move between sections again.
- `fix(#393)` **Eyebrow row wraps cleanly** — the "Copy as Markdown for AI" button no longer crowds the pill+subtitle row at narrow widths. Drops to its own line below the eyebrow on mobile.
- `fix(#393)` **Duplicated lead text hidden from sighted users on `/how-it-works`** — the `#ai-lead` block (added in v2.0.0 to satisfy `/geo-audit` G12) is now visually-hidden via clip+position trick. AI crawlers and screen readers still consume it; sighted users no longer see the same prose twice.
- `fix(#393)` **Homepage hero polish** — "Built by me2resh" moved from between tagline and subhead to below the CTAs; version line dimmed further (14px→13px, opacity 0.7→0.55); hero inline link shortened and `white-space:nowrap` so it doesn't wrap mid-phrase.
- `fix(#393)` **Subtitles trimmed on `/architecture` and `/skills`** so they don't wrap awkwardly on mobile.

### Compatibility

No breaking changes. No framework code touched. Adopters see no changes to hooks, skills, rules, agents, templates, or workflows — only `site/` files were modified.

## [2.0.0] — 2026-05-24

### Six new skills, agent runtime overhaul, marketing site repositioned

v2.0.0 adds six slash commands (planning, audit, PDF, handbook-feedback), ships per-agent model routing via `agent-routing.yaml`, introduces class-aware role activation (spawn vs in-thread), and renames the security-reviewer agent (Hatim → Hakim). The marketing site is repositioned for the founder audience.

**6 new skills (54 total) · 5 adopter-friction fixes · 1 breaking change.**

### Highlights

- **`/plan-initiative`** — interview-driven decomposition into milestones + tasks, dependency-aware sequencing, optional bulk-file each milestone as a Feature ticket with cross-refs
- **`/mutation-test`** — mutation-testing sensor (Stryker / MutPy / go-mutesting / mutant); milestone cadence, graceful degrade if no language tool installed
- **`/geo-audit`** — LLM- and agent-discoverability audit; 17 checks across discovery, capability-signaling, content-format, token economics (sibling to `/seo-audit`)
- **`/codify-rule`** — turn a code-review comment that caught a Rex-miss into a draft handbook entry, auto-routed by domain bucket
- **`/feature-diagram`** — per-feature Mermaid flowchart of routes / models / jobs / screens (consumes `/extract-features` inventory)
- **`/pdf`** — export any framework-generated doc (markdown / HTML / BPMN) to PDF with destination prompt
- **Agent routing layer** (`agent-routing.yaml`) — per-agent model / endpoint / env / timeout overrides without forking the framework agent files
- **Class-aware role activation** — role triggers now distinguish isolated-work (spawn sub-agent) from in-flow (adopt persona in-thread) per the role's `Class` field

### Added

- `feat(#377)` `/plan-initiative` — initiative → milestones → tasks with DAG topo-sort + two-pass filing
- `feat(#299)` `/mutation-test` — language-dispatched mutation testing, milestone cadence, exit-3 graceful degrade
- `feat(#311)` `/geo-audit` — LLM/agent discoverability audit (renamed from `/generative-engine-audit` in #334)
- `feat(#296)` `/codify-rule` — review comment → handbook entry, Y/N gated, source-PR footer
- `feat(#288)` `/feature-diagram` — per-feature Mermaid flowchart
- `feat(#284)` `/pdf` — destination-prompted PDF export (pandoc / md-to-pdf / wkhtmltopdf / bpmn-to-image dispatch)
- `feat(#351)` `agent-routing.yaml` — per-agent model / endpoint / env / timeout overrides + SessionStart sync hook + drift guards
- `feat(#347)` Class-aware role-trigger banner — HYBRID spawn-vs-in-thread per role's `Class` field
- `feat(#298)` `/handover` scores harnessability across 5 codebase dimensions and offers to file Next Steps as tracker tickets
- `feat(#293)` Rex domain-aware code review — `handbooks/domain/` Stage 1
- `feat(#297)` Harness templates by topology — TS NextJS / Python FastAPI / Go data pipeline scaffolds
- `feat(#321)` Audit-pack + safety-hooks marketplace plugins
- `feat(#386)` Marketing site rewritten for outcomes-led positioning — new `/how-it-works` page, attribution layer across 156 framework markdown files

### Breaking

- **Security-reviewer agent renamed `Hatim → Hakim`** (#347, PR #360) — consolidates the prior Hatim persona into the canonical Hakim security-review agent. Stock-agent adopters have nothing to do. Adopters with custom prompts / hooks that explicitly referenced `Hatim` must grep and update.

### Fixed

- `fix(#382)` `gh api repos/...` GETs no longer blocked by the ticket-create gate (was over-broad prefix match)
- `fix(#381)` Code-reviewer agent's approval marker now pin-resolves to the ops fork via SessionStart, not the throwaway clone
- `fix(#370)` Hook wrappers silent no-op when launched outside an apexyard fork
- `perf(#372)` `docs/multi-project.md` (70k chars) no longer auto-imported into every session — ~18k tokens reclaimed
- `fix(#310)` Config resolves from ops-fork root, not the workspace clone
- `fix(#317)` `/split-portfolio` produces v2 layout with copy-onboarding semantics

### Changed

- `feat(#280)` `jq` is now a hard dependency — `/setup` refuses to proceed without it (was advisory)
- `feat(#283)` Tracker-aware hooks via `_lib-tracker.sh` dispatcher (`gh` / `linear` / `jira` / `asana` / `custom` / `none`)
- `feat(#282)` `/update` walks intermediate-release migration chain — safe to skip versions and re-sync
- `feat(#312)` PR summary narrative-quality rule + Rex advisory check — label-only bullets flagged
- `feat(#295)` Self-correction guidance standardised across 5 blocking hooks

### Notable behaviour changes

1. **Agent renamed: `Hatim → Hakim`** — see Breaking above.
2. **`jq` required for `/setup`** — first-run refuses without `jq` on PATH (was silent default-fallback). See AgDR-0038.
3. **`agent-routing.yaml` SessionStart sync** — overrides applied on every session start. Edit the file; no manual reload needed.
4. **Class-aware role activation** — custom roles should declare `**Class**: isolated-work-class` or `**Class**: in-flow-class` per AgDR-0050.
5. **`docs/multi-project.md` no longer auto-loaded** — setup-relevant content still on demand via `Read`.

---

## [1.3.0] — 2026-05-18

### Architecture-doc family + audit persistence + split-portfolio v2 + multi-tracker gate

v1.3.0 added the **architecture-doc family** — read-the-code-and-produce-an-artefact skills (`/c4`, `/dfd`, `/process`, `/tech-vision`, `/journey`, `/extract-features`, `/agdr`, plus `/threat-model --format=dragon`), canonical audit-artefact persistence (paired JSON + MD per run, dated subdirs), split-portfolio v2 (workspace + onboarding moved to private sibling repo), and skill-gated ticket-create across multiple trackers.

Full release notes: [PR #279](https://github.com/me2resh/apexyard/pull/279). Highlights:

- 9 new skills, 4 new hooks (28 total at the time), 16 new AgDRs (0014 → 0030, excluding 0029 parked)
- Audit-artefact persistence (#218, AgDR-0019) — `projects/<name>/audits/<dim>/<ts>.md` + `runs/<ts>.json`
- Split-portfolio v2 (#242, AgDR-0021) — `onboarding.yaml` + `workspace/` move to private sibling repo
- Custom templates layer (#244, AgDR-0023) and private custom skills + handbooks (#243, AgDR-0022)
- Skill-gated ticket-create across `gh` / `linear` / `jira` / `asana` (#268, AgDR-0030)
- Mermaid lint per emitting skill (`/c4`, `/dfd`, `/tech-vision`) (#266)

---

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
