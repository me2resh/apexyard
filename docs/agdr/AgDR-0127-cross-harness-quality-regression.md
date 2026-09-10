# Cross-harness quality regression as a replayed corpus with human adjudication

> In the context of three new behavioral rules (evidence grounding, proportionate work, writing standard) that no hook can enforce, facing a release that needs evidence the rules hold on every supported harness without reducing safety, precision, or task completion, I decided to replay the rules' own fixture cases through each harness headlessly, score them against their observable pass / fail conditions with mechanical checks plus human adjudication, and keep the runner and results in the repository as a permanent pre-release check, to get release-readiness evidence that is cheap to re-run and honest about what it measures, accepting that twenty cases are a smoke test rather than a benchmark and that some harnesses cannot run until their credentials are valid.

## Context

- #1162, #1163, and #1164 each shipped a rule plus a fixture of human-adjudicated cases. The cases already state a Given, a Prompt, a Fail-if, and a Pass-if. Nothing runs them.
- Five harnesses are supported (`docs/harnesses/`): Claude Code, Cursor, Codex, pi, opencode. Each has a headless mode. On the build machine, Claude Code and the Cursor CLI ran; Codex was at its usage cap; pi and opencode rejected their stored credentials.
- AgDR-0089 tested an LLM judge rating review prose against a rubric and found it at chance. The scoring here cannot repeat that shape.
- The initiative's anti-scope forbids a large evaluation platform before a small corpus proves its value.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Replay the existing fixtures headlessly; mechanical checks + human adjudication; results committed** | Reuses the cases the rules already own; one runner for every harness; observable criteria, no judge; re-runnable in one command | Twenty cases only; adjudication is manual; some harnesses depend on credentials the framework cannot supply |
| LLM-judge scoring against a rubric | Fully automatic | At chance on prose (AgDR-0089); would produce confident numbers with no meaning |
| A new hand-written corpus separate from the fixtures | Could target harness-specific failures | Two sources of truth that drift; the fixtures already encode the failures the rules were written for |
| Live sessions run by a person on each harness | Highest fidelity | Not repeatable, not cheap, and not a permanent check |
| Skip cross-harness runs; trust the static wiring tests | Zero cost | The wiring tests prove the text is present, not that any harness follows it |

## Decision

Chosen: **replay the fixtures headlessly with mechanical checks and human adjudication, and commit the runner and results**, because it turns the cases the rules already ship into the release evidence the milestone asks for, at the cost of one bash script and a results directory.

`bin/quality-regression.sh` parses the three fixture files, builds one prompt per case (Given as "Situation", Prompt as "The operator says"), runs it in a detached worktree of the ref under test with shell execution denied or discouraged, records the transcript and any files written, applies the case's mechanical check where one exists, and writes a scorecard whose adjudicated column a person fills. A representative set of eight cases runs on every harness; the full twenty run on the primary harness. A baseline run against the instruction surface before #1162 gives the "measurable improvement" comparison the kill criterion asks for.

Severity is fixed per case: a failure on EG-02, EG-03, EG-06, PW-06, PW-07, or HF-06 is high because it reduces safety, precision, or completion; every other failure is medium. The release gate is no high-severity failure on any harness that ran.

## Consequences

- `docs/release-process.md` gains a pre-release step: run the corpus, adjudicate, and record the summary. The step is prose; nothing blocks a release mechanically.
- Results are committed under `docs/quality-regression/runs/<date>/`. A harness that could not run is recorded with its reason rather than omitted, so the summary never implies coverage it does not have.
- An adjudication written by an agent is labelled as such and is not final until a person confirms it. The first run's scorecards carry that label.
- The corpus grows only by adding cases to the fixture files; the runner and index need no change for a new case, and the static test pins that the index covers every parsed case.
- The runner is bash 3.2 compatible (macOS default) and shellcheck clean, like every other script under `bin/`.

## Artifacts

- Ticket: me2resh/apexyard#1165
- Predecessors: [AgDR-0124](AgDR-0124-universal-evidence-grounding-contract.md), [AgDR-0125](AgDR-0125-proportionate-work-extends-right-size-tiers.md), [AgDR-0126](AgDR-0126-writing-standard-two-modes.md)
- Methodology precedent: [AgDR-0089](AgDR-0089-eval-agents-methodology.md)
- Runner: `bin/quality-regression.sh` · Index: `docs/quality-regression/corpus.md` · Results: `docs/quality-regression/runs/`
