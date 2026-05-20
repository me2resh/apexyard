# AgDR-0045 — `/mutation-test`: behaviour-quality sensor closes the behaviour-harness gap

> In the context of the framework's existing coverage-% gate proving a weak signal for test-suite quality (100% coverage with `assert(true)` everywhere passes the gate but constrains no behaviour), facing the choice of which mutation testers to dispatch across, what threshold to set, how to surface results, and whether to run per-PR or on-demand, I decided to ship a **standalone `/mutation-test` skill** that dispatches across **Stryker (TS/JS), MutPy (Python), go-mutesting (Go), mutant (Ruby)** with a **default 60% threshold**, runs on **`/launch-check` / weekly cron / explicit invocation only** (never per-PR), graceful-degrades to **exit 3 + advisory** when no runner is installed, and writes a dated report to **`projects/<name>/quality/mutation-<YYYY-MM-DD>.md`** — accepting that mutation testing is a stricter measure than coverage and a slower one (30 min on a medium codebase), so the framework treats it as a milestone-boundary sensor, not a per-commit gate.

## Context

The framework already enforces a **> 80% coverage gate** on new code via `.claude/rules/workflow-gates.md` and the PR-quality checklist. But coverage % answers only one question — *"did the test run this line?"* — which is a necessary-but-not-sufficient signal for "the test suite constrains behaviour". The pathological case (100% coverage with `assert(true)` in every test) passes the gate and constrains nothing.

Industry **behaviour harness** writing names this gap explicitly as the third regulation dimension after maintainability and architecture fitness:

- **Maintainability harness** — ApexYard covers this well: Rex (code review agent), handbooks (advisory + blocking rules), `/codify-rule` (turning review comments into handbook entries).
- **Architecture-fitness harness** — partially covered: `/c4`, `/dfd`, `/tech-vision`, `require-agdr-for-arch-changes.sh` gate.
- **Behaviour harness** — the weakest dimension today. AI-generated tests plus a coverage % gate. No measure of whether the tests actually constrain behaviour.

Mutation testing flips the question from *"did the test execute this line?"* to *"if I broke this line, would the test catch it?"*. A test that catches the mutation is a test that constrains behaviour; a test that doesn't is theatre. Mutation **score** (killed / total) is the headline number.

Three live problems followed:

1. **Which runner per language?** Mutation testers are heavily language-specific. Stryker dominates TS/JS, MutPy dominates Python, go-mutesting is the most-maintained Go option, mutant is Ruby's standard. There's no cross-language aggregator. The framework has to dispatch.
2. **What threshold?** Coverage % gates at 80%. Mutation score is a stricter measure (a mutant that's semantically equivalent to the original survives even on perfect tests), so 80% is unreachable on most real codebases. Industry consensus from the mutation-testing community is 50–70%. The framework needs a defensible default.
3. **Per-PR vs on-demand?** Mutation testing is slow — Stryker on a medium TS codebase takes 20–40 minutes. Running it on every PR would dominate CI time and force the gate to be a soft warning anyway. But the value is real, so the framework needs a delivery channel.

## Options Considered

### Axis 1 — Single runner vs language-dispatched

| Option | Pros | Cons |
|--------|------|------|
| Hardcode Stryker, document "TS/JS only" | Smallest skill surface. One install path. | Excludes every Python / Go / Ruby project in the portfolio. Doesn't match the framework's polyglot stance (handbooks/language/, golden-paths/, etc.). |
| Language-dispatch across Stryker / MutPy / go-mutesting / mutant (chosen) | Adopter on any of the four supported languages gets the audit. Single skill surface from the operator's view. | One install per language to document. Each runner has different invocation, different report format, different config knobs — the dispatch table carries the variance. |
| Wrap a polyglot meta-runner (e.g. some emerging cross-lang mutation tool) | One install, all languages. | No mature cross-language mutation runner exists at v1 time. The closest options are immature, slow, or single-language-disguised. |

### Axis 2 — Default threshold

| Option | Pros | Cons |
|--------|------|------|
| Match coverage at 80% | Mental-model consistency. | Unreachable on real codebases — equivalent-mutant survivors push real-world scores into the 50–75% band. A 80% default would force adopters to either suppress equivalent mutants by hand (huge effort) or live with a permanently-red gate. |
| 50% — lower bound of industry consensus | Easy to hit. Most existing test suites pass. | Too lenient — the value of the sensor is "find the gaps", and 50% means half the mutations slip. Adopters get false comfort. |
| **60%** (chosen) | Middle of the industry-consensus band. Achievable on tests-as-actually-written-by-humans suites. Strict enough to surface real gaps. | Some idiomatic codebases (especially those heavy on equivalent-mutant patterns like simple getters/setters or unrolled-loop optimisations) sit naturally lower. Mitigated by per-project override via config. |
| 70% — upper bound | Forces high-quality tests. | Pushes adopters into mutant-suppression configuration before the sensor pays off. |

### Axis 3 — Per-PR vs on-demand vs milestone

| Option | Pros | Cons |
|--------|------|------|
| Per-PR (block merge on below-threshold) | Tight feedback loop. Same shape as the coverage gate. | A 30-minute audit on every PR is incompatible with normal review cadence. Even on a self-hosted runner pool, queuing dominates. Adopters would suppress or skip the gate. |
| Per-PR (warn-only) | Tight feedback loop, no merge block. | Still 30 min of CI per PR. Adopters disable. |
| **`/launch-check` + weekly cron + on-demand** (chosen) | Mutation testing fits the milestone-boundary shape exactly — measure at the moments where the answer changes adopter behaviour (epic completion, release prep, monthly health check). Doesn't burn per-PR CI minutes. | Slower feedback loop (typically weekly, not per-commit). A failing test that mutation testing would catch can land before the next audit. Mitigated by Rex's per-PR test-coverage advice + the existing coverage gate as the first-line defence. |
| `/launch-check` only (no cron, no on-demand) | Single trigger to learn. | Adopters who want quarterly health-check trends don't get them without manually re-running. |

### Axis 4 — Runner-missing behaviour

| Option | Pros | Cons |
|--------|------|------|
| Hard-fail (exit 1) when no runner installed | Forces install. | Punishes adopters who don't want the audit. Same dynamic as making pandoc a hard dep for `/pdf`. |
| Silent skip | No friction. | Adopter never discovers the audit exists. |
| **Exit 3 + install advisory** (chosen — matches `/pdf` and `/process`) | Adopter sees what's missing and the install one-liner. Skill stays slim — no runner is bundled into the framework. | One more skill with its own install-advisory shape. Mitigated by the uniformity: `/pdf`, `/process`, `/c4` (Mermaid lint), and now `/mutation-test` all use the same exit-3 pattern. |

### Axis 5 — Report location

| Option | Pros | Cons |
|--------|------|------|
| `projects/<name>/audits/mutation-test/<YYYY-MM-DD>.md` (full audit-family shape) | Matches `/launch-check`, `/threat-model`, `/security-review` — same persistence helper, same trend renderer. | The audit family expects `audit_run_persist` to drive a findings table with PASS/WARN/FAIL severities; mutation testing's output is more directly a score + survived-mutant catalogue. Forcing it into the audit-family shape loses information. |
| **`projects/<name>/quality/mutation-<YYYY-MM-DD>.md`** (chosen — its own subdir under `quality/`) | Mutation reports are a distinct artefact class (score + survivors with code snippets), not a severity-graded audit. The `quality/` subdir leaves room for sibling behaviour-harness skills (e.g. a future `/property-test-coverage` audit) without forcing each into the audit-family shape. | One more subdir convention to learn. Mitigated by the `quality/` name being self-documenting. |
| `projects/<name>/mutation/<YYYY-MM-DD>.md` (its own top-level subdir per skill) | Self-contained. | Proliferates per-skill subdirs — every new sensor would want one. The `quality/` umbrella is the right scope for sensors that aren't graded audits. |

## Decision

### Chosen on axis 1 — Language-dispatched

The dispatch table:

| Language | Runner | Detection signature | Install one-liner |
|----------|--------|---------------------|-------------------|
| TS / JS | Stryker | `*.ts` + `*.tsx` + `*.js` file count exceeds Python/Go/Ruby | `npm install --save-dev @stryker-mutator/core` |
| Python | MutPy | `*.py` file count dominant; `pyproject.toml` or `setup.py` present | `pip install mutpy` |
| Go | go-mutesting | `*.go` file count dominant; `go.mod` present | `go install github.com/zimmski/go-mutesting/cmd/go-mutesting@latest` |
| Ruby | mutant | `*.rb` file count dominant; `Gemfile` present | `gem install mutant-rspec` (or `mutant-minitest`) |

Language detection is a file-count heuristic. The configured runner (`mutation.runner` in `.claude/project-config.json`) wins when set; otherwise the language detection picks. Mixed-language projects (e.g. a TS frontend + Python backend) default to the dominant language and surface a note that the other language's coverage isn't audited in this run — the operator can re-run with `--language=python` to audit the other side.

### Chosen on axis 2 — 60% default

`mutation.threshold` defaults to `60` in `.claude/project-config.defaults.json`. Below-threshold reports flag in `/launch-check` output as `WARN` (not `FAIL` — see axis 3). Adopters override per-project in `.claude/project-config.json`.

Operators who hit the threshold in their first run and want to push higher should bump it incrementally — a 60→70 jump usually surfaces a long tail of work that's better as multiple small PRs than one mutation-mass-fix PR.

### Chosen on axis 3 — Milestone-boundary + on-demand only

The skill is invoked in three ways:

1. **`/launch-check` fans out to it** as a 10th dimension ("Behaviour quality"). Below-threshold projects get a `WARN` (not `FAIL`) in the verdict — the rationale being that mutation testing is a leading indicator, not a launch-blocker.
2. **Weekly cron** (via a CI workflow the adopter wires in — example template in `golden-paths/pipelines/mutation-test.yml.example`). Cadence is the adopter's call.
3. **Explicit `/mutation-test [project]`** invocation when the operator wants a fresh number.

Per-PR is explicitly **out of scope**. Rex still does the per-PR test-quality review; the coverage gate still fires at 80%; mutation testing is the slower, deeper measure that lives one cadence above.

### Chosen on axis 4 — Exit 3 + advisory

When `command -v stryker / mut.py / go-mutesting / mutant` all return non-zero, the skill exits 3 with an advisory naming the install one-liner per language. Same shape as `/pdf` and `/process` (BPMN lint). Adopters who don't want the audit pay zero install cost.

### Chosen on axis 5 — `projects/<name>/quality/mutation-<YYYY-MM-DD>.md`

Six sections, in order:

1. **Header** — date, runner, language detected, threshold, project, command invoked.
2. **Score** — `killed / total = X%` with a PASS/WARN line against the threshold.
3. **Summary table** — total mutants, killed, survived, timed-out, no-coverage, equivalent-suppressed.
4. **Top-5 survived mutants** — per-mutant: file path, line, mutator name, original code snippet, mutated code snippet, why-it-survived hint.
5. **Trend (optional)** — last 5 runs' scores, if any. Read from `projects/<name>/quality/mutation-*.md` (filename-based — no JSON-history dependency at v1).
6. **Recommendations** — operator-actionable next steps (file-specific test gaps, equivalent-mutant suppression candidates, runner-config tweaks).

## Consequences

### Positive

- **Closes the behaviour-harness gap** — adopters now have a sensor for "do the tests constrain behaviour?", not just "do the tests execute the lines?".
- **Polyglot from day 1** — TS, Python, Go, Ruby covered. Adding a language is a row in the dispatch table + a runner one-liner.
- **Zero install cost for non-users** — graceful-degrades the same way `/pdf` and `/process` do. Adopters who never want the audit are unaffected.
- **Fits the milestone-boundary mental model** — `/launch-check` already covers nine dimensions; adding "Behaviour quality" as the tenth slots in cleanly without forcing a new audit cadence on adopters.
- **Per-project threshold override** — adopters whose codebase legitimately sits below 60% (heavy equivalent-mutant patterns, large generated-code surface) can drop the threshold without forking the skill.

### Negative

- **30+ minute audit time** is a real cost. The framework mitigates by making the audit milestone-boundary-only, but adopters running it weekly are paying it weekly. There's no obvious shortcut at v1.
- **Equivalent-mutant noise** — some survived mutants are semantically equivalent to the original (e.g. `i++` vs `i = i + 1`). The runner filters most, but the top-5 list will sometimes include false positives. The report's "why-it-survived hint" flags candidates for operator triage but can't suppress them automatically.
- **Per-language runner divergence** — Stryker has a different config shape from MutPy from go-mutesting from mutant. The skill's dispatch table papers over the invocation difference, but operators who want to tune the runner deeply still need to learn the per-language tool. The skill names the docs URL in the report.
- **Mixed-language projects audit only the dominant language** in a single run. Operators who care equally about a TS frontend and a Python backend need two runs (or `--language=...` overrides).
- **No per-PR mutation gate** means a test-quality regression can land before the next audit catches it. Mitigated by Rex + the coverage gate, which remain the per-PR defences.

### Migration / rollback

- **No data migration needed** — the skill is additive. No existing artefacts touched.
- **Rollback** is `git revert` of the introducing PR; no state in `.claude/session/` is created.
- **Adopters with no mutation runner installed** see exit 3 + advisory; the rest of `/launch-check` (the other 9 dimensions) runs unaffected.

## Artifacts

- Issue: [me2resh/apexyard#299](https://github.com/me2resh/apexyard/issues/299)
- PR: <to be filled at merge time>
- Skill: `.claude/skills/mutation-test/SKILL.md`
- Config defaults: `.claude/project-config.defaults.json` → `mutation.runner` map + `mutation.threshold`
- Launch-check wiring: `.claude/skills/launch-check/SKILL.md` § "The 10 dimensions" + § "Deep-dive companions"
- Tests: `.claude/skills/mutation-test/tests/smoke.sh`
- Sibling patterns this AgDR reuses:
  - AgDR-0034 — graceful-degradation shape (exit 3 + install advisory) from `/pdf`
  - AgDR-0025 — `/process` graceful-degrade for `bpmnlint`
  - AgDR-0043 — `/generative-engine-audit` sibling-skill pattern (dispatched from `/launch-check`)
  - AgDR-0019 — audit artefact persistence (the `quality/` subdir is sibling to `audits/<dim>/` rather than nested, because mutation reports are score + catalogue, not severity-graded findings)
