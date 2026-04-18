---
id: AgDR-0001
timestamp: 2026-04-11T18:50:00Z
agent: atlas
model: claude-opus-4-6
trigger: user-prompt
status: executed
ticket: me2resh/apexyard#13
---

# Rule mechanization — which four hooks to ship and what thresholds they enforce

> In the context of auditing the apexyard CLAUDE.md and rule files after three sibling incidents exposed "prose rules the model drops under pressure", facing the choice of which MUST rules to mechanize and which to leave explicitly advisory, I decided to ship four new hooks (`require-agdr-for-arch-changes`, `require-design-review-for-ui`, `block-merge-on-red-ci`, `validate-commit-format`) with narrow default path lists and project-config overrides, accepting that some MUSTs (>80% coverage, "no bare any", "one ticket at a time") stay prose because they are either too project-specific or genuinely not mechanizable in a shell harness.

## Context

Three sibling incidents in the same session (2026-04-11) all traced back to the same root cause: rules written as prose in `CLAUDE.md` / `.claude/rules/*.md` / `workflows/*.md` are advice the model drops under pressure.

- **Incident 1** — plan-level "go" was inferred as merge approval. Fixed in [#11](https://github.com/me2resh/apexyard/issues/11) / commit `646302e`: explicit per-merge CEO approval rule, two-marker merge gate, `/approve-merge` skill.
- **Incident 2** — agent presented a fabricated 10-ticket tree in chat using tracker vocabulary. Fixed in [#14](https://github.com/me2resh/apexyard/issues/14) / commit `d0a2128`: ticket-vocabulary rule + verify-issue-exists backstops.
- **Incident 3** — general audit. Multiple MUSTs in the rules remained unenforced by hooks. This ticket (#13).

The audit found that the apexyard rules/workflows files contain ~15 MUST-type statements. About 10 are already mechanized (from the enforcement work merged earlier this session plus the pre-existing six hooks). Of the remainder, some are mechanizable and some are not.

## Options Considered

### Option A — ship all mechanizable rules as hooks, immediately, with broad defaults

Everything that *could* be a hook becomes one. Design rules touch any UI file extension, architecture rules touch any infrastructure-adjacent path, commit-format enforces strict types, PR-body glossary becomes a blocker, etc.

**Pros:** maximum mechanical enforcement, minimum prose leakage, clearest message that "if it's a rule, it's a hook."

**Cons:** broad defaults fire false positives constantly (server `.ts` treated as UI, `package.json` bump treated as architecture, etc.). Users burn out on false alarms and disable hooks. Worse-than-status-quo outcome.

### Option B — ship only the rules with clean mechanization and narrow defaults, leave the rest explicitly advisory

Four hooks with narrow, project-configurable path lists:

- `require-agdr-for-arch-changes.sh` — fires on `git commit` when the staged diff touches `infrastructure/`, `*.tf`, `docker-compose*.yml`, `Dockerfile*`, or `.github/workflows/`. Requires an AgDR reference in the commit message or a new AgDR file staged alongside. Narrow enough that false positives are rare.
- `require-design-review-for-ui.sh` — fires on `gh pr merge` when the PR diff touches `.tsx`, `.jsx`, `.vue`, `.svelte`, `.css`, `.scss`, `.sass`, `.less`, or `design-tokens*`. Requires a design approval marker. **Deliberately excludes `.ts` and `.js`** — those are server-side TypeScript/JavaScript much more often than UI, and catching them would create false positives on every backend PR.
- `block-merge-on-red-ci.sh` — fires on `gh pr merge`, runs `gh pr checks` on the target PR, blocks on any failing/pending check. Allows the "no checks configured" case (some projects don't have CI) with a NOTE.
- `validate-commit-format.sh` — fires on `git commit`, checks that the subject matches `type: subject` or `type(scope): subject` with type from `{feat, fix, refactor, test, docs, chore, style, perf, build, ci, revert}`. Matches the PR-title type list in `git-conventions.md`.

Each hook has default path lists that can be overridden via `.claude/project-config.json` (`architecture_paths`, `ui_paths` — `commit_types` is a future extension if a project wants a stricter or looser type list).

**Pros:** low false-positive rate by construction. Projects can tighten the defaults if they want broader coverage. The rules that *can't* be mechanized cleanly are explicit about that — they stay prose and the audit doc (follow-up) will label them.

**Cons:** some MUSTs remain advisory (>80% coverage, typing rules, one-ticket-at-a-time), which means the "every MUST is a hook" goal isn't fully met. Acceptable because the alternative is worse-than-prose (hook spam that gets disabled).

### Option C — split each hook into its own PR

One PR per hook, each with its own Rex review cycle and CEO approval.

**Pros:** smaller reviews, easier to revert individual hooks.

**Cons:** four round trips instead of one, cross-PR coupling via `settings.json`, audit doc can't land until all hooks merge, 4x the CEO-approval-moment overhead.

## Decision

**Chosen: Option B** — ship the four hooks in one PR with narrow defaults and project-config overrides.

**Why:**

1. The audit's core finding is "mechanize the ones you can without creating false-positive spam." Option A loses that by being too broad. Option C fragments the work.
2. Narrow defaults + config overrides is the right shape because apexyard is a forkable framework. The defaults should be safe-for-everyone; each fork tightens/loosens to match its own tech stack.
3. All four hooks share infrastructure (`settings.json` wiring, `.claude/hooks/README.md` section, multi-line `-m` parsing from the verify-commit-refs fix in #14). Shipping as one PR avoids duplicating that machinery across four PRs.
4. One PR = one Rex cycle = one CEO approval moment. Current session throughput is the binding constraint, not review-surface width.

## Rules explicitly staying advisory (not mechanized by this ticket)

These were considered for mechanization and deliberately left as prose, with a plan to label them explicitly in the follow-up audit doc:

- **`>80% coverage for domain logic`** — project-specific. Coverage reports live in each project's CI, not the framework. A framework-level hook would need to know the project's coverage tool, output format, and thresholds. Too brittle. Stays advisory; each project enforces in its own CI.
- **`No bare any types without justification`** — lint-level concern. Needs static analysis, not a shell hook. Belongs in each project's ESLint/tsconfig, not the framework.
- **`Domain layer has no external dependencies`** — architectural, needs import-graph analysis. Same answer: lint-level, per-project.
- **`One ticket at a time`** — behavioral, hard to detect mechanically. The closest proxy would be "block `gh pr create` if there's already an open PR on this branch's parent issue", but that's complex for marginal value. Stays prose.
- **`Testing pyramid 70/20/10`** — advisory metric, not a threshold. Not mechanizable.
- **Trigger patterns for role activation (`role-triggers.md`)** — context-aware activation, language-level matching. Not mechanizable in shell hooks.
- **`/decide` trigger patterns ("when you say 'I'll use X' → stop")** — self-discipline on prose output. Same class as the rejected "lint Claude's chat output" idea in #14.

The follow-up audit doc (`docs/rule-audit.md`, separate ticket) will list these explicitly with "advisory, see reason X" labels.

## Threshold decisions (the actual content of this AgDR)

### Architecture paths (`require-agdr-for-arch-changes.sh`)

Default regex patterns:

```
infrastructure/
\.tf$
\.tfvars$
^terraform/
^docker-compose.*\.ya?ml$
^Dockerfile
^\.github/workflows/
```

**Deliberately excluded:**

- `package.json`, `go.mod`, `requirements.txt`, etc. — dependency bumps are too frequent and too small for an AgDR each. Projects that care about this can override `architecture_paths` to add them.
- `openapi.yaml`, `*.graphql` — API schemas might deserve AgDRs, but not every schema tweak. Too noisy as a default.
- `src/domain/**/entities/` — architectural in DDD projects, but the path is project-specific and would false-positive everywhere that uses a different layout.

### UI paths (`require-design-review-for-ui.sh`)

Default regex patterns:

```
\.tsx$
\.jsx$
\.vue$
\.svelte$
\.css$
\.scss$
\.sass$
\.less$
design-tokens
```

**Deliberately excluded:**

- `\.ts$`, `\.js$` — the original draft had `\.tsx?$` and `\.jsx?$` which matched plain `.ts` and `.js`. Caught in smoke test. Plain `.ts`/`.js` are much more often server/build code than UI. Forking the pattern would have caused false positives on every backend PR.
- HTML files — Next.js / Vue projects don't have plain `.html` often; static sites might. Not a default.
- Image files — bitmap changes are visual but don't need a *designer's* review in most teams. Content concern, not design.

### Commit message types (`validate-commit-format.sh`)

Accepted types: `feat, fix, refactor, test, docs, chore, style, perf, build, ci, revert`.

This is the same list used in the PR-title regex in `git-conventions.md` (plus `revert` which PR titles allow via the existing regex). Keeping the commit list aligned with the PR list prevents the "commit passes validation but PR title using the same type fails" asymmetry.

### Red-CI check semantics (`block-merge-on-red-ci.sh`)

- **Green** → allow
- **Red** (any fail/cancelled/timeout) → block
- **Pending / in-progress** → block (the rule says "no red CI", and pending is not green)
- **No checks configured** (`"no checks reported"` text from `gh pr checks`) → allow with a NOTE (legitimate state for repos without CI; common in early apexyard forks)

## Consequences

**Positive:**

- Four previously-unenforced rules from `agdr-decisions.md`, `pr-quality.md`, and `git-conventions.md` are now mechanical.
- Claude (or any user of apexyard) will hit a hard-stop at commit/merge time if they try to bypass these rules.
- Design decisions for the hooks are documented in one place (this AgDR) so future contributors understand why the defaults are narrow and how to widen them via project-config.

**Negative / tradeoffs:**

- The hooks won't catch rules that can't be mechanized in a shell harness. Those stay advisory and depend on self-discipline, same as `ticket-vocabulary.md` from #14.
- Narrow defaults mean some projects will need to customize `project-config.json` to get full coverage. The alternative — broad defaults — was rejected as worse.
- New dependency on `gh pr checks` in `block-merge-on-red-ci.sh`. Assumed already present; apexyard already depends on `gh` throughout.

**Follow-ups captured:**

- **docs/rule-audit.md** — the full audit table listing every MUST and whether it's mechanized / advisory / deferred. Separate ticket.
- **Warning → blocker upgrade** for `validate-branch-name.sh` and `validate-pr-create.sh`'s format checks. Breaking change, deserves its own ticket and explicit scope approval.
- **`commit_types` project-config override** for `validate-commit-format.sh`. Not needed for MVP, nice-to-have.

## Artifacts

- Ticket: [me2resh/apexyard#13](https://github.com/me2resh/apexyard/issues/13)
- Hooks added (in this PR): `require-agdr-for-arch-changes.sh`, `require-design-review-for-ui.sh`, `block-merge-on-red-ci.sh`, `validate-commit-format.sh`
- Companion PRs merged earlier in the same session: `646302e` (explicit merge approval, #11), `d0a2128` (ticket vocabulary + verify-issue-exists, #14)
- Hooks README section documenting the four new hooks (this PR)

## Post-ship amendments

This AgDR is historical — the threshold decisions below reflect the state at the time of writing (2026-04-11, commit `772506e` on PR #17). Post-ship refinements are tracked here as a changelog so the original decision block stays intact.

### 2026-04-11 — architecture path anchors refined for monorepos ([#18](https://github.com/me2resh/apexyard/issues/18) / PR to follow)

Rex's review of PR #17 flagged that the original `^Dockerfile` / `^docker-compose.*` anchors silently missed monorepo layouts (`backend/Dockerfile`, `web/docker-compose.yml`). The original unanchored `infrastructure/` matched `docs/infrastructure/notes.md` as a false positive. Refined defaults:

**Removed from defaults** (ambiguous directory name, false-positive-prone):

- `(^|/)infrastructure/` — "infrastructure" is used for IaC in some projects and library code in others. Dropped in favor of relying on file-extension patterns. Projects that use CDK/Pulumi with plain `.ts`/`.py` files in `infrastructure/` should override via `.architecture_paths` (e.g. `(^|/)infrastructure/.*\.(ts|py|go)$`).
- `(^|/)terraform/` — same ambiguity, and Terraform files are already caught unambiguously via `\.tf$` and `\.tfvars$` at any depth.

**Anchoring updated to `(^|/)` prefix** so monorepo subdirectory paths match:

- `^Dockerfile` → `(^|/)Dockerfile`
- `^docker-compose.*\.ya?ml$` → `(^|/)docker-compose.*\.ya?ml$`

**Verified with 21 path fixtures** in PR #18's smoke tests (13 should-match cases including monorepo layouts, 8 should-NOT-match cases including the previously-false-positive `docs/infrastructure/` and `docs/terraform-primer.md` paths).

**Also in #18**: dead-code cleanup (`FAILED_COUNT` / `PENDING_COUNT` in `block-merge-on-red-ci.sh` lines 69–70, defined but never referenced).
