---
name: mutation-test
description: Mutation-testing sensor — language-dispatched (Stryker/MutPy/go-mutesting/mutant), milestone-cadence not per-PR, exit-3 graceful-degrade.
argument-hint: "[project-path] [--language=ts|js|python|go|ruby] [--runner=<name>] [--threshold=<N>] [--check-only]"
allowed-tools: Bash, Read, Glob, Grep, Write
---

# /mutation-test — Behaviour-Quality Sensor

Runs **mutation testing** against a project to measure whether the test suite *constrains* behaviour, not just *executes* lines. Coverage % answers "did the test run this line?"; mutation testing answers "if I broke this line, would the test catch it?".

Pairs with `/launch-check` (fans out to this skill at milestone boundaries) and complements the existing `> 80%` coverage gate from `.claude/rules/workflow-gates.md`. **Not** run per-PR — see § "When to use this" for the cadence rationale.

## Runtime requirements

| Dependency | Used for | Without it |
|------------|----------|------------|
| `bash` ≥ 4 | The skill itself | Required |
| `git` | Project detection + path resolution | Required |
| `stryker` (`@stryker-mutator/core`) | TS / JS mutation runner | Skill exits 3 with the install one-liner if TS/JS detected |
| `mut.py` (MutPy) | Python mutation runner | Same shape |
| `go-mutesting` | Go mutation runner | Same shape |
| `mutant` (`mutant-rspec` / `mutant-minitest`) | Ruby mutation runner | Same shape |
| `jq` | Stryker JSON report parsing | Required when Stryker is the chosen runner |

Same disclosure shape as `/pdf` and `/process` — disclosed up front, surfaced when invoked, never silently fails.

## Path resolution

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
projects_dir=$(portfolio_projects_dir)
workspace_dir=$(portfolio_workspace_dir)
```

Defaults to single-fork mode. Split-portfolio v2 adopters resolve to the sibling private repo transparently. Don't hardcode `projects/` or `workspace/` literals.

## Usage

```
/mutation-test                          # run against cwd (must be inside workspace/<name>/)
/mutation-test workspace/example-app    # run against an explicit project path
/mutation-test --language=python        # force the Python runner (skip detection)
/mutation-test --runner=stryker         # force a specific runner regardless of language
/mutation-test --threshold=70           # one-off threshold override (doesn't write to config)
/mutation-test --check-only             # report which runners are installed, do nothing else
```

## When to use this

| Trigger | Use `/mutation-test`? |
|---------|----------------------|
| Milestone boundary (epic done, release prep, launch check) | **Yes** — `/launch-check` dispatches automatically |
| Quarterly health check | Yes — explicit invocation |
| Weekly cron via CI workflow | Yes — adopter wires a scheduled workflow |
| Per-PR pre-merge gate | **No** — too slow (20–40 min on a medium codebase). Rex + the coverage gate cover per-PR test quality. |
| Pre-deploy smoke | No — use `/launch-check` for a full sweep instead |
| After adding new test infrastructure | Yes — confirm the new tests actually constrain |
| First-time on a brownfield project | Yes — expect a low score on the first run; treat it as a baseline |

The skill is **NOT** wired to any pre-commit, pre-push, or merge-gate hook. It runs only when explicitly invoked or when `/launch-check` fans out to it.

## Process

### Step 1 — Resolve the project

```bash
PROJECT_PATH="${1:-$PWD}"
if [ ! -d "$PROJECT_PATH" ]; then
  echo "/mutation-test: project path not found: $PROJECT_PATH" >&2
  exit 2
fi
cd "$PROJECT_PATH"
```

If invoked without an argument, use `$PWD`. If `$PWD` is the ops-fork root (contains `onboarding.yaml` or `.apexyard-fork`), refuse — the audit is for managed projects, not the framework repo itself.

Resolve `<project-name>` from the path:

1. If `$PROJECT_PATH` is under `<workspace_dir>/<name>/...` → `name` is that path segment.
2. Otherwise fall back to `basename "$PROJECT_PATH"` and warn the operator to `/handover` for cross-machine trend continuity.

### Step 2 — Detect the language

File-count heuristic across the project tree (excluding `node_modules`, `.venv`, `vendor`, `dist`, `build`, `.next`):

```bash
ts_count=$(find . -type f \( -name '*.ts' -o -name '*.tsx' \) ! -path '*/node_modules/*' ! -path '*/dist/*' | wc -l)
js_count=$(find . -type f \( -name '*.js' -o -name '*.jsx' -o -name '*.mjs' \) ! -path '*/node_modules/*' ! -path '*/dist/*' | wc -l)
py_count=$(find . -type f -name '*.py' ! -path '*/.venv/*' ! -path '*/__pycache__/*' | wc -l)
go_count=$(find . -type f -name '*.go' ! -path '*/vendor/*' | wc -l)
rb_count=$(find . -type f -name '*.rb' ! -path '*/vendor/*' | wc -l)
```

The language with the highest count wins. TS and JS collapse into the same dispatch ("ts/js"). Ties: prefer the language with the matching config-block runner if set; otherwise prefer ts/js > python > go > ruby (alphabetical-of-the-popular-stack tiebreak).

`--language=<lang>` overrides detection. Mixed-language projects audit only the dominant language in a single run; the report flags the other languages as "not audited in this run; re-run with `--language=<lang>` to cover them".

### Step 3 — Pick the runner

Read `mutation.runner` from `.claude/project-config.json` (merge over `.claude/project-config.defaults.json`):

```json
{
  "mutation": {
    "runner": {
      "ts": "stryker",
      "js": "stryker",
      "python": "mutpy",
      "go": "go-mutesting",
      "ruby": "mutant"
    },
    "threshold": 60
  }
}
```

The configured runner wins. `--runner=<name>` flag wins over config. Otherwise use the default for the detected language.

### Step 4 — Graceful-degradation check

Before running anything, verify the chosen runner is installed:

```bash
case "$RUNNER" in
  stryker)       command -v stryker      >/dev/null 2>&1 || RUNNER_MISSING=1 ;;
  mutpy)         command -v mut.py       >/dev/null 2>&1 || RUNNER_MISSING=1 ;;
  go-mutesting)  command -v go-mutesting >/dev/null 2>&1 || RUNNER_MISSING=1 ;;
  mutant)        command -v mutant       >/dev/null 2>&1 || RUNNER_MISSING=1 ;;
esac
```

If `RUNNER_MISSING=1`, print the install advisory and exit 3:

```
✗ No mutation tester installed for <language> (chosen runner: <RUNNER>).

Per-language install one-liners:
  TS / JS  — npm install --save-dev @stryker-mutator/core
              (then add stryker.conf.json — see https://stryker-mutator.io/docs/stryker-js/)
  Python   — pip install mutpy
              (https://github.com/mutpy/mutpy)
  Go       — go install github.com/zimmski/go-mutesting/cmd/go-mutesting@latest
              (https://github.com/zimmski/go-mutesting)
  Ruby     — gem install mutant-rspec   (or mutant-minitest)
              (https://github.com/mbj/mutant)

Install the runner for your project's language and re-run /mutation-test.
This skill never bundles a mutation runner — same graceful-degrade shape
as /pdf and /process.
```

Exit code **3**. Same shape as `/pdf` and `/process`. The rest of the framework is unaffected.

`--check-only` reports which runners are installed without invoking any and exits 0 if at least one is, exit 3 if none.

### Step 5 — Invoke the runner

The dispatch table (skill resolves the per-runner invocation):

| Runner | Invocation | Report shape consumed |
|--------|-----------|-----------------------|
| `stryker` | `npx stryker run --reporters json,clear-text` then `jq` the `reports/mutation/mutation.json` | JSON: `files.<path>.mutants[]` with `status` ∈ {Killed, Survived, Timeout, NoCoverage, CompileError, RuntimeError} |
| `mutpy` | `mut.py --target <module> --unit-test <tests> --report-html out/` (or `--report yaml`) | Parse the YAML/HTML survivors list |
| `go-mutesting` | `go-mutesting ./...` | Parse the trailing `PASS/FAIL` counts + per-mutant lines |
| `mutant` | `mutant run` (project's `.mutant.yml` config) | Parse the summary table |

The runner's stdout/stderr stream through (so operators can watch progress on long runs). The skill collects the report file at the end.

**Timeout cap:** 90 minutes wall-clock. Beyond that, the skill kills the runner and emits an `incomplete` report flagging the time-out. (Configurable via `mutation.timeout_minutes`.)

### Step 6 — Parse results

Normalise the runner's output into a common record:

```
total_mutants    = sum of all mutant outcomes
killed           = mutants the tests caught
survived         = mutants the tests did NOT catch
timed_out        = runner timed out before the test could finish
no_coverage      = mutated line not exercised by any test
compile_error    = mutant didn't compile (counts as killed in most conventions)
runtime_error    = runner crashed on this mutant (skip)
score_pct        = round(100 * killed / (total_mutants - no_coverage - runtime_error))
```

The denominator deliberately excludes `no_coverage` and `runtime_error` — the convention is to score only the mutants that were genuinely tested. `compile_error` counts as killed (Stryker's default; MutPy and go-mutesting align).

### Step 7 — Render the report

Write to `<projects_dir>/<name>/quality/mutation-<YYYY-MM-DD>.md`. If a report for today already exists, append `-NN` (start at `-01`) so re-runs don't clobber.

Report shape (six sections):

````markdown
# Mutation report — <project> — <YYYY-MM-DD>

| Field | Value |
|-------|-------|
| Project   | <name> |
| Language  | <ts|js|python|go|ruby> |
| Runner    | <stryker|mutpy|go-mutesting|mutant> |
| Threshold | <N>% |
| Command   | `<exact invocation>` |
| Duration  | <HH:MM:SS> |

## Score

**<killed> / <denominator> = <score_pct>%** — <PASS|WARN below threshold of <N>%>

## Summary

| Outcome | Count | Notes |
|---------|-------|-------|
| Killed         | <N> | Test suite caught the mutation |
| Survived       | <N> | **Test gap** — investigate top-5 below |
| Timed out      | <N> | Counts as killed in most conventions |
| No coverage    | <N> | Mutated line not exercised by any test |
| Compile error  | <N> | Counts as killed |
| Runtime error  | <N> | Excluded from score |

## Top-5 survived mutants

For each (up to five), with file:line, mutator name, original snippet, mutated snippet, why-it-survived hint:

### 1. `src/foo.ts:42` — ArithmeticOperator (`+` → `-`)

```ts
// Original
return a + b;

// Mutated
return a - b;
```

**Hint:** the test asserts `result` is a number, not the specific value. Tighten the assertion to `expect(result).toBe(5)`.

### 2. ...

(Up to 5 — if there are more, summarise the long tail as a count by mutator type.)

## Trend (last 5 runs)

| Date | Score | Threshold | Verdict |
|------|-------|-----------|---------|
| 2026-05-20 | 64% | 60% | PASS |
| 2026-04-29 | 58% | 60% | WARN |
| ...        | ...  | ...   | ...    |

(Section omitted if there are no prior reports.)

## Recommendations

- File-specific test gaps surfaced above
- Equivalent-mutant suppression candidates (mutants the runner classified survived but that look semantically equivalent)
- Runner-config tweaks (e.g. `stryker.conf.json` `ignorePatterns`)
````

### Step 8 — Emit a one-line verdict to stdout

Same scannable shape as `/launch-check`:

```
✓ MUTATION TEST — <project> — <score_pct>% (threshold <N>%) — PASS
  Report: projects/<name>/quality/mutation-<YYYY-MM-DD>.md
```

or:

```
⚠ MUTATION TEST — <project> — <score_pct>% (threshold <N>%) — WARN
  Below threshold. Top-5 survived mutants in:
  projects/<name>/quality/mutation-<YYYY-MM-DD>.md
```

WARN does **not** block anything mechanically. The signal is advisory.

### Step 9 — Optional auto-ticket offer

```
Want me to file a [Task] ticket to address the top survived mutants? [y/N]
```

If yes → run `/task` with the prefilled body (skill stays out of `gh issue create` directly; the structured-ticket gate fires through `/task`). If no → exit cleanly.

## Config

`.claude/project-config.defaults.json` ships a `mutation` block:

```json
"mutation": {
  "runner": {
    "ts": "stryker",
    "js": "stryker",
    "python": "mutpy",
    "go": "go-mutesting",
    "ruby": "mutant"
  },
  "threshold": 60,
  "timeout_minutes": 90
}
```

Adopters override per-project in `.claude/project-config.json`:

```json
{
  "mutation": {
    "threshold": 70,
    "runner": { "python": "cosmic-ray" }
  }
}
```

(Per-key shallow-merge — overriding `runner.python` doesn't blow away the other languages' defaults.)

## Rules

1. **Never run per-PR.** The skill is milestone-boundary + on-demand + weekly-cron only. The framework does not wire it to any pre-commit, pre-push, or merge-gate hook.
2. **Graceful-degrade on missing runner.** Exit 3 + advisory — never block adopters who don't want the audit. Same shape as `/pdf` and `/process`.
3. **Report is dated + per-project.** `projects/<name>/quality/mutation-<YYYY-MM-DD>.md`. Re-runs on the same day append `-NN` rather than clobber.
4. **Below-threshold is WARN, not FAIL.** Mutation testing is a leading indicator, not a launch blocker. The verdict surfaces the gap; the operator decides whether to address now or in the next sprint.
5. **Run from inside the project workspace.** The skill checks `workspace/<name>/`, not the ops repo.
6. **No ticket creation without explicit operator yes.** Step 9 offers; doesn't auto-file.
7. **Mixed-language projects audit only the dominant language per run.** Re-run with `--language=<other>` to cover the rest.

## Implementation notes

| File | Purpose |
|------|---------|
| `.claude/skills/mutation-test/SKILL.md` | This file — the skill spec |
| `.claude/skills/mutation-test/detect.sh` | Language detection + runner-availability check (shared between full and `--check-only` modes) |
| `.claude/skills/mutation-test/tests/smoke.sh` | Language-detection + graceful-degradation + report-shape tests |
| `.claude/project-config.defaults.json` → `mutation.*` | Default runner map + threshold + timeout |
| `.claude/skills/launch-check/SKILL.md` § "10. Behaviour quality" | The launch-check dimension that dispatches here |

Design rationale: see [`docs/agdr/AgDR-0045-mutation-test-skill.md`](../../../docs/agdr/AgDR-0045-mutation-test-skill.md).

## See also

- AgDR-0045 — runner choices, threshold rationale, why-not-per-PR, graceful-degrade pattern, report location convention
- `.claude/skills/launch-check/SKILL.md` — milestone-boundary umbrella that fans out to this skill
- `.claude/skills/pdf/SKILL.md` — the graceful-degrade shape this skill mirrors
- `.claude/skills/process/SKILL.md` — sibling skill with the same exit-3 install-advisory pattern
- `.claude/rules/workflow-gates.md` — the existing > 80% coverage gate that this skill complements (coverage = was-it-executed; mutation = does-it-constrain)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
