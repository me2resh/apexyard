# ApexStack Rule Audit

Every **MUST / NEVER / HARD-STOP** rule from `CLAUDE.md`, `.claude/rules/*.md`, and `workflows/*.md`, mapped to its enforcement mechanism (hook, agent, prose) and labelled with whether it is mechanized, advisory, or deferred to a follow-up ticket.

## How to use this doc

This audit is the **single view** of the governance surface ApexStack ships with. For each rule it answers three questions: *where is it written down*, *who enforces it*, and *is it a hard block or a piece of self-discipline*. When you fork apexstack and start tuning the rules to your team, start here — the rows flagged `advisory` are the ones you most likely want to promote to CI checks or linter rules in your own stack, because the shell-harness can't reach them.

**When to update**: any time a rule is added, removed, tightened, or loosened in a rule file, workflow, or `CLAUDE.md`; any time a hook is added or its matcher changes; any time a deferred ticket (listed below) is closed and the rule moves from `deferred` to `mechanized`. The rule files themselves are the source of truth for the prose — this doc is the *index* and should not try to restate them.

**Append changelog vs write a new AgDR** (rule of thumb from the `AgDR-0001` thinking — AgDRs are historical artefacts of a decision moment, not living documents): if a post-ship change is a small tweak to a threshold or a clarification of a choice that was already made (e.g. "we added `.serverless/` to `architecture_paths`", "the green-CI check now allows `no checks reported`"), append a dated changelog entry to the AgDR and mention it in this audit. If the change involves *re-opening the options table* — a new option you didn't consider, a reversal of the chosen path, a different tradeoff — write a **new** AgDR that links back to the old one. The test is: "would a reader who only saw the new state understand *why* without re-reading the old options?" If yes, changelog entry. If no, new AgDR.

---

## Audit table

Columns:

| col | meaning |
|-----|---------|
| **rule** | short name, one-liner |
| **source** | file and section — clickable links where useful |
| **enforced by** | hook filename, agent, CI check, or `prose` |
| **mechanizable?** | `yes` / `no` / `deferred` (with follow-up ticket) |
| **proposed hook / reason advisory** | for mechanizable-not-yet rows, the candidate hook name; for `no` rows, why it stays prose |

### 1. Git mechanics

| rule | source | enforced by | mechanizable? | proposed hook / reason advisory |
|------|--------|-------------|---------------|---------------------------------|
| Never `git add -A` / `.` / `--all` | `.claude/rules/git-conventions.md § File Staging` | `block-git-add-all.sh` | yes | mechanized |
| No direct commits / pushes to `main` / `master` | `.claude/rules/git-conventions.md § No Direct Main` | `block-main-push.sh` | yes | mechanized |
| Branch name format `{type}/{TICKET-ID}-{slug}` | `.claude/rules/git-conventions.md § Branch Naming` | `validate-branch-name.sh` | yes | mechanized (warning-only today, blocker upgrade in [#20][20]) |
| PR title format `type(TICKET): description` | `.claude/rules/git-conventions.md § PR Title Format` | `validate-pr-create.sh` | yes | mechanized (warning-only today, blocker upgrade in [#20][20]) |
| One ticket ID per PR title (no `fix(#1,2,3):`) | `.claude/rules/git-conventions.md § PR Title Format` | `validate-pr-create.sh` | yes | mechanized |
| Commit subject matches conventional format (`type: …` / `type(scope): …`) | `.claude/rules/git-conventions.md § Commit Message Format` | `validate-commit-format.sh` | yes | mechanized (AgDR-0001) |
| Breaking-change marker (`feat!:` / `feat(scope)!:`) | — | — | deferred | [#23][23] — not yet in the accepted commit regex |
| `commit_types` project-config override | — | — | deferred | [#22][22] — hook uses a hardcoded type list |
| No hardcoded secrets in code | `.claude/rules/git-conventions.md § No Hardcoded Secrets` | `check-secrets.sh` | yes | mechanized |
| `Closes #N` / `Fixes #N` / `Refs #N` must resolve to a real issue | `.claude/rules/ticket-vocabulary.md § Backstop enforcement` | `verify-commit-refs.sh` | yes | mechanized |
| PR title's `#N` must resolve to a real issue in the tracker repo | `.claude/rules/ticket-vocabulary.md § Backstop enforcement` | `validate-pr-create.sh` | yes | mechanized |

### 2. Ticket-first & workflow gates

| rule | source | enforced by | mechanizable? | proposed hook / reason advisory |
|------|--------|-------------|---------------|---------------------------------|
| Ticket MUST exist before code edits begin | `.claude/rules/workflow-gates.md § Pre-Build Gate`, `workflows/sdlc.md § Phase 3 Pre-Build Gate` | `require-active-ticket.sh` | yes | mechanized (exempts `.claude/`, `docs/`, `*.md`) |
| Gate 1 — PRD approved + parent epic exists before tech design | `.claude/rules/workflow-gates.md` | prose | no | requires product-doc review; not a shell-observable signal [^advisory] |
| Gate 2 — design approved + story tickets exist + AgDR for key decisions before build | `.claude/rules/workflow-gates.md` | prose + `require-agdr-for-arch-changes.sh` (arch half) | partial | AgDR half mechanized on arch commits; "design approved" stays prose |
| Gate 3 — ticket exists + branch created + design review if UI before starting code | `.claude/rules/workflow-gates.md` | `require-active-ticket.sh` (ticket half) + prose | partial | design-review gate fires at *merge* time via `require-design-review-for-ui.sh`, not at build start |
| Gate 4 — tests pass + checks pass + >80% coverage + AgDR linked before PR | `.claude/rules/workflow-gates.md`, `.claude/rules/pr-workflow.md` | `pre-push-gate.sh` (reminder) + prose | partial | lint/typecheck/test/build reminder mechanized; >80% coverage stays advisory — per-project CI concern [^coverage] |
| Gate 5 — two reviews + CI green + commit SHA matches review before merge | `.claude/rules/workflow-gates.md`, `.claude/rules/pr-quality.md` | `block-unreviewed-merge.sh` + `block-merge-on-red-ci.sh` | yes | mechanized (two hooks together) |
| Gate 6 — QA verified before ticket → Done | `.claude/rules/workflow-gates.md`, `workflows/sdlc.md § Phase 5` | prose | no | QA sign-off is a human handoff; not a shell-observable signal [^advisory] |
| One ticket at a time (one PR = one ticket) | `.claude/rules/workflow-gates.md`, `workflows/sdlc.md` | prose | no | behavioral rule; detection would need per-session PR tracking that isn't worth the complexity [^advisory] |
| Pre-Build Gate checklist (parent epic, story tickets with AC, tasks broken down) | `workflows/sdlc.md § Pre-Build Gate` | prose | no | per-ticket content check requires reading issue bodies and scoring — out of scope for shell hooks [^advisory] |
| QA state mandatory — merged PR moves to QA label, not auto-closed | `.claude/rules/workflow-gates.md § QA State`, `workflows/sdlc.md § Phase 5` | prose | no | needs integration with GitHub projects / labels; deferred to project-level automation |
| If a gate fails → STOP, complete the missing step first | `CLAUDE.md § Workflow Gates`, `.claude/rules/workflow-gates.md` | prose | no | umbrella "STOP" rule, composed of the individual gate rows above |

### 3. Code review & PR quality

| rule | source | enforced by | mechanizable? | proposed hook / reason advisory |
|------|--------|-------------|---------------|---------------------------------|
| Code review required before merge | `CLAUDE.md § Quality Rules`, `workflows/code-review.md` | `block-unreviewed-merge.sh` (Rex marker half) | yes | mechanized |
| Explicit per-PR human approval before every merge | `.claude/rules/pr-workflow.md § Plan-level "go"` | `block-unreviewed-merge.sh` (CEO marker half) + `/approve-merge` skill | yes | mechanized (AgDR-0001 precursor) |
| Plan-level "go" / "ship it" does NOT authorize a merge | `.claude/rules/pr-workflow.md § Plan-level "go" is NOT merge approval` | `block-unreviewed-merge.sh` (CEO marker must be written via `/approve-merge`) | yes | mechanized via the marker-writing convention |
| After `gh pr create` → invoke Code Reviewer | `.claude/rules/pr-workflow.md § After gh pr create` | `auto-code-review.sh` (PostToolUse reminder) | yes | mechanized as reminder-style nudge |
| After pushing new commits to an open PR → re-invoke Code Reviewer | `.claude/rules/pr-workflow.md § After Pushing Commits` | `block-unreviewed-merge.sh` (SHA mismatch check) | yes | mechanized |
| Commit SHA matches Rex + CEO approvals at merge time | `.claude/rules/pr-quality.md § Commit SHA Verification` | `block-unreviewed-merge.sh` | yes | mechanized |
| PR description MUST contain a Glossary section | `.claude/rules/pr-quality.md § Glossary`, `workflows/code-review.md § PR Description Format` | `validate-pr-create.sh` (warning) + `code-reviewer` agent (blocker) | yes | mechanized (warning + agent) |
| Design review required when PR touches UI | `.claude/rules/pr-quality.md § Design Review`, `workflows/code-review.md` | `require-design-review-for-ui.sh` | yes | mechanized (AgDR-0001) |
| `/approve-design` skill for writing the design marker | — | — | deferred | [#21][21] — today's convention is a manual `git rev-parse HEAD > marker` |
| Never merge with red CI — even pre-existing failures must be fixed first | `.claude/rules/pr-quality.md § No Red CI`, `CLAUDE.md` | `block-merge-on-red-ci.sh` | yes | mechanized (AgDR-0001) |
| No merge on pending / in-progress CI (pending is not green) | `.claude/rules/pr-quality.md § No Red CI` | `block-merge-on-red-ci.sh` | yes | mechanized |
| Before `git push`: lint, typecheck, test, build must pass locally | `.claude/rules/pr-workflow.md § Before git push`, `CLAUDE.md § Quality Rules` | `pre-push-gate.sh` (reminder) | partial | reminder mechanized; actual pass/fail stays per-project CI [^project-cmds] |
| Ticket must exist before `gh pr create` | `.claude/rules/pr-workflow.md § Before gh pr create` | `validate-pr-create.sh` (branch-ID + issue-exists checks) | yes | mechanized |
| Ticket must have acceptance criteria before `gh pr create` | `.claude/rules/pr-workflow.md § Before gh pr create` | prose | no | AC-content detection needs issue-body parsing and scoring — not a shell-hook job [^advisory] |
| Branch name has ticket ID before `gh pr create` | `.claude/rules/pr-workflow.md § Before gh pr create` | `validate-branch-name.sh` + `validate-pr-create.sh` | yes | mechanized |
| Approval requirements by change type (infra +1 platform, security +1 auditor, arch → Head of Eng) | `workflows/code-review.md § Approval Requirements` | prose | no | change-type detection is ambiguous (what counts as "infra"?); role activation handles the soft version |

### 4. Technical decisions (AgDR)

| rule | source | enforced by | mechanizable? | proposed hook / reason advisory |
|------|--------|-------------|---------------|---------------------------------|
| HARD STOP — run `/decide` before any technical decision | `.claude/rules/agdr-decisions.md § Trigger Patterns` | prose (self-discipline) | no | trigger patterns are chat-output phrases; linting assistant prose was rejected for the same reason as in `ticket-vocabulary.md` [^self-discipline] |
| AgDR required for architecture / infra commits | `.claude/rules/agdr-decisions.md § Enforcement` | `require-agdr-for-arch-changes.sh` | yes | mechanized (AgDR-0001); narrow default path list, project-config override via `.architecture_paths` |
| Extend default `architecture_paths` to cover SAM / Helm / K8s / Serverless Framework | — | — | deferred | [#25][25] — default list is deliberately narrow; follow-up broadens safely |
| AgDRs stored at `{project}/docs/agdr/AgDR-NNNN-{slug}.md` | `.claude/rules/agdr-decisions.md § What /decide Does` | prose | no | path convention, not a gatekeeping rule |
| Code Reviewer flags PRs with arch changes that don't link an AgDR | `.claude/rules/agdr-decisions.md § Enforcement` | `code-reviewer` agent + `require-agdr-for-arch-changes.sh` | yes | mechanized |

### 5. Ticket vocabulary

| rule | source | enforced by | mechanizable? | proposed hook / reason advisory |
|------|--------|-------------|---------------|---------------------------------|
| `Ticket`, `#N`, `blocked by #N` refer ONLY to real GitHub issues | `.claude/rules/ticket-vocabulary.md § The rule`, `CLAUDE.md § Quality Rules` | prose + downstream backstops | partial | prose is primary; `validate-pr-create.sh` and `verify-commit-refs.sh` catch the symptoms in durable artefacts [^self-discipline] |
| Never apply tracker notation to in-conversation plan items | `.claude/rules/ticket-vocabulary.md § The rule` | prose | no | chat-output rule, same class as the `/decide` triggers [^self-discipline] |
| Crossing "plan item → tracker item" requires an explicit `gh issue create` | `.claude/rules/ticket-vocabulary.md § The boundary-crossing rule` | prose | no | workflow rule, not a mechanical check |

### 6. Code standards

| rule | source | enforced by | mechanizable? | proposed hook / reason advisory |
|------|--------|-------------|---------------|---------------------------------|
| TypeScript `strict` mode enabled in all projects | `.claude/rules/code-standards.md § TypeScript` | prose | no | lint / `tsconfig` concern, per-project [^lint] |
| No bare `any` without justification comment | `.claude/rules/code-standards.md § TypeScript` | prose | no | lint / AST concern, per-project [^lint] |
| No swallowed errors (empty `catch` blocks) | `.claude/rules/code-standards.md § TypeScript` | prose | no | lint / AST concern, per-project [^lint] |
| Always handle errors or re-throw with context | `.claude/rules/code-standards.md § TypeScript` | prose | no | lint / AST concern, per-project [^lint] |
| Domain layer has NO external dependencies (no frameworks, HTTP, DB) | `.claude/rules/code-standards.md § DDD`, `CLAUDE.md` | prose | no | import-graph analysis, per-project [^lint] |
| Application layer does NOT import infrastructure | `.claude/rules/code-standards.md § DDD` | prose | no | import-graph analysis, per-project [^lint] |
| Commands vs queries separation | `.claude/rules/code-standards.md § DDD` | prose | no | architectural pattern, not a shell-observable signal [^advisory] |
| Repository pattern for data access | `.claude/rules/code-standards.md § DDD` | prose | no | architectural pattern [^advisory] |
| Naming conventions (PascalCase components, camelCase hooks, kebab-case dirs, etc.) | `.claude/rules/code-standards.md § Naming Conventions` | prose | no | lint rule, per-project [^lint] |
| Tests test behavior not implementation, Arrange-Act-Assert | `.claude/rules/code-standards.md § Testing` | prose | no | style rule, not mechanizable [^advisory] |
| Coverage > 80% for domain logic | `.claude/rules/code-standards.md § Testing`, `.claude/rules/pr-quality.md § QA Gate`, `CLAUDE.md § Quality Rules` | prose | no | per-project coverage tooling; framework-level hook is too brittle (AgDR-0001) [^coverage] |
| Testing pyramid ~70% unit / 20% integration / 10% E2E | `.claude/rules/code-standards.md § Testing` | prose | no | advisory metric, not a threshold — see AgDR-0001 [^advisory] |
| Frontend state split (local primitive / server query-lib / global only when justified) | `.claude/rules/code-standards.md § Frontend` | prose | no | architectural preference, not a shell-observable signal [^advisory] |
| Forms must be schema-validated (e.g. Zod) | `.claude/rules/code-standards.md § Frontend` | prose | no | lint / AST concern [^lint] |
| Always export the interface for component props | `.claude/rules/code-standards.md § Frontend` | prose | no | lint / AST concern [^lint] |

### 7. Role activation & handoffs

| rule | source | enforced by | mechanizable? | proposed hook / reason advisory |
|------|--------|-------------|---------------|---------------------------------|
| Role files MUST be read and adopted before acting in a role | `.claude/rules/role-triggers.md § Activation Protocol`, `CLAUDE.md § Roles` | prose | no | behavioral, depends on the agent reading the file before responding [^self-discipline] |
| Respect CAN / CANNOT role boundaries, hand off when you hit a CANNOT | `.claude/rules/role-triggers.md § Role Boundaries` | prose | no | behavioral [^self-discipline] |
| Role handoff artefacts (PRD, tech design, PR, test plan) are contracts | `.claude/rules/role-triggers.md § Handoff Artefacts` | prose | no | workflow, not a mechanical check [^advisory] |
| Auto-activate Security Auditor on `**/auth/**` / `**/crypto/**` / `**/secrets/**` diffs | `.claude/rules/role-triggers.md § Auto-activation`, `workflows/code-review.md` | prose | no | possible future hook: PostToolUse on `gh pr create`, diff-grep for sensitive paths, emit reminder [^future-hook] |
| Auto-activate QA Engineer when ticket enters `qa` label | `.claude/rules/role-triggers.md`, `workflows/sdlc.md § Phase 5` | prose | no | needs GitHub label webhook integration, out of scope for local hooks |

### 8. Deployment

| rule | source | enforced by | mechanizable? | proposed hook / reason advisory |
|------|--------|-------------|---------------|---------------------------------|
| Infrastructure MUST be defined in code (no manual console changes) | `workflows/deployment.md § Infrastructure as Code` | prose | no | out-of-band rule, not a shell-observable signal [^advisory] |
| IaC version controlled + reviewed through PR process + tested in staging | `workflows/deployment.md § Infrastructure as Code` | `require-agdr-for-arch-changes.sh` (AgDR half) + prose | partial | AgDR enforced for arch-path commits; "tested in staging" stays advisory |
| Pre-deploy checklist (tests, QA sign-off, rollback plan, monitoring, team aware, DB migrations tested) | `workflows/deployment.md § Pre-Deploy Checklist` | prose | no | checklist — not a single hookable condition [^advisory] |
| Production deploy approval (staging tested, QA sign-off, no P1/P2 bugs, team available) | `workflows/deployment.md § Production Deploy Approval` | prose | no | human decision gate [^advisory] |
| "Not Friday afternoon (unless critical)" | `workflows/deployment.md § Production Deploy Approval` | prose | no | advisory — not mechanizable in a shell harness [^advisory] |

### 9. Onboarding / session bootstrapping

| rule | source | enforced by | mechanizable? | proposed hook / reason advisory |
|------|--------|-------------|---------------|---------------------------------|
| New session without `.claude/session/onboarded` → run `/onboard` | — | `onboarding-check.sh` (SessionStart) | yes | mechanized |
| `.claude/` duplication between ops-repo and apexstack upstream | — | — | deferred | [#15][15] |

---

## Summary

| bucket | count |
|--------|-------|
| mechanized (`yes` — hook / agent enforces it fully) | 26 |
| partially mechanized (`partial` — hook + prose combination) | 6 |
| advisory (`no` — stays prose by design) | 36 |
| deferred to a follow-up ticket (`deferred`) | 5 |
| **total rows** | **73** |
| deferred tickets referenced | 6 ([#15][15], [#20][20], [#21][21], [#22][22], [#23][23], [#25][25]) |

The count of deferred *rows* (5) and deferred *tickets* (6) differ because [#15][15] is a meta-chore (resolve `.claude/` duplication between ops-repo and apexstack upstream) that gets one row in the onboarding section, while the commit-related tickets [#20][20] and [#22][22] share a row via `validate-branch-name.sh` + `validate-pr-create.sh`.

The spread confirms what AgDR-0001 set out to make true: the **high-blast-radius rules** (git add, main push, secrets, merge gate, ticket-first, commit format, arch-change AgDR, red-CI, UI design review) are hooks. The **per-project concerns** (coverage, type strictness, import-graph purity, testing pyramid) stay advisory because a framework-level shell harness can't reach them without false-positive spam. The **self-discipline rules** (`/decide` trigger phrases, `Ticket N` vocabulary in chat, role adoption) stay advisory by design — the rule files are primary and the hooks catch only the durable-artefact symptoms.

---

## Footnotes

[^advisory]: Advisory — not mechanizable in a shell harness. Either the rule is a human decision gate (QA sign-off, "not Friday afternoon"), or it depends on reading structured content (PRD body, issue AC text) that a shell hook cannot meaningfully score.

[^coverage]: Framework-level coverage-threshold enforcement was explicitly rejected in AgDR-0001: coverage reports live in each project's CI with project-specific tooling and output formats, so a generic hook would need to know every project's toolchain. Each project enforces `>80%` in its own CI.

[^lint]: Static-analysis concern. Belongs in each project's ESLint / `tsconfig` / equivalent — not a shell hook. The rule stays in `code-standards.md` as the canonical prose; individual projects translate it into their linter config.

[^project-cmds]: `pre-push-gate.sh` is a reminder that echoes the commands, not a runner. Actually executing lint / typecheck / test / build requires knowing the project's package manager and script names — left to per-project CI.

[^self-discipline]: Chat-output rule. Hooks run on tool calls, not assistant prose. The rule file is the primary defence and the downstream artefacts (commit messages, PR titles, staged diffs) are the backstop. See `ticket-vocabulary.md § Why not lint Claude's prose output?` for the full rejection of the "lint chat output" alternative.

[^future-hook]: Candidate for a future PostToolUse reminder hook on `Bash(gh pr create *)` — if the diff touches sensitive paths, emit a reminder telling Claude to invoke the Security Reviewer. Not written yet; track as a follow-up if the trigger fires often enough to justify a hook.

[15]: https://github.com/me2resh/apexstack/issues/15
[20]: https://github.com/me2resh/apexstack/issues/20
[21]: https://github.com/me2resh/apexstack/issues/21
[22]: https://github.com/me2resh/apexstack/issues/22
[23]: https://github.com/me2resh/apexstack/issues/23
[25]: https://github.com/me2resh/apexstack/issues/25
