# Changelog

All notable changes to ApexYard are documented here.

## [v5.1.0] — 2026-07-16

Minor release — 16 features, 11 fixes, 9 improvements.

### Added (feat)

- (#915) on-demand glossary lookup rule + full /tutorial glossary — 08428dd
- (#913) onboarding JIT glossary asides — guided-mode teach-in-context (#913) — 2bd7c1b
- (#933) SessionStart search advisory probes MCP reachability — 77d99de
- (#934) onboarding depth adaptivity — terse vs guided + override + transparency — fa4bf37
- (#928) Phase-0 cognitive memory scaffold (.claude/memory/) — 0f04092
- (#925) /inbox stale-ticket reconcile flag — surface open issues with a merged PR — cb78bed
- (#920) standalone /tutorial re-entry point (tour-only) — 961257e
- (#910) increment-1 walking-skeleton first-run onboarding flow — 50814c8
- (#894) advisory intent → skill routing hook + skill-first rule — 1847f79
- (#895) wire the session-start reindex hook into settings.json — 33b4915
- (#904) SessionStart split-portfolio v2 primer banner — 5d0834a
- (#871) conformance CI — credentialed multi-runtime gate matrix + live badge — 6d86b58
- (#893) premium-hook safe-fallback harness — _lib-premium-hook.sh — 7809376
- (#892) SessionStart validation for apexyard-search MCP config — 4352a5f
- (#710) add tracker_list + cross-tracker query translation — 4a1487d
- (#761) widen tracker_view body support to jira/linear/asana — 85bd0f1

### Fixed (fix)

- (#932) close <> read-write + >(…) process-sub residuals in bash write-detection — 7e08e47
- (#886) judge all bash write targets, not just the first — 5c6b1aa
- (#887) scope the remaining unscoped gh pr view calls in the review-posting path (#887) — 25f6678
- (#908) gate scorecard.yml to the canonical repo — 4e60d5e
- (#906) globToRegExp missing dotall flag — multi-line commits fail-open on gate adapters — 0dba073
- (#898) scope pr_base_repo to an explicit repo (no ambient gh resolution) — 8f1d68a
- (#897) exempt 'development' + config-driven trunk whitelist in validate-branch-name — 527015c
- (#883) exempt out-of-repo writes from the ticket-first gate — b6f7f56
- (#882) resolve /start-ticket's ops root correctly on split-portfolio v2 — fddc9ea
- (#872) resolve the changelog range from a Released-From trailer — 9150d63
- (#875) trim marker-set recipe from warn-review-marker-write.sh BLOCKED banner — 602fc25

### Changed (refactor / chore / docs)

- (#912) increment-2 technical design — onboarding education layer — fe738e0
- (#924) add reconcile-before-build self-discipline rule — a3e57b9
- (#921) conformance dispatch-streak guard + Codex model pin — 6b48e77
- (#909) increment-1 technical design — guided first-run onboarding — 626dcad
- (#902) PRD — guided onboarding + teach-in-context — e61a20e
- (#901) managed-project release versioning convention — e402955
- (#889) fold no-attribution advisory into commit-message-quality handbook — 0b13047
- (#877) AgDR-0094 — record release provenance via Released-From trailer — 12c9fb9
- (#874) trim verbose squash-merge note in README contributors section — 9b2b814

### Closes

- Closes #710, #761, #871, #872, #874, #875, #877, #882, #883, #886, #887, #889, #892, #893, #894, #895, #897, #898, #901, #902, #904, #906, #908, #909, #910, #912, #913, #915, #920, #921, #924, #925, #928, #932, #933, #934

## [v5.0.0] — 2026-07-10

Major release — 122 features, 75 fixes, 1 breaking change. Consolidates the multi-harness governance quarter (opencode / pi.dev / Codex / Cursor gate adapters, `/eval-agents`, tracker-agnostic review + merge routing) on top of v4.4.0.

### Breaking

- feat(#347)!: Hatim→Hakim consolidation + security + data sub-agents (Wave 2 PR 3) (#360)

### Added (feat)

- harness-selection step in /setup and /handover (#850)
- opencode gate adapter — enforce apexyard gates via a plugin over the bash hooks (#839)
- Cursor gate adapter — generate .cursor/hooks.json delegating to the bash hooks (#838)
- /eval-agents — score review agents against frozen ground-truth defect sets (#828)
- add Codex adapter generator (#730)
- Structurizr DSL as escape hatch for L3+ C4 diagrams (#822)
- multi-harness gate adapter for pi.dev (#817)
- pi.dev AGENTS.md bridge (advisory rules for pi) (#806)
- route /approve-merge's merge command through tracker_pr_merge (gh/glab) (#794)
- /handover offers a Governed-by-ApexYard badge to onboarded repos (#798)
- route /security-review + /design-review through tracker_review_submit (#766)
- route /code-review through tracker-agnostic review submission (#762)
- make merge-gate HEAD/merge-detection forge-aware (gh/glab) (#767)
- docs-index hook — auto-maintain per-project docs/INDEX.md + nudge (#768)
- guard the agent-spawn boundary with a role-selection rule (#789)
- safe-by-default isolated builds via git worktrees (rule + advisory guard) (#787)
- reporting-style rule + human-report output style (#783)
- auto-invoke the Security Auditor on trust-chain changes (#778)
- route remaining creator skills + label helper through tracker abstraction (#771)
- wire design tooling into roles + add /design-sync skill (#742)
- offer an opt-in /challenge nudge from /decide (#740)
- auto-move board cards through the SDLC lifecycle (#726)
- route /task /feature /bug through tracker_create (#708)
- add The Contrarian — advisory premise-level adversary agent (#707)
- add golden-path macOS build + release pipeline template (#706)
- tracker_create creation abstraction (gh/glab/custom) (#702)
- add golden-path Terraform CI pipeline template (#703)
- per-project tracker config resolution (#671)
- add /walking-skeleton + /prototype skills (#682)
- automate /release — one-command bump + changelog + release PR (#681)
- /handover offers in-repo AGENTS.md generation (#675)
- detect (and offer to enable) GitHub Issues in /setup + /handover (#654)
- opt-in gate mode for suggest-mcp-search.sh (force MCP-first on exploratory search) (#652)
- consent-gated GA + cookie banner on all site pages (#641)
- grant Rex search_code + prefer semantic search when available (#633)
- support fallow static analysis in code review (#628)
- game — Skip level (forfeit to 0) for stuck players (#607)
- governed looping — loop-mode trigger rule + AgDR-0068 (#595)
- interactive LLM game on the site with social score-sharing (#586)
- harden framework security scanning (code parts) (#523)
- per-worktree ticket marker tier (fix same-project concurrent-agent collision) (#524)
- keep onboarding config out of git (example-file + gitignore + guard) (#522)
- add reusable Swift CI golden-path pipeline (#520)
- fire the MCP-search advisory on Read/Glob/Grep for workspace paths (#490)
- /report-apexyard-bug + /request-apexyard-feature (upstream framework feedback) (#484)
- suggest MCP reindex after a workspace clone is pulled/updated (#483)
- /handover checklist-first doc selection + template pick (#481)
- /launch-check --workflow — opt-in parallel + adversarially-verified audit (#474)
- Solution Architect — independent design-review role/agent (Rex for non-code) (#472)
- /release-sync carries forward CHANGELOG.md from main to dev (#451)
- Rex semantic handbook supplement via MCP search_docs (#450)
- Ollama/LiteLLM agent routing — reachability + model-pulled checks + session-wide ANTHROPIC_BASE_URL (#440)
- clone repo immediately at step 1.5 when URL given in /handover (#432)
- auto-reindex MCP search after /handover clones a project (#429)
- enforce MCP search-first pattern with advisory hooks
- /release-sync — main→dev sync after each release (#406)
- rewrite site/ for outcomes-led positioning to non-tech founders (#387)
- /plan-initiative — initiative → milestones → tasks (DAG + topo-sort + two-pass filing) (#379)
- /handover offers to file Next Steps as tracker tickets (#378)
- site AI-readiness polish — agent-permissions, llm:* meta, Copy-for-AI button (#369)
- clean URLs without .html via Netlify _redirects rewrites (#367)
- local-routing — Claude default + 4 commented candidates by hardware (Wave 2 PR 4) (#365)
- /setup seeds agent-routing.yaml + 8th portfolio config key (Wave 2 PR 3) (#363)
- class-aware role-trigger banner — HYBRID spawn vs in-thread (Wave 2 PR 5) (#362)
- promote utility agents to per-agent model: frontmatter (Wave 2 PR 4) (#361)
- agent-routing sync hook + pre-commit/pre-push drift guards (Wave 1 PR 2) (#357)
- promote product + design roles to sub-agents (Wave 3 PR 2) (#356)
- promote engineering-dept roles to sub-agents + Activation mode (Wave 1 PR 1) (#355)
- agent-routing.yaml schema + portfolio_agent_routing resolver (Wave 1 PR 1) (#353)
- audit-pack + safety-hooks marketplace plugins (#344)
- harness templates by topology — TS NextJS / Python FastAPI / Go data pipeline (#346)
- /mutation-test skill + behaviour-quality sensor (#338)
- /generative-engine-audit — LLM/agent SEO sibling to /seo-audit (#315)
- PR summary narrative-quality rule + Rex advisory check (#314)
- /handover scores harnessability + warns on low blast-radius (#307)
- /codify-rule — turn human review comments into draft handbook entries (#305)
- /extract-features --with-mockups (AI-inferred ASCII wireframes) (#292)
- standardise self-correction guidance across blocking hooks (shape + 5 retrofits) (#301)
- declare jq as a hard dependency — Option A (#300)
- Rex domain-aware code review — handbooks/domain/ Stage 1 (#294)
- tracker-aware hooks + _lib-tracker.sh dispatcher (#289)
- /feature-diagram skill for per-feature Mermaid sub-graphs (#291)
- /update walks intermediate-release migration chain (#286)
- /pdf — export any framework-generated doc to PDF, with destination prompt (#287)
- uniform ticket templates + custom-templates/ override (#285)
- skill-gated ticket-create hook (multi-tracker) (#276)
- /threat-model inlines DFD as point-in-time snapshot at audit time (#273)
- mermaid lint per emitting skill (/c4, /dfd, /tech-vision) (#269)
- add site/architecture.html — 5-layer diagram, recoloured to site palette (#272)
- /tech-vision skill — interactive author for architecture vision (#263)
- /investigation skill + template for sustained root-cause work (#262)
- /dfd skill — extract Data Flow Diagram with trust boundaries + classifications (#260)
- /process skill — extract process from code, BPMN 2.0 output (#259)
- /threat-model --format=dragon for OWASP Threat Dragon JSON export (#258)
- private repo houses company custom skills + cross-org handbooks (#253)
- /update --from-dev hidden flag for pre-release sync (#254)
- /extract-features skill for greenfield rewrite inventories (#252)
- custom templates layer with override semantics (#251)
- split-portfolio v2 — workspace + onboarding to private repo (#248)
- adopter handbooks consumed by Rex during code review (#233)
- add architecture vision + DFD + sequence templates (#226)
- audit-skill artefact persistence + canonical structure (#222)
- role-activation visibility markers convention (#213)
- mechanical role-trigger detection with non-blocking reminder injection (#209)
- /setup auto-enables LSP — language detection + install + env var + plugin (#210)
- /spike skill — hypothesis-driven throw-away ticket type (#202)
- /journey skill — single-file user-journey HTML with modal-per-page (#200)
- /update detects deprecated config keys + offers cleanup (#199)
- /handover offers clone-first deep-dive prompt (#192)
- /status --briefing + bin/apexyard status CLI shim (#187)
- /launch-check trend tracking (#185)
- /agdr skill — searchable AgDR library (#186)
- skills reference page on the landing site + changelog link (#167)
- multi-tab terminal demo on the landing site (#162)
- structured CEO marker + same-turn merge in /approve-merge (#158)
- bootstrap-skill exemption + Bash-write coverage (#152)
- portfolio config + self-healing + /split-portfolio helper (#147)
- add /debug skill — structured hypothesis-driven debugging (#142)
- configurable voice prompts on assistant pause (AgDR-0009-voice-prompts-on-pause) (#135)
- add /validate-idea skill — lightweight pre-spec gate (#131)
- add /fan-out skill + parallel-work rule doc (#128)
- add /tickets-batch skill for bulk-file flow (#127)

### Fixed (fix)

- gitignore agent-routing.local.yaml and .mcp.json (#867)
- subagent-aware auto-code-review + blocking rex-marker guard (#865)
- repoint rex-770, add defect-in-diff validator guard, grow corpus (#864)
- Cursor adapter must install at user-level hooks.json, not project (#847)
- subdir install layout for pi + opencode adapters (#845)
- key all approval markers on the PR base repo (cross-fork) (#770)
- resolve {owner/repo} placeholder in /roadmap tracker_create flow (#810)
- pr-create validator — expand tilde before git -C + stop over-matching gh issue create (#792)
- make red-CI merge gate forge-aware (gh/glab), fail-closed (#793)
- route migration gate through tracker abstraction (GitLab support) (#760)
- agdr-arch-pr hook — origin-first diff base + raw-command marker haystack (#773)
- anchor release-changelog range on the post-sync boundary (#749)
- anchor active-ticket repo resolution to FILE_PATH not CWD (#747)
- parse gh pr create structurally (body-file, multi-line, body-example) (AgDR-0081) (#748)
- harden warn-review-marker-write guardrail against forged Rex markers (#732)
- block-main-push.sh — handle the -u/--set-upstream push form (#731)
- graceful degrade for tracker.kind=none in /task /feature /bug (#722)
- exempt framework-filing skills from project issue schema (#713)
- resolve ops-root via .apexyard-fork in issue-skill marker (split-portfolio) (#699)
- re-root validate-pr-create + validate-branch-name to the cd-target (#698)
- read --body-file when checking the skip marker + required sections (#697)
- re-root merge-gate repo to cd-target + repo-aware marker writers (#689)
- make hook directory-walks and upstream fetch cross-platform (#691)
- re-root arch-PR diff to the command's cd-target (#688)
- rename jq `def` binding so detection works on jq 1.6 (#686)
- code-reviewer flow is auto-mode-friendly — local marker is the gate signal (#677)
- block-merge-on-red-ci refuses variable-substituted merges instead of guessing (#656)
- escape DOM-sourced email parts in site mailto builder (#639)
- extract_push_ref no longer over-matches arrow in commit messages (#634)
- printf not echo when re-emitting captured JSON (pre-push-gate + tracker) (#632)
- config_get dropped ALL overrides when config had a backslash escape (#630)
- game score over max — level1 + levelTemp double-counted (#615)
- embedding level — replace drag-into-plane with tap-to-group (mobile) (#610)
- game mobile-responsive pass + #apexyard share + loop-engineering level (#603)
- exempt .claude/, /tmp, rm, and $VAR targets from bash-write ticket gate (#582)
- PR extractor ignores redirection tokens + unexpanded var args (#581)
- block-main-push checks the operation's target branch, not session cwd (#580)
- pre-push markdownlint lints tracked files only (#567)
- parse git-push dst ref, ignore redirections + tag pushes (#566)
- tag the squash commit on main + ancestry guard in /release (#565)
- resolve review-marker home pin-first in Rex + /approve-merge (#564)
- guard hero pill + releases metric against version drift (#563)
- block build-agent self-review — require a real GitHub review behind the rex marker (#504)
- release site-version bump + correct issue-filing version on dev + tracker shape-only fallback (#505)
- repo-qualify review markers to prevent same-PR-number collision across repos (#486)
- make code-reading sub-agents MCP-first (#477)
- suggest-mcp-search surfaces to the agent + install-gates (#470)
- PR-create hooks resolve PR origin repo, not session ops-fork (#465)
- require --merge for sync PRs; guard --squash in hook (#463)
- replace truncating sed extractor in require-agdr-for-arch-pr.sh with greedy awk (#462)
- inline helper-source in /dfd write blocks + strengthen Write targets rule (#445)
- warn at SessionStart when Ollama routing is INACTIVE; promote shell-profile step in docs (#444)
- catch split-portfolio v2 silent fallbacks for workspace_dir and projects/ (#441)
- route SETUP step 1 onboarding.yaml through portfolio helper (#437)
- promote /handover MCP reindex to named step + add advisory hook (#439)
- configure branch protection on private portfolio repo after split-portfolio (#431)
- update wrapper test to v2 shape + guard against v1 regression (#430)
- merge hook handles compound marker-write + merge commands (#427)
- hook walker reads session pin before walk-up (#425)
- guard bootstrap exemption scope — /handover only (#423)
- reorder case patterns to satisfy shellcheck SC2221
- remove stale --pdf-output-folder flag from md-to-pdf dispatch (#405)
- mobile UX regressions — nav main pages + eyebrow + content polish (#394)
- pin ops-root via CLAUDE_CODE_SESSION_ID SessionStart hook (#385)
- refine gh api matcher to only block POST on /issues (#384)
- replace `|| echo "0"` with `|| true` in code-quality.yml (#375)
- hook wrappers silent no-op outside an apexyard fork (#371)
- /split-portfolio produces v2 layout + copy-onboarding semantics (#335)
- resolve config from ops-fork root, not workspace clone (#313)
- additive ui_paths_exclude carve-out for require-design-review-for-ui (#277)
- greedy body extractor — no more truncation at embedded quotes (#264)
- align merge gates + agent + skill on ops-fork marker path (#240)
- make verify-commit-refs and validate-pr-create consult upstream remote (#211)
- validation hooks read git context from command, not $PWD (#198)
- CHANGELOG fallback in drift hook for squash-merged forks (#129)

### Changed (refactor / chore / docs / ci / perf / test)

- remove broken Star History chart (#860)
- bump the codeql-action group with 3 updates (#857)
- Merge pull request #858 from me2resh/sync/main-to-dev-after-v4.4.0
- merge main into dev after v4.4.0 release
- add a non-Claude-Code on-ramp to the README (#854)
- make harness-support tables user-readable (#852)
- harness capability tables reflect live conformance results (#846)
- adapter-family hardening — generator fail-loud, timeout, warn-loud, pi derive-gates convergence (#842)
- refresh harness matrices + cursor/opencode pages to merged reality (#841)
- harness support matrix + docs/harnesses/ index (#836)
- eval-agents hardening follow-ups from the #828 reviews (#837)
- reconcile duplicate AgDR-0082 — renumber handover-badge to AgDR-0090 (#835)
- add hossam-96 to the Contributors list (#830)
- calibrate LLM-judge against real ship/reject outcomes (#827)
- least-privilege permissions + SHA-pin actions in CI (#826)
- discard spikes #466/#660 (memos) + state Git Bash as Windows prereq (#823)
- least-privilege workflow permissions + SHA-pin actions (#820)
- prove pi extension can gate merges by shelling out to bash hook (#814)
- repo-targeting convention — always explicit --repo (#811)
- combine codeql-action init+analyze bump + group github-actions (#808)
- bump DavidAnson/markdownlint-cli2-action from 23.2.0 to 24.0.0 (#799)
- bump github/codeql-action/upload-sarif from 4.36.2 to 4.36.3 (#802)
- README pain-story hook + technical detail to sub-doc + adopter badge (#797)
- correct /plan-initiative active-issue-skill marker wording (#786)
- Merge pull request #781 from me2resh/sync/main-to-dev-after-v4.3.0
- merge main into dev after v4.3.0 release
- add star-history chart to README (#757)
- Merge pull request #752 from me2resh/sync/main-to-dev-after-v4.2.0
- merge main into dev after v4.2.0 release
- Merge pull request #738 from me2resh/sync/main-to-dev-after-v4.1.0
- merge main into dev after v4.1.0 release
- Merge pull request #717 from me2resh/sync/main-to-dev-after-v4.0.0
- merge main into dev after v4.0.0 release
- bump actions/checkout from 6.0.3 to 7.0.0 (#684)
- Merge pull request #685 from me2resh/sync/main-to-dev-after-v3.3.0
- merge main into dev after v3.3.0 release
- set scorecard publish_results false to stop the action failing (#680)
- add Code of Conduct + fix stale counts (#678)
- document orchestrator cost model + cost levers (#676)
- remove extracted marketing site (now lives in apexyard-site) (#664)
- Merge pull request #659 from me2resh/sync/main-to-dev-after-v3.2.0
- merge main into dev after v3.2.0 release
- harden workflows — SHA-pin all Actions + least-privilege permissions (#636)
- bump actions/checkout from 4 to 6 (#598)
- Merge pull request #623 from me2resh/sync/main-to-dev-after-v3.1.4
- merge main into dev after v3.1.4 release
- game — repoint outro footer off LangGraph, fix stale intro, add game OG image (#620)
- Merge pull request #618 from me2resh/sync/main-to-dev-after-v3.1.3
- merge main into dev after v3.1.3 release
- Merge pull request #613 from me2resh/sync/main-to-dev-after-v3.1.2
- merge main into dev after v3.1.2 release
- Merge pull request #608 from me2resh/sync/main-to-dev-after-v3.1.1
- merge main into dev after v3.1.1 release
- pin ossf/scorecard-action to v2.4.3 (#601)
- Merge pull request #599 from me2resh/sync/main-to-dev-after-v3.1.0
- carry forward site/index.html from main after v3.1.0 release
- merge main into dev after v3.1.0 release
- bump upload-artifact v4->v7 + codeql-action v3->v4 (#593)
- bump DavidAnson/markdownlint-cli2-action from 16 to 23 (#543)
- bump actions/github-script from 7 to 9 (#542)
- bump gitleaks/gitleaks-action from 2 to 3 (#540)
- exempt dependabot/sync branches from ticket-ID check; target dev (#589)
- re-fork & data-preservation guide in upgrading.md (#561)
- exempt sync/ branches from the PR-create ticket-ID rule (#546)
- Merge pull request #544 from me2resh/sync/main-to-dev-after-v3.0.0
- merge main into dev after v3.0.0 release
- open-source community-health files + README refresh (#537)
- drain quarantine — pin-escape audit fix + handover rewrite (#533)
- fix + un-quarantine agent_routing_sync_and_drift (#530)
- fix + un-quarantine 3 of 5 hook-test failures (#529)
- gate the hook test suite in CI (#527)
- onboarding guard — literal filename match (grep -Fxq) (#525)
- relax release-gated semgrep to fail-on-ERROR (#521)
- Merge pull request #516 from me2resh/chore/onboarding-reset
- reset onboarding.yaml to template placeholders
- Merge pull request #510 from me2resh/sync/GH-508-main-to-dev-after-v2.3.0
- carry forward CHANGELOG.md from main after v2.3.0 release
- merge main into dev after v2.3.0 release
- wire pre-push-gate to the framework CI checks + add git pre-push hook (#507)
- bump marketing-site framework version to 2.2.0 (#492)
- release-gated security scan on the framework repo (dog-food the Shield pipeline) (#488)
- whitelist `sync` type across branch/commit/PR validators (#460)
- main→dev sync after v2.2.0 release (#457)
- Merge remote-tracking branch 'upstream/dev' into chore/sync-upstream-dev
- add split-portfolio v2 marker + sync onboarding.yaml from portfolio
- sync CHANGELOG.md from main to dev (#447)
- Merge pull request #422 from atlas-apex/feature/GH-418-mcp-search-first
- ship 6 site/ binary assets — OG previews + favicons (#383)
- drop @docs/multi-project.md auto-import from CLAUDE.md (#380)
- multi-project workspace + conflict-skip + README preservation (Case 5) (#368)
- /debug 'when to invoke' sidebar in workflows/sdlc.md Phase 3 (#366)
- wave-2 cleanup bundle — drop allowed_tools_override + push-gate scope + multi-line drift (#364)
- AgDR-0050 — agent runtime overhaul (cross-cutting design for #347 + #348 + #351) (#352)
- /setup + /update step 8a test infrastructure (#349)
- align v1→v2 manual recipe in docs/multi-project.md with AgDR-0021 § H copy-onboarding semantics (#350)
- AgDR-0047 for framework packaging & distribution (#343)
- site/ count refresh + meta-tag polish + content-shape + markdown alternates (#340)
- rename /generative-engine-audit to /geo-audit (#339)
- site/ AI-readiness + classic SEO infrastructure (#337)
- token-efficiency Wave 1 — ~2.9k tokens saved at session start (#328)
- sweep all 40 hook wrappers to v2-anchor-aware shape (#306)
- generic cleanup (#304)
- /learn feasibility — dry-run report (#247)
- retrofit 7 audit skills onto _lib-audit-history.sh (#239)
- add Data Flow Diagram section to threat-model template (#225)
- plan-mode usage rule — when to enter (#220)
- /setup emits verified LSP plugin-install commands (#216)
- give every role + agent an Arabic persona name (#212)
- Claude tier-routing spike — measurement + recommendation (#201)
- local-model routing spike — measurement + recommendation (#196)
- document ENABLE_LSP_TOOL opt-in + per-language LSP plugin install (#193)
- annotate LSP-aware skills with opt-in callouts (#191)
- LSP integration spike — measurement + recommendation (#184)
- sync CHANGELOG.md from main → dev (#174)
- exempt release/vN.N.N from validate-pr-create's branch-id check (#171)
- accept release/vN.N.N branches + release(...) PR titles (#169)
- default the split-portfolio sibling repo name to <fork>-portfolio (#164)
- remove voice-prompts feature + correct hook/skill counts (#161)
- mock gh in test sandboxes to remove live-tracker dependency (#156)
- extend Bash-write matcher beyond first-version coverage (#155)
- correct privacy-gate wording — adopter action, not framework auto-publish (#149)
- document split-portfolio mode + add /setup privacy gate (#144)
- adopt release-cut branch model (dev/main + tags) — framework only (#126)
- enforce single Closes-keyword per PR body (#125)
- require Testing section in PR body (config-driven) (#124)
- add require-agdr-for-arch-pr.sh PreToolUse hook (#123)
- add validate-issue-structure.sh PreToolUse hook (#122)
- upgrade pre-push-gate from advisory reminder to blocking check-runner (#121)
- add warn-stale-review-markers.sh PostToolUse hook (#120)
- add block-private-refs-in-public-repos.sh hook (#119)
- project-configurable ticket / branch / commit / PR schema (#118)

## [v4.4.0] — 2026-07-09

Minor release — 17 features,7 fixes,20 improvements.

### Added (feat)

- (#850) harness-selection step in /setup and /handover — 67ec274
- (#821) opencode gate adapter — enforce apexyard gates via a plugin over the bash hooks — 526c6e3
- (#831) Cursor gate adapter — generate .cursor/hooks.json delegating to the bash hooks — 8c2b384
- (#824) /eval-agents — score review agents against frozen ground-truth defect sets — 8ea78c3
- (#729) add Codex adapter generator — deb4342
- (#68) Structurizr DSL as escape hatch for L3+ C4 diagrams — 1afb1d8
- (#815) multi-harness gate adapter for pi.dev — 25211b3
- (#805) pi.dev AGENTS.md bridge (advisory rules for pi) — df35bd3
- (#759) route /approve-merge's merge command through tracker_pr_merge (gh/glab) — be0dbd9
- (#798) /handover offers a Governed-by-ApexYard badge to onboarded repos — b4dc069
- (#763) route /security-review + /design-review through tracker_review_submit — 557c3be
- (#758) route /code-review through tracker-agnostic review submission — abf0d79
- (#764) make merge-gate HEAD/merge-detection forge-aware (gh/glab) — f9f4541
- (#753) docs-index hook — auto-maintain per-project docs/INDEX.md + nudge — 1b960a2
- (#789) guard the agent-spawn boundary with a role-selection rule — d91652b
- (#787) safe-by-default isolated builds via git worktrees (rule + advisory guard) — 3fc95fb
- (#782) reporting-style rule + human-report output style — 9641cf4

### Fixed (fix)

- (#840) Cursor adapter must install at user-level hooks.json, not project — 63361f4
- (#844) subdir install layout for pi + opencode adapters — 341825d
- (#765) key all approval markers on the PR base repo (cross-fork) — c06f8c5
- (#810) resolve {owner/repo} placeholder in /roadmap tracker_create flow — 8c2bf53
- (#791) pr-create validator — expand tilde before git -C + stop over-matching gh issue create — 9df643b
- (#790) make red-CI merge gate forge-aware (gh/glab), fail-closed — d6e6630
- (#755) route migration gate through tracker abstraction (GitLab support) — 35146fc

### Changed (refactor / chore / docs)

- (#853) add a non-Claude-Code on-ramp to the README — 8424b4e
- (#851) make harness-support tables user-readable — fd45d44
- (#840) harness capability tables reflect live conformance results — c1cb807
- (#840) adapter-family hardening — generator fail-loud, timeout, warn-loud, pi derive-gates convergence — bac2792
- (#840) refresh harness matrices + cursor/opencode pages to merged reality — 8b014d3
- (#834) harness support matrix + docs/harnesses/ index — 0aea22d
- (#833) eval-agents hardening follow-ups from the #828 reviews — 3f8ff0f
- (#832) reconcile duplicate AgDR-0082 — renumber handover-badge to AgDR-0090 — e0080d0
- (#829) add hossam-96 to the Contributors list — 70121bf
- (#825) calibrate LLM-judge against real ship/reject outcomes — 460bef1
- (#819) least-privilege permissions + SHA-pin actions in CI — 333a831
- (#466) discard spikes #466/#660 (memos) + state Git Bash as Windows prereq — 63d9a14
- (#819) least-privilege workflow permissions + SHA-pin actions — e1b14a0
- (#804) prove pi extension can gate merges by shelling out to bash hook — eb98997
- (#811) repo-targeting convention — always explicit --repo — c0a0b6c
- (#808) combine codeql-action init+analyze bump + group github-actions — 04df622
- (#799) bump DavidAnson/markdownlint-cli2-action from 23.2.0 to 24.0.0 — 731d16c
- (#802) bump github/codeql-action/upload-sarif from 4.36.2 to 4.36.3 — 1c7fdbc
- (#795) README pain-story hook + technical detail to sub-doc + adopter badge — 8968764
- (#775) correct /plan-initiative active-issue-skill marker wording — 3a80bca

### Closes

- Closes #68, #466, #729, #753, #755, #758, #759, #763, #764, #765, #775, #782, #787, #789, #790, #791, #795, #798, #799, #802, #804, #805, #808, #810, #811, #815, #819, #821, #824, #825, #829, #831, #832, #833, #834, #840, #844, #850, #851, #853

## [v4.3.0] — 2026-07-04

Minor release — 2 features, 1 fix, 1 docs improvement. Headlined by the
**trust-chain security trigger**: the adversarial Security Auditor now
auto-fires on any change to the framework's own enforcement layer
(`.claude/hooks/**` + `.claude/settings.json`), not just auth/crypto/secrets
paths — closing the gap that let enforcement-layer bugs reach review with only
a generalist code-review pass.

**Tracker/forge scope note.** Issue *creation* is now tracker-agnostic across
the remaining creator skills (gh/glab/custom). Merge-gate and review-*posting*
enforcement remain GitHub-first — forge-aware review submission (#758 / #763)
and merge-gating (#764) are in progress on the #711 epic and are **not** in this
release. GitLab adopters can create tickets tracker-agnostically but should not
yet rely on forge-aware merge gating.

### Added (feat)

- (#777) auto-invoke the Security Auditor on trust-chain changes — fac3547
- (#709) route remaining creator skills + label helper through tracker abstraction — 6f515e3

### Fixed (fix)

- (#769) agdr-arch-pr hook — origin-first diff base + raw-command marker haystack — c342be8

### Changed (refactor / chore / docs)

- (#756) add star-history chart to README — b98bb28

### Closes

- Closes #709, #756, #769, #777

## [v4.2.0] — 2026-06-28

Minor release — 2 features, 3 fixes.

### Added (feat)

- (#741) wire design tooling into roles + add /design-sync skill — f324b59
- (#740) offer an opt-in /challenge nudge from /decide — 4cd59a7

### Fixed (fix)

- (#737) anchor release-changelog range on the post-sync boundary — ee35238
- (#744) anchor active-ticket repo resolution to FILE_PATH not CWD — 029c676
- (#743) parse gh pr create structurally (body-file, multi-line, body-example) (AgDR-0081) — 620da46

### Closes

- Closes #737, #740, #741, #743, #744

## [v4.1.0] — 2026-06-27

Minor release — 1 feature,3 fixes.

### Added (feat)

- (#725) auto-move board cards through the SDLC lifecycle — 5897132

### Fixed (fix)

- (#728) harden warn-review-marker-write guardrail against forged Rex markers — 2521bd2
- (#727) block-main-push.sh — handle the -u/--set-upstream push form — dea022e
- (#718) graceful degrade for tracker.kind=none in /task /feature /bug — 1f2580e

### Closes

- Closes #718, #725, #727, #728

## [v4.0.0] — 2026-06-25

Major release — 100 features, 58 fixes, 76 improvements.

### Added (feat)

- (#670) route /task /feature /bug through tracker_create — ab0f57c
- (#704) add The Contrarian — advisory premise-level adversary agent — 72f6ad2
- (#705) add golden-path macOS build + release pipeline template — 563e07c
- (#670) tracker_create creation abstraction (gh/glab/custom) — 8fe58a0
- (#701) add golden-path Terraform CI pipeline template — e4e9982
- (#670) per-project tracker config resolution — 1de9c7f
- (#672) add /walking-skeleton + /prototype skills — 0544797
- (#674) automate /release — one-command bump + changelog + release PR — 2072eb5
- (#675) /handover offers in-repo AGENTS.md generation — 1ffb639
- (#653) detect (and offer to enable) GitHub Issues in /setup + /handover — e7c5c09
- (#651) opt-in gate mode for suggest-mcp-search.sh (force MCP-first on exploratory search) — 77dfa05
- (#641) consent-gated GA + cookie banner on all site pages — 88b8b8f
- (#626) grant Rex search_code + prefer semantic search when available — 3c2529a
- (#627) support fallow static analysis in code review — 32eaff6
- (#606) game — Skip level (forfeit to 0) for stuck players — ebd3582
- (#594) governed looping — loop-mode trigger rule + AgDR-0068 — 9797a29
- (#585) interactive LLM game on the site with social score-sharing — fe743f9
- (#518) harden framework security scanning (code parts) — f617039
- (#513) per-worktree ticket marker tier (fix same-project concurrent-agent collision) — 5c0b8ee
- (#517) keep onboarding config out of git (example-file + gitignore + guard) — 3c1e728
- (#520) add reusable Swift CI golden-path pipeline — b4ba5ab
- (#489) fire the MCP-search advisory on Read/Glob/Grep for workspace paths — fdad663
- (#482) /report-apexyard-bug + /request-apexyard-feature (upstream framework feedback) — 7b39bcc
- (#478) suggest MCP reindex after a workspace clone is pulled/updated — fb367b8
- (#480) /handover checklist-first doc selection + template pick — b66fcf6
- (#473) /launch-check --workflow — opt-in parallel + adversarially-verified audit — ec0727f
- (#471) Solution Architect — independent design-review role/agent (Rex for non-code) — f86f843
- (#451) /release-sync carries forward CHANGELOG.md from main to dev — 95fd084
- (#450) Rex semantic handbook supplement via MCP search_docs — d7519f4
- (#438) Ollama/LiteLLM agent routing — reachability + model-pulled checks + session-wide ANTHROPIC_BASE_URL — add9c79
- (#417) clone repo immediately at step 1.5 when URL given in /handover — 587048a
- (#428) auto-reindex MCP search after /handover clones a project — 4a3e7bb
- (#418) enforce MCP search-first pattern with advisory hooks — bbf4453
- (#403) /release-sync — main→dev sync after each release — 39f4b6e
- (#386) rewrite site/ for outcomes-led positioning to non-tech founders — b9ed8cd
- (#377) /plan-initiative — initiative → milestones → tasks (DAG + topo-sort + two-pass filing) — ac087b7
- (#376) /handover offers to file Next Steps as tracker tickets — 7879c0d
- (#333) site AI-readiness polish — agent-permissions, llm:* meta, Copy-for-AI button — ada6836
- (#327) clean URLs without .html via Netlify _redirects rewrites — 8c86328
- (#351) local-routing — Claude default + 4 commented candidates by hardware (Wave 2 PR 4) — dc83764
- (#351) /setup seeds agent-routing.yaml + 8th portfolio config key (Wave 2 PR 3) — 8be449c
- (#347) class-aware role-trigger banner — HYBRID spawn vs in-thread (Wave 2 PR 5) — 4ca8f30
- (#347) promote utility agents to per-agent model: frontmatter (Wave 2 PR 4) — 4baae6d
- (#351) agent-routing sync hook + pre-commit/pre-push drift guards (Wave 1 PR 2) — 12484a0
- (#347) promote product + design roles to sub-agents (Wave 3 PR 2) — 5b37d69
- (#347) promote engineering-dept roles to sub-agents + Activation mode (Wave 1 PR 1) — 1e78cfd
- (#351) agent-routing.yaml schema + portfolio_agent_routing resolver (Wave 1 PR 1) — cfdac35
- (#321) audit-pack + safety-hooks marketplace plugins — 5fe91d4
- (#297) harness templates by topology — TS NextJS / Python FastAPI / Go data pipeline — 6c0dc3f
- (#299) /mutation-test skill + behaviour-quality sensor — 8cca818
- (#311) /generative-engine-audit — LLM/agent SEO sibling to /seo-audit — 5ab092c
- (#312) PR summary narrative-quality rule + Rex advisory check — 550322d
- (#298) /handover scores harnessability + warns on low blast-radius — dc81460
- (#296) /codify-rule — turn human review comments into draft handbook entries — 20ac99b
- (#290) /extract-features --with-mockups (AI-inferred ASCII wireframes) — bc4b56b
- (#295) standardise self-correction guidance across blocking hooks (shape + 5 retrofits) — 4cebf94
- (#280) declare jq as a hard dependency — Option A — bd5c29e
- (#293) Rex domain-aware code review — handbooks/domain/ Stage 1 — 2d514cf
- (#283) tracker-aware hooks + _lib-tracker.sh dispatcher — ac89541
- (#288) /feature-diagram skill for per-feature Mermaid sub-graphs — 5b7ece9
- (#282) /update walks intermediate-release migration chain — 39bbaa4
- (#284) /pdf — export any framework-generated doc to PDF, with destination prompt — 40552c6
- (#281) uniform ticket templates + custom-templates/ override — a4efbf2
- (#268) skill-gated ticket-create hook (multi-tracker) — 456272b
- (#270) /threat-model inlines DFD as point-in-time snapshot at audit time — 2aae484
- (#266) mermaid lint per emitting skill (/c4, /dfd, /tech-vision) — 94ed7a7
- (#271) add site/architecture.html — 5-layer diagram, recoloured to site palette — 43a5970
- (#246) /tech-vision skill — interactive author for architecture vision — 7de6b64
- (#245) /investigation skill + template for sustained root-cause work — 999e1b7
- (#257) /dfd skill — extract Data Flow Diagram with trust boundaries + classifications — 7c33016
- (#256) /process skill — extract process from code, BPMN 2.0 output — 3d8b75c
- (#255) /threat-model --format=dragon for OWASP Threat Dragon JSON export — 7c5f49d
- (#243) private repo houses company custom skills + cross-org handbooks — 40439ff
- (#250) /update --from-dev hidden flag for pre-release sync — 1020e01
- (#249) /extract-features skill for greenfield rewrite inventories — df5b006
- (#244) custom templates layer with override semantics — 3dafe92
- (#242) split-portfolio v2 — workspace + onboarding to private repo — 90384bb
- (#232) adopter handbooks consumed by Rex during code review — 5de6c95
- (#224) add architecture vision + DFD + sequence templates — f795d35
- (#218) audit-skill artefact persistence + canonical structure — 227beb3
- (#205) role-activation visibility markers convention — 0f054ee
- (#206) mechanical role-trigger detection with non-blocking reminder injection — c4545e6
- (#208) /setup auto-enables LSP — language detection + install + env var + plugin — b060e75
- (#180) /spike skill — hypothesis-driven throw-away ticket type — 9bc54b5
- (#179) /journey skill — single-file user-journey HTML with modal-per-page — 5fd5b9e
- (#177) /update detects deprecated config keys + offers cleanup — 033c789
- (#188) /handover offers clone-first deep-dive prompt — 550893f
- (#182) /status --briefing + bin/apexyard status CLI shim — 78b23d9
- (#183) /launch-check trend tracking — b42c7f3
- (#181) /agdr skill — searchable AgDR library — d2fc34b
- (#165) skills reference page on the landing site + changelog link — 22f795f
- (#160) multi-tab terminal demo on the landing site — d17765a
- (#132) structured CEO marker + same-turn merge in /approve-merge — aab0457
- (#150) bootstrap-skill exemption + Bash-write coverage — 64457d2
- (#145) portfolio config + self-healing + /split-portfolio helper — 271d319
- (#141) add /debug skill — structured hypothesis-driven debugging — bb458b8
- (#135) configurable voice prompts on assistant pause (AgDR-0009-voice-prompts-on-pause) — a79a62a
- (#130) add /validate-idea skill — lightweight pre-spec gate — 88784a4
- (#117) add /fan-out skill + parallel-work rule doc — 4544990
- (#108) add /tickets-batch skill for bulk-file flow — dea0055

### Fixed (fix)

- (#712) exempt framework-filing skills from project issue schema — 1f78db0
- (#694) resolve ops-root via .apexyard-fork in issue-skill marker (split-portfolio) — 63f1058
- (#693) re-root validate-pr-create + validate-branch-name to the cd-target — 8cd3bbd
- (#695) read --body-file when checking the skip marker + required sections — acbb58b
- (#687) re-root merge-gate repo to cd-target + repo-aware marker writers — fe81340
- (#690) make hook directory-walks and upstream fetch cross-platform — 6c599c0
- (#669) re-root arch-PR diff to the command's cd-target — ec2331b
- (#686) rename jq `def` binding so detection works on jq 1.6 — cfdd22f
- (#677) code-reviewer flow is auto-mode-friendly — local marker is the gate signal — 51f279e
- (#643) block-merge-on-red-ci refuses variable-substituted merges instead of guessing — ff3bcfc
- (#638) escape DOM-sourced email parts in site mailto builder — 3116eed
- (#584) extract_push_ref no longer over-matches arrow in commit messages — 20c7554
- (#631) printf not echo when re-emitting captured JSON (pre-push-gate + tracker) — 1785e90
- (#629) config_get dropped ALL overrides when config had a backslash escape — cd4bfbe
- (#614) game score over max — level1 + levelTemp double-counted — 2224a53
- (#609) embedding level — replace drag-into-plane with tap-to-group (mobile) — 583e8a6
- (#602) game mobile-responsive pass + #apexyard share + loop-engineering level — b3e9f4a
- (#569) exempt .claude/, /tmp, rm, and $VAR targets from bash-write ticket gate — be50036
- (#568) PR extractor ignores redirection tokens + unexpanded var args — 7da5984
- (#549) block-main-push checks the operation's target branch, not session cwd — eaa0fa9
- (#548) pre-push markdownlint lints tracked files only — 98a0aba
- (#547) parse git-push dst ref, ignore redirections + tag pushes — 2b41158
- (#550) tag the squash commit on main + ancestry guard in /release — 63b72bf
- (#559) resolve review-marker home pin-first in Rex + /approve-merge — 50b54a5
- (#562) guard hero pill + releases metric against version drift — a7f5f34
- (#494) block build-agent self-review — require a real GitHub review behind the rex marker — 471a74a
- (#493) release site-version bump + correct issue-filing version on dev + tracker shape-only fallback — b149c4e
- (#485) repo-qualify review markers to prevent same-PR-number collision across repos — 417e326
- (#475) make code-reading sub-agents MCP-first — 42c8fb5
- (#469) suggest-mcp-search surfaces to the agent + install-gates — d8862f1
- (#464) PR-create hooks resolve PR origin repo, not session ops-fork — 5638132
- (#459) require --merge for sync PRs; guard --squash in hook — 2961d4d
- (#461) replace truncating sed extractor in require-agdr-for-arch-pr.sh with greedy awk — dfe35ba
- (#443) inline helper-source in /dfd write blocks + strengthen Write targets rule — d12c460
- (#442) warn at SessionStart when Ollama routing is INACTIVE; promote shell-profile step in docs — 3848cb1
- (#373) catch split-portfolio v2 silent fallbacks for workspace_dir and projects/ — d638dbf
- (#434) route SETUP step 1 onboarding.yaml through portfolio helper — 84eae45
- (#433) promote /handover MCP reindex to named step + add advisory hook — 03ed05a
- (#415) configure branch protection on private portfolio repo after split-portfolio — 1d107d8
- (#414) update wrapper test to v2 shape + guard against v1 regression — c98a262
- (#426) merge hook handles compound marker-write + merge commands — be1479c
- (#424) hook walker reads session pin before walk-up — a2e7c36
- (#419) guard bootstrap exemption scope — /handover only — d24c762
- (#418) reorder case patterns to satisfy shellcheck SC2221 — 3b217f9
- (#404) remove stale --pdf-output-folder flag from md-to-pdf dispatch — 47a438f
- (#393) mobile UX regressions — nav main pages + eyebrow + content polish — 0ba64e1
- (#381) pin ops-root via CLAUDE_CODE_SESSION_ID SessionStart hook — fbc1cff
- (#382) refine gh api matcher to only block POST on /issues — 1f86db3
- (#375) replace `|| echo "0"` with `|| true` in code-quality.yml — 3942789
- (#370) hook wrappers silent no-op outside an apexyard fork — fa327e0
- (#317) /split-portfolio produces v2 layout + copy-onboarding semantics — a075c9a
- (#310) resolve config from ops-fork root, not workspace clone — 4b81bde
- (#275) additive ui_paths_exclude carve-out for require-design-review-for-ui — 14b651b
- (#227) greedy body extractor — no more truncation at embedded quotes — 227b3b4
- (#229) align merge gates + agent + skill on ops-fork marker path — c419666
- (#207) make verify-commit-refs and validate-pr-create consult upstream remote — 02eeb1a
- (#194) validation hooks read git context from command, not $PWD — ffb44b0
- (#106) CHANGELOG fallback in drift hook for squash-merged forks — dd85a13

### Changed (refactor / chore / docs)

- (#684) bump actions/checkout from 6.0.3 to 7.0.0 — 43b9c6b
- (#679) set scorecard publish_results false to stop the action failing — 2f572ec
- (#536) add Code of Conduct + fix stale counts — 9307f75
- (#676) document orchestrator cost model + cost levers — fbc0668
- (#663) remove extracted marketing site (now lives in apexyard-site) — 19f406d
- (#635) harden workflows — SHA-pin all Actions + least-privilege permissions — dc588e1
- (#598) bump actions/checkout from 4 to 6 — 3c141b5
- (#619) game — repoint outro footer off LangGraph, fix stale intro, add game OG image — cb701c7
- (#600) pin ossf/scorecard-action to v2.4.3 — 771e2ea
- (#590) bump upload-artifact v4->v7 + codeql-action v3->v4 — 38dcf45
- (#543) bump DavidAnson/markdownlint-cli2-action from 16 to 23 — 4c8352a
- (#542) bump actions/github-script from 7 to 9 — 4c2a3cb
- (#540) bump gitleaks/gitleaks-action from 2 to 3 — 4b69896
- (#588) exempt dependabot/sync branches from ticket-ID check; target dev — 207a761
- (#560) re-fork & data-preservation guide in upgrading.md — 28b34fe
- (#545) exempt sync/ branches from the PR-create ticket-ID rule — f2ed536
- (#536) open-source community-health files + README refresh — 6ac3373
- (#528) drain quarantine — pin-escape audit fix + handover rewrite — afbb26c
- (#528) fix + un-quarantine agent_routing_sync_and_drift — 41d1051
- (#528) fix + un-quarantine 3 of 5 hook-test failures — 9bd0e17
- (#526) gate the hook test suite in CI — 1027dbc
- (#517) onboarding guard — literal filename match (grep -Fxq) — 1822767
- (#511) relax release-gated semgrep to fail-on-ERROR — 2422927
- reset onboarding.yaml to template placeholders — 9730435
- (#506) wire pre-push-gate to the framework CI checks + add git pre-push hook — 94a6a0f
- (#492) bump marketing-site framework version to 2.2.0 — e93562c
- (#487) release-gated security scan on the framework repo (dog-food the Shield pipeline) — 4509ebf
- (#458) whitelist `sync` type across branch/commit/PR validators — 02dc105
- (#456) main→dev sync after v2.2.0 release — 2314e2f
- Merge remote-tracking branch 'upstream/dev' into chore/sync-upstream-dev — 16f2e42
- add split-portfolio v2 marker + sync onboarding.yaml from portfolio — de9069c
- (#447) sync CHANGELOG.md from main to dev — e8208bd
- (#341) ship 6 site/ binary assets — OG previews + favicons — 0526aac
- (#372) drop @docs/multi-project.md auto-import from CLAUDE.md — 0f6ca08
- (#320) multi-project workspace + conflict-skip + README preservation (Case 5) — 9ddbe2b
- (#354) /debug 'when to invoke' sidebar in workflows/sdlc.md Phase 3 — 008aaf0
- (#358) wave-2 cleanup bundle — drop allowed_tools_override + push-gate scope + multi-line drift — 47b557a
- (#347) AgDR-0050 — agent runtime overhaul (cross-cutting design for #347 + #348 + #351) — 17942fc
- (#318) /setup + /update step 8a test infrastructure — e135a0b
- (#350) align v1→v2 manual recipe in docs/multi-project.md with AgDR-0021 § H copy-onboarding semantics — 5d54641
- (#265) AgDR-0047 for framework packaging & distribution — e6a6d71
- (#325) site/ count refresh + meta-tag polish + content-shape + markdown alternates — 7668e91
- (#334) rename /generative-engine-audit to /geo-audit — 7567739
- (#329) site/ AI-readiness + classic SEO infrastructure — cb00fa9
- (#322) token-efficiency Wave 1 — ~2.9k tokens saved at session start — 2ccefa4
- (#302) sweep all 40 hook wrappers to v2-anchor-aware shape — ad42d0d
- (#303) generic cleanup — e4aa82a
- (#241) /learn feasibility — dry-run report — e1953b4
- (#221) retrofit 7 audit skills onto _lib-audit-history.sh — c8b292e
- (#223) add Data Flow Diagram section to threat-model template — fc54ace
- (#219) plan-mode usage rule — when to enter — 5eccc0f
- (#215) /setup emits verified LSP plugin-install commands — 526e9b7
- (#204) give every role + agent an Arabic persona name — 88f9dae
- (#197) Claude tier-routing spike — measurement + recommendation — e435719
- (#195) local-model routing spike — measurement + recommendation — 20d9974
- (#189) document ENABLE_LSP_TOOL opt-in + per-language LSP plugin install — 8e753f6
- (#190) annotate LSP-aware skills with opt-in callouts — fa72b0a
- (#178) LSP integration spike — measurement + recommendation — 9615dea
- (#173) sync CHANGELOG.md from main → dev — 85fe794
- (#170) exempt release/vN.N.N from validate-pr-create's branch-id check — 9873c25
- (#168) accept release/vN.N.N branches + release(...) PR titles — f28096a
- (#163) default the split-portfolio sibling repo name to <fork>-portfolio — 9517b19
- (#157) remove voice-prompts feature + correct hook/skill counts — 327a297
- (#154) mock gh in test sandboxes to remove live-tracker dependency — d4ed533
- (#153) extend Bash-write matcher beyond first-version coverage — 690ada8
- (#148) correct privacy-gate wording — adopter action, not framework auto-publish — 20b071e
- (#143) document split-portfolio mode + add /setup privacy gate — 344da88
- (#116) adopt release-cut branch model (dev/main + tags) — framework only — 3c53ff8
- (#114) enforce single Closes-keyword per PR body — 5a03d9e
- (#113) require Testing section in PR body (config-driven) — e4c09a3
- (#112) add require-agdr-for-arch-pr.sh PreToolUse hook — f23f784
- (#107) add validate-issue-structure.sh PreToolUse hook — 6920060
- (#111) upgrade pre-push-gate from advisory reminder to blocking check-runner — e98633c
- (#115) add warn-stale-review-markers.sh PostToolUse hook — 6e86b95
- (#110) add block-private-refs-in-public-repos.sh hook — a4edb89
- (#109) project-configurable ticket / branch / commit / PR schema — 1586d44

### Breaking

- (#347) Hatim→Hakim consolidation + security + data sub-agents (Wave 2 PR 3) — bcbb121

### Closes

- Closes #106, #107, #108, #109, #110, #111, #112, #113, #114, #115, #116, #117, #130, #132, #135, #141, #143, #145, #148, #150, #153, #154, #157, #160, #163, #165, #168, #170, #173, #177, #178, #179, #180, #181, #182, #183, #188, #189, #190, #194, #195, #197, #204, #205, #206, #207, #208, #215, #218, #219, #221, #223, #224, #227, #229, #232, #241, #242, #243, #244, #245, #246, #249, #250, #255, #256, #257, #265, #266, #268, #270, #271, #275, #280, #281, #282, #283, #284, #288, #290, #293, #295, #296, #297, #298, #299, #302, #303, #310, #311, #312, #317, #318, #320, #321, #322, #325, #327, #329, #333, #334, #341, #347, #350, #351, #354, #358, #370, #372, #373, #375, #376, #377, #381, #382, #386, #393, #403, #404, #414, #415, #417, #418, #419, #422, #424, #426, #428, #433, #434, #438, #442, #443, #447, #450, #451, #456, #458, #459, #461, #464, #469, #471, #473, #475, #478, #480, #482, #485, #487, #489, #492, #493, #494, #506, #510, #511, #513, #516, #517, #518, #520, #526, #528, #536, #540, #542, #543, #544, #545, #547, #548, #549, #550, #559, #560, #562, #568, #569, #584, #585, #588, #590, #594, #598, #599, #600, #602, #606, #608, #609, #613, #614, #618, #619, #623, #626, #627, #629, #631, #635, #638, #641, #643, #651, #653, #659, #663, #669, #670, #672, #674, #675, #676, #677, #679, #684, #685, #686, #687, #690, #693, #694, #695, #701, #704, #705, #712

## [v3.3.0] — 2026-06-22

Major release — 94 features, 50 fixes, 75 improvements.

### Added (feat)

- (#672) add /walking-skeleton + /prototype skills — 0544797
- (#674) automate /release — one-command bump + changelog + release PR — 2072eb5
- (#675) /handover offers in-repo AGENTS.md generation — 1ffb639
- (#653) detect (and offer to enable) GitHub Issues in /setup + /handover — e7c5c09
- (#651) opt-in gate mode for suggest-mcp-search.sh (force MCP-first on exploratory search) — 77dfa05
- (#641) consent-gated GA + cookie banner on all site pages — 88b8b8f
- (#626) grant Rex search_code + prefer semantic search when available — 3c2529a
- (#627) support fallow static analysis in code review — 32eaff6
- (#606) game — Skip level (forfeit to 0) for stuck players — ebd3582
- (#594) governed looping — loop-mode trigger rule + AgDR-0068 — 9797a29
- (#585) interactive LLM game on the site with social score-sharing — fe743f9
- (#518) harden framework security scanning (code parts) — f617039
- (#513) per-worktree ticket marker tier (fix same-project concurrent-agent collision) — 5c0b8ee
- (#517) keep onboarding config out of git (example-file + gitignore + guard) — 3c1e728
- (#520) add reusable Swift CI golden-path pipeline — b4ba5ab
- (#489) fire the MCP-search advisory on Read/Glob/Grep for workspace paths — fdad663
- (#482) /report-apexyard-bug + /request-apexyard-feature (upstream framework feedback) — 7b39bcc
- (#478) suggest MCP reindex after a workspace clone is pulled/updated — fb367b8
- (#480) /handover checklist-first doc selection + template pick — b66fcf6
- (#473) /launch-check --workflow — opt-in parallel + adversarially-verified audit — ec0727f
- (#471) Solution Architect — independent design-review role/agent (Rex for non-code) — f86f843
- (#451) /release-sync carries forward CHANGELOG.md from main to dev — 95fd084
- (#450) Rex semantic handbook supplement via MCP search_docs — d7519f4
- (#438) Ollama/LiteLLM agent routing — reachability + model-pulled checks + session-wide ANTHROPIC_BASE_URL — add9c79
- (#417) clone repo immediately at step 1.5 when URL given in /handover — 587048a
- (#428) auto-reindex MCP search after /handover clones a project — 4a3e7bb
- (#418) enforce MCP search-first pattern with advisory hooks — bbf4453
- (#403) /release-sync — main→dev sync after each release — 39f4b6e
- (#386) rewrite site/ for outcomes-led positioning to non-tech founders — b9ed8cd
- (#377) /plan-initiative — initiative → milestones → tasks (DAG + topo-sort + two-pass filing) — ac087b7
- (#376) /handover offers to file Next Steps as tracker tickets — 7879c0d
- (#333) site AI-readiness polish — agent-permissions, llm:* meta, Copy-for-AI button — ada6836
- (#327) clean URLs without .html via Netlify _redirects rewrites — 8c86328
- (#351) local-routing — Claude default + 4 commented candidates by hardware (Wave 2 PR 4) — dc83764
- (#351) /setup seeds agent-routing.yaml + 8th portfolio config key (Wave 2 PR 3) — 8be449c
- (#347) class-aware role-trigger banner — HYBRID spawn vs in-thread (Wave 2 PR 5) — 4ca8f30
- (#347) promote utility agents to per-agent model: frontmatter (Wave 2 PR 4) — 4baae6d
- (#351) agent-routing sync hook + pre-commit/pre-push drift guards (Wave 1 PR 2) — 12484a0
- (#347) promote product + design roles to sub-agents (Wave 3 PR 2) — 5b37d69
- (#347) promote engineering-dept roles to sub-agents + Activation mode (Wave 1 PR 1) — 1e78cfd
- (#351) agent-routing.yaml schema + portfolio_agent_routing resolver (Wave 1 PR 1) — cfdac35
- (#321) audit-pack + safety-hooks marketplace plugins — 5fe91d4
- (#297) harness templates by topology — TS NextJS / Python FastAPI / Go data pipeline — 6c0dc3f
- (#299) /mutation-test skill + behaviour-quality sensor — 8cca818
- (#311) /generative-engine-audit — LLM/agent SEO sibling to /seo-audit — 5ab092c
- (#312) PR summary narrative-quality rule + Rex advisory check — 550322d
- (#298) /handover scores harnessability + warns on low blast-radius — dc81460
- (#296) /codify-rule — turn human review comments into draft handbook entries — 20ac99b
- (#290) /extract-features --with-mockups (AI-inferred ASCII wireframes) — bc4b56b
- (#295) standardise self-correction guidance across blocking hooks (shape + 5 retrofits) — 4cebf94
- (#280) declare jq as a hard dependency — Option A — bd5c29e
- (#293) Rex domain-aware code review — handbooks/domain/ Stage 1 — 2d514cf
- (#283) tracker-aware hooks + _lib-tracker.sh dispatcher — ac89541
- (#288) /feature-diagram skill for per-feature Mermaid sub-graphs — 5b7ece9
- (#282) /update walks intermediate-release migration chain — 39bbaa4
- (#284) /pdf — export any framework-generated doc to PDF, with destination prompt — 40552c6
- (#281) uniform ticket templates + custom-templates/ override — a4efbf2
- (#268) skill-gated ticket-create hook (multi-tracker) — 456272b
- (#270) /threat-model inlines DFD as point-in-time snapshot at audit time — 2aae484
- (#266) mermaid lint per emitting skill (/c4, /dfd, /tech-vision) — 94ed7a7
- (#271) add site/architecture.html — 5-layer diagram, recoloured to site palette — 43a5970
- (#246) /tech-vision skill — interactive author for architecture vision — 7de6b64
- (#245) /investigation skill + template for sustained root-cause work — 999e1b7
- (#257) /dfd skill — extract Data Flow Diagram with trust boundaries + classifications — 7c33016
- (#256) /process skill — extract process from code, BPMN 2.0 output — 3d8b75c
- (#255) /threat-model --format=dragon for OWASP Threat Dragon JSON export — 7c5f49d
- (#243) private repo houses company custom skills + cross-org handbooks — 40439ff
- (#250) /update --from-dev hidden flag for pre-release sync — 1020e01
- (#249) /extract-features skill for greenfield rewrite inventories — df5b006
- (#244) custom templates layer with override semantics — 3dafe92
- (#242) split-portfolio v2 — workspace + onboarding to private repo — 90384bb
- (#232) adopter handbooks consumed by Rex during code review — 5de6c95
- (#224) add architecture vision + DFD + sequence templates — f795d35
- (#218) audit-skill artefact persistence + canonical structure — 227beb3
- (#205) role-activation visibility markers convention — 0f054ee
- (#206) mechanical role-trigger detection with non-blocking reminder injection — c4545e6
- (#208) /setup auto-enables LSP — language detection + install + env var + plugin — b060e75
- (#180) /spike skill — hypothesis-driven throw-away ticket type — 9bc54b5
- (#179) /journey skill — single-file user-journey HTML with modal-per-page — 5fd5b9e
- (#177) /update detects deprecated config keys + offers cleanup — 033c789
- (#188) /handover offers clone-first deep-dive prompt — 550893f
- (#182) /status --briefing + bin/apexyard status CLI shim — 78b23d9
- (#183) /launch-check trend tracking — b42c7f3
- (#181) /agdr skill — searchable AgDR library — d2fc34b
- (#165) skills reference page on the landing site + changelog link — 22f795f
- (#160) multi-tab terminal demo on the landing site — d17765a
- (#132) structured CEO marker + same-turn merge in /approve-merge — aab0457
- (#150) bootstrap-skill exemption + Bash-write coverage — 64457d2
- (#145) portfolio config + self-healing + /split-portfolio helper — 271d319
- (#141) add /debug skill — structured hypothesis-driven debugging — bb458b8
- (#135) configurable voice prompts on assistant pause (AgDR-0009-voice-prompts-on-pause) — a79a62a
- (#130) add /validate-idea skill — lightweight pre-spec gate — 88784a4
- (#117) add /fan-out skill + parallel-work rule doc — 4544990
- (#108) add /tickets-batch skill for bulk-file flow — dea0055

### Fixed (fix)

- (#677) code-reviewer flow is auto-mode-friendly — local marker is the gate signal — 51f270e
- (#643) block-merge-on-red-ci refuses variable-substituted merges instead of guessing — ff3bcfc
- (#638) escape DOM-sourced email parts in site mailto builder — 3116eed
- (#584) extract_push_ref no longer over-matches arrow in commit messages — 20c7554
- (#631) printf not echo when re-emitting captured JSON (pre-push-gate + tracker) — 1785e90
- (#629) config_get dropped ALL overrides when config had a backslash escape — cd4bfbe
- (#614) game score over max — level1 + levelTemp double-counted — 2224a53
- (#609) embedding level — replace drag-into-plane with tap-to-group (mobile) — 583e8a6
- (#602) game mobile-responsive pass + #apexyard share + loop-engineering level — b3e9f4a
- (#569) exempt .claude/, /tmp, rm, and $VAR targets from bash-write ticket gate — be50036
- (#568) PR extractor ignores redirection tokens + unexpanded var args — 7da5984
- (#549) block-main-push checks the operation's target branch, not session cwd — eaa0fa9
- (#548) pre-push markdownlint lints tracked files only — 98a0aba
- (#547) parse git-push dst ref, ignore redirections + tag pushes — 2b41158
- (#550) tag the squash commit on main + ancestry guard in /release — 63b72bf
- (#559) resolve review-marker home pin-first in Rex + /approve-merge — 50b54a5
- (#562) guard hero pill + releases metric against version drift — a7f5f34
- (#494) block build-agent self-review — require a real GitHub review behind the rex marker — 471a74a
- (#493) release site-version bump + correct issue-filing version on dev + tracker shape-only fallback — b149c4e
- (#485) repo-qualify review markers to prevent same-PR-number collision across repos — 417e326
- (#475) make code-reading sub-agents MCP-first — 42c8fb5
- (#469) suggest-mcp-search surfaces to the agent + install-gates — d8862f1
- (#464) PR-create hooks resolve PR origin repo, not session ops-fork — 5638132
- (#459) require --merge for sync PRs; guard --squash in hook — 2961d4d
- (#461) replace truncating sed extractor in require-agdr-for-arch-pr.sh with greedy awk — dfe35ba
- (#443) inline helper-source in /dfd write blocks + strengthen Write targets rule — d12c460
- (#442) warn at SessionStart when Ollama routing is INACTIVE; promote shell-profile step in docs — 3848cb1
- (#373) catch split-portfolio v2 silent fallbacks for workspace_dir and projects/ — d638dbf
- (#434) route SETUP step 1 onboarding.yaml through portfolio helper — 84eae45
- (#433) promote /handover MCP reindex to named step + add advisory hook — 03ed05a
- (#415) configure branch protection on private portfolio repo after split-portfolio — 1d107d8
- (#414) update wrapper test to v2 shape + guard against v1 regression — c98a262
- (#426) merge hook handles compound marker-write + merge commands — be1479c
- (#424) hook walker reads session pin before walk-up — a2e7c36
- (#419) guard bootstrap exemption scope — /handover only — d24c762
- (#418) reorder case patterns to satisfy shellcheck SC2221 — 3b217f9
- (#404) remove stale --pdf-output-folder flag from md-to-pdf dispatch — 47a438f
- (#393) mobile UX regressions — nav main pages + eyebrow + content polish — 0ba64e1
- (#381) pin ops-root via CLAUDE_CODE_SESSION_ID SessionStart hook — fbc1cff
- (#382) refine gh api matcher to only block POST on /issues — 1f86db3
- (#375) replace `|| echo "0"` with `|| true` in code-quality.yml — 3942789
- (#370) hook wrappers silent no-op outside an apexyard fork — fa327e0
- (#317) /split-portfolio produces v2 layout + copy-onboarding semantics — a075c9a
- (#310) resolve config from ops-fork root, not workspace clone — 4b81bde
- (#275) additive ui_paths_exclude carve-out for require-design-review-for-ui — 14b651b
- (#227) greedy body extractor — no more truncation at embedded quotes — 227b3b4
- (#229) align merge gates + agent + skill on ops-fork marker path — c419666
- (#207) make verify-commit-refs and validate-pr-create consult upstream remote — 02eeb1a
- (#194) validation hooks read git context from command, not $PWD — ffb44b0
- (#106) CHANGELOG fallback in drift hook for squash-merged forks — dd85a13

### Changed (refactor / chore / docs)

- (#679) set scorecard publish_results false to stop the action failing — 2f572ec
- (#536) add Code of Conduct + fix stale counts — 9307f75
- (#676) document orchestrator cost model + cost levers — fbc0668
- (#663) remove extracted marketing site (now lives in apexyard-site) — 19f406d
- (#635) harden workflows — SHA-pin all Actions + least-privilege permissions — dc588e1
- (#598) bump actions/checkout from 4 to 6 — 3c141b5
- (#619) game — repoint outro footer off LangGraph, fix stale intro, add game OG image — cb701c7
- (#600) pin ossf/scorecard-action to v2.4.3 — 771e2ea
- (#590) bump upload-artifact v4->v7 + codeql-action v3->v4 — 38dcf45
- (#543) bump DavidAnson/markdownlint-cli2-action from 16 to 23 — 4c8352a
- (#542) bump actions/github-script from 7 to 9 — 4c2a3cb
- (#540) bump gitleaks/gitleaks-action from 2 to 3 — 4b69896
- (#588) exempt dependabot/sync branches from ticket-ID check; target dev — 207a761
- (#560) re-fork & data-preservation guide in upgrading.md — 28b34fe
- (#545) exempt sync/ branches from the PR-create ticket-ID rule — f2ed536
- (#536) open-source community-health files + README refresh — 6ac3373
- (#528) drain quarantine — pin-escape audit fix + handover rewrite — afbb26c
- (#528) fix + un-quarantine agent_routing_sync_and_drift — 41d1051
- (#528) fix + un-quarantine 3 of 5 hook-test failures — 9bd0e17
- (#526) gate the hook test suite in CI — 1027dbc
- (#517) onboarding guard — literal filename match (grep -Fxq) — 1822767
- (#511) relax release-gated semgrep to fail-on-ERROR — 2422927
- reset onboarding.yaml to template placeholders — 9730435
- (#506) wire pre-push-gate to the framework CI checks + add git pre-push hook — 94a6a0f
- (#492) bump marketing-site framework version to 2.2.0 — e93562c
- (#487) release-gated security scan on the framework repo (dog-food the Shield pipeline) — 4509ebf
- (#458) whitelist `sync` type across branch/commit/PR validators — 02dc105
- (#456) main→dev sync after v2.2.0 release — 2314e2f
- add split-portfolio v2 marker + sync onboarding.yaml from portfolio — de9069c
- (#447) sync CHANGELOG.md from main to dev — e8208bd
- (#341) ship 6 site/ binary assets — OG previews + favicons — 0526aac
- (#372) drop @docs/multi-project.md auto-import from CLAUDE.md — 0f6ca08
- (#320) multi-project workspace + conflict-skip + README preservation (Case 5) — 9ddbe2b
- (#354) /debug 'when to invoke' sidebar in workflows/sdlc.md Phase 3 — 008aaf0
- (#358) wave-2 cleanup bundle — drop allowed_tools_override + push-gate scope + multi-line drift — 47b557a
- (#347) AgDR-0050 — agent runtime overhaul (cross-cutting design for #347 + #348 + #351) — 17942fc
- (#318) /setup + /update step 8a test infrastructure — e135a0b
- (#350) align v1→v2 manual recipe in docs/multi-project.md with AgDR-0021 § H copy-onboarding semantics — 5d54641
- (#265) AgDR-0047 for framework packaging & distribution — e6a6d71
- (#325) site/ count refresh + meta-tag polish + content-shape + markdown alternates — 7668e91
- (#334) rename /generative-engine-audit to /geo-audit — 7567739
- (#329) site/ AI-readiness + classic SEO infrastructure — cb00fa9
- (#322) token-efficiency Wave 1 — ~2.9k tokens saved at session start — 2ccefa4
- (#302) sweep all 40 hook wrappers to v2-anchor-aware shape — ad42d0d
- (#303) generic cleanup — e4aa82a
- (#241) /learn feasibility — dry-run report — e1953b4
- (#221) retrofit 7 audit skills onto _lib-audit-history.sh — c8b292e
- (#223) add Data Flow Diagram section to threat-model template — fc54ace
- (#219) plan-mode usage rule — when to enter — 5eccc0f
- (#215) /setup emits verified LSP plugin-install commands — 526e9b7
- (#204) give every role + agent an Arabic persona name — 88f9dae
- (#197) Claude tier-routing spike — measurement + recommendation — e435719
- (#195) local-model routing spike — measurement + recommendation — 20d9974
- (#189) document ENABLE_LSP_TOOL opt-in + per-language LSP plugin install — 8e753f6
- (#190) annotate LSP-aware skills with opt-in callouts — fa72b0a
- (#178) LSP integration spike — measurement + recommendation — 9615dea
- (#173) sync CHANGELOG.md from main → dev — 85fe794
- (#170) exempt release/vN.N.N from validate-pr-create's branch-id check — 9873c25
- (#168) accept release/vN.N.N branches + release(...) PR titles — f28096a
- (#163) default the split-portfolio sibling repo name to <fork>-portfolio — 9517b19
- (#157) remove voice-prompts feature + correct hook/skill counts — 327a297
- (#154) mock gh in test sandboxes to remove live-tracker dependency — d4ed533
- (#153) extend Bash-write matcher beyond first-version coverage — 690ada8
- (#148) correct privacy-gate wording — adopter action, not framework auto-publish — 20b071e
- (#143) document split-portfolio mode + add /setup privacy gate — 344da88
- (#116) adopt release-cut branch model (dev/main + tags) — framework only — 3c53ff8
- (#114) enforce single Closes-keyword per PR body — 5a03d9e
- (#113) require Testing section in PR body (config-driven) — e4c09a3
- (#112) add require-agdr-for-arch-pr.sh PreToolUse hook — f23f784
- (#107) add validate-issue-structure.sh PreToolUse hook — 6920060
- (#111) upgrade pre-push-gate from advisory reminder to blocking check-runner — e98633c
- (#115) add warn-stale-review-markers.sh PostToolUse hook — 6e86b95
- (#110) add block-private-refs-in-public-repos.sh hook — a4edb89
- (#109) project-configurable ticket / branch / commit / PR schema — 1586d44

### Breaking

- (#347) Hatim→Hakim consolidation + security + data sub-agents (Wave 2 PR 3) — bcbb121

### Closes
<!-- multi-close: approved -->
- Closes #106, #107, #108, #109, #110, #111, #112, #113, #114, #115, #116, #117, #130, #132, #135, #141, #143, #145, #148, #150, #153, #154, #157, #160, #163, #165, #168, #170, #173, #177, #178, #179, #180, #181, #182, #183, #188, #189, #190, #194, #195, #197, #204, #205, #206, #207, #208, #215, #218, #219, #221, #223, #224, #227, #229, #232, #241, #242, #243, #244, #245, #246, #249, #250, #255, #256, #257, #265, #266, #268, #270, #271, #275, #280, #281, #282, #283, #284, #288, #290, #293, #295, #296, #297, #298, #299, #302, #303, #310, #311, #312, #317, #318, #320, #321, #322, #325, #327, #329, #333, #334, #341, #347, #350, #351, #354, #358, #370, #372, #373, #375, #376, #377, #381, #382, #386, #393, #403, #404, #414, #415, #417, #418, #419, #424, #426, #428, #433, #434, #438, #442, #443, #447, #450, #451, #456, #458, #459, #461, #464, #469, #471, #473, #475, #478, #480, #482, #485, #487, #489, #492, #493, #494, #506, #510, #511, #513, #517, #518, #520, #526, #528, #536, #540, #542, #543, #545, #547, #548, #549, #550, #559, #560, #562, #568, #569, #584, #585, #588, #590, #594, #598, #600, #602, #606, #609, #614, #619, #626, #627, #629, #631, #635, #638, #641, #643, #651, #653, #663, #672, #674, #675, #676, #677, #679

## [3.2.0] — 2026-06-17

Minor release — agent-routing cost levers, MCP-search enforcement, GitHub-Issues onboarding, and merge-gate hardening.

### Added

- (#652) Opt-in gate mode for `suggest-mcp-search.sh` — when `mcp_search.gate_mode` is enabled and `apexyard-search` is configured, the hook soft-blocks (exit 2) exploratory `grep -r`/`find` over indexed paths and instructs MCP-first, with an `APEXYARD_MCP_FALLBACK=1` per-call escape hatch. Default-off, install-gated, Read/Glob/Grep never blocked (AgDR-0070)
- (#654) Detect (and offer to enable) GitHub Issues during `/setup` + `/handover` when `tracker.kind=github` — new `tracker_check_issues` helper in `_lib-tracker.sh` warns + offers `gh repo edit --enable-issues` (never auto-enables; gated on tracker kind; fails open) so a fresh fork doesn't hit a cryptic `repository has disabled issues` error (AgDR-0071)
- (#641) Consent-gated GA + cookie banner on all marketing-site pages
- (#633) Grant Rex `search_code` and prefer semantic MCP search over grep when available
- (#628) Support `fallow` static-analysis pass in code review (JS/TS dead-code, unused exports, duplication)

### Fixed

- (#656) `block-merge-on-red-ci` now refuses variable-substituted merges (`gh pr merge $PR --repo $REPO`, incl. quoted forms) with a clear message instead of silently checking an unrelated CWD PR — new shared `merge_command_uses_variable` guard
- (#639) Escape DOM-sourced email parts in the site mailto builder
- (#634) `extract_push_ref` no longer over-matches the arrow (`→`) in commit messages
- (#632) Use `printf` not `echo` when re-emitting captured JSON (pre-push-gate + tracker lib)
- (#630) `config_get` no longer drops ALL overrides when the config contains a backslash escape

### Changed

- (#636) Harden CI workflows — SHA-pin all Actions + least-privilege `permissions`
- (#598) Bump `actions/checkout` 4 → 6

### Closes

- Closes #651, #653, #643, #626, #627, #638, #635, #584, #631, #629

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
