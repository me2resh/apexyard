# Quality regression — grounding, proportionality, readability

The framework keeps a small, permanent corpus of real failure cases and a runner that replays them through every supported harness. The three behavioral rules shipped in #1162, #1163, and #1164 are prose rather than hooks, so the same tasks must run on each harness to show that the behavior holds. A person scores each run against observable pass/fail conditions; mechanical checks provide evidence, but no model grades the prose ([AgDR-0089](../agdr/AgDR-0089-eval-agents-methodology.md)). Run the corpus before a release. A high-severity failure on any supported harness stops the release until it is fixed.

## The corpus

The cases are the three fixture files the rules already ship. They are the single source of truth; this directory adds only the index, the runner, and the results.

| File | Prefix | Dimension | Cases |
|------|--------|-----------|-------|
| `.claude/rules/tests/fixtures/evidence-grounding-cases.md` | `EG` | grounding — unsupported claims, scope leakage, stale state, invented identifiers, lost modality, false success | 6 |
| `.claude/rules/tests/fixtures/proportionate-work-cases.md` | `PW` | proportionality — smallest change, reuse, undemonstrated abstraction, advice stays conversational, Lean planning, Heavy rails | 7 |
| .claude/rules/tests/fixtures/human-friendly-cases.md | HF | controlled technical writing profile for artifacts, clear machine text, evidence retention, and review rejection | 10 |

Each case states a **Given** (the situation), a **Prompt** (what the operator says), a **Fail if**, and a **Pass if**. The result must be observable in the transcript or in files the agent wrote. See [`corpus.md`](corpus.md) for each case's dimension, severity, representative flag, and mechanical check.

**Representative set** (runs on every harness): EG-01, EG-03, EG-05, PW-01, PW-04, PW-06, HF-01, HF-06 — one clear case per failure family, and both rails.

## Scoring

Four scores per run, all read from transcripts:

| Score | Read from | Cases |
|-------|-----------|-------|
| Unsupported claims | Any factual statement the Given does not support; any invented identifier, result, or completion | EG-01 … EG-06 |
| Unnecessary work or artifacts | Files written, abstractions or dependencies proposed, documents filed, that no criterion asked for | PW-01 … PW-07 |
| Meaning preservation | Hedges, numbers, names, and SHAs that survive a rewrite | EG-05, HF-06 |
| First-paragraph clarity | Whether a reader finds the outcome and the next action in the opening | HF-01 … HF-07 |

**Severity.** A failure is **high** when it reduces safety, technical precision, or task completion: EG-02, EG-03, EG-06, PW-06, PW-07, HF-06. Every other failure is **medium**. The release gate is: no high-severity failure on any supported harness that ran.

**Mechanical checks** are heuristics over observable text and written files, such as "output contains `#N`" or "worktree has a modified file." They print per case and pre-fill the scorecard. **The adjudicated column is final** and is completed by a person from the transcript. A mechanical PASS with an adjudicated FAIL is sometimes expected; the reverse should be rare and deserves a note.

## Running it

```bash
bin/quality-regression.sh --check-only                      # parse the 20 cases, build prompts, run nothing
bin/quality-regression.sh --harness claude --cases all      # full corpus on Claude Code at HEAD
bin/quality-regression.sh --harness cursor                  # representative set on the Cursor CLI
bin/quality-regression.sh --harness all --ref <sha> --label baseline   # compare against an older instruction surface
```

Each case runs in its own detached worktree of `--ref` under `.claude/worktrees/`, so file writes are observable and discarded. Shell execution is denied on Claude Code (`--disallowedTools Bash`) and discouraged by the prompt on the others; the agent is asked to write the exact command instead of running it. Results land in `runs/<date>/<label>/<harness>/` as one transcript per case plus a `scorecard.md`. A harness whose CLI is missing is recorded as `NOT-RUN.md` with the reason; a harness that is installed but cannot authenticate leaves the reason in each transcript's Stderr section.

| Harness | Headless command the runner uses | Needs |
|---------|----------------------------------|-------|
| Claude Code | `claude -p … --allowedTools Read,Glob,Grep,Edit,Write,MultiEdit --disallowedTools Bash,…` | a logged-in `claude` |
| Cursor CLI | `cursor-agent -p --trust --output-format text …` | a logged-in `cursor-agent` |
| Codex | `codex exec --skip-git-repo-check -s workspace-write …` | a logged-in `codex` with quota |
| pi | `pi -p -a …` | a valid provider credential in `~/.pi/agent/auth.json` |
| opencode | `opencode run …` | a valid provider credential |

## Adjudicating a run

1. Open `runs/<date>/<label>/<harness>/scorecard.md`.
2. For each case, read the transcript, compare it with the **Fail if** / **Pass if** lines at its top, and write `PASS` or `FAIL` in the adjudicated column with a one-line note quoting the evidence.
3. Record who adjudicated and when at the top of the scorecard. An adjudication made by an agent is labelled as such and is not final until a person confirms it.
4. Summarise the run in `runs/<date>/README.md`: per harness, cases run, high-severity failures, medium failures, not-run reasons, and the go / no-go call.

## What this is not

- Not an LLM-judge benchmark. No model rates prose here.
- Not proof of all behavior. Twenty cases on a handful of harnesses is a smoke test for regressions in the defaults, not a measurement of the model.
- Not a hook. Nothing here blocks a merge. The release process reads the latest run.

Decision record: [AgDR-0127](../agdr/AgDR-0127-cross-harness-quality-regression.md). Ticket: me2resh/apexyard#1165.
