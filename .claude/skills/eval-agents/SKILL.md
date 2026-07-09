---
name: eval-agents
description: Score a review agent (Rex/Hakim/Tariq) against a labeled PR corpus — ground-truth defect-set overlap, never a prose rubric. Headline metric is approve-precision.
argument-hint: "<rex|hakim|tariq> [--corpus <path>] [--check-only]"
allowed-tools: Bash, Read, Glob, Grep, Agent
---

# /eval-agents — Review-Agent Eval Harness

Scores one of the framework's review agents (Rex / Hakim / Tariq) against a labeled corpus of real, already-reviewed PRs with **frozen ground-truth defect sets**. Reports catch-rate, false-positive-rate, and **approve-precision** (the headline metric) against a configurable pass/fail threshold.

## Why this isn't an LLM-judge rating review prose

Spike #825 tested that shape first — score a review agent's *text output* against a 0-4 rubric, calibrated against recorded verdicts — and found it **at chance** on the one question that matters: was an approval justified? A fluent, verification-heavy wrong approval scored as well as or better than genuinely correct approvals (`docs/spike-825/findings.md`). This skill instead:

1. **Never asks a judge to rate review text.** Ground truth is a frozen set of real defects, established **once, offline, by a human**, from actual re-review disagreements and confirmed fixes — never re-derived at run time, never established by the agent being measured.
2. **Runs the agent-under-test fresh** against the corpus entry's diff, and mechanically/semantically compares its findings to the frozen defect set: caught / missed / false-alarm.
3. **Reports approve-precision as the headline metric** — the rate at which the agent's approvals were actually justified. A missed BLOCKING/HIGH defect is an automatic WARN regardless of the aggregate score.

Full rationale: [AgDR-0089](../../../docs/agdr/AgDR-0089-eval-agents-methodology.md). Corpus format: [`docs/eval-agents/SCHEMA.md`](../../../docs/eval-agents/SCHEMA.md).

## Usage

```
/eval-agents rex                                            # run against the seeded starter corpus
/eval-agents hakim --corpus docs/eval-agents/corpus/hakim.json
/eval-agents tariq --corpus my-corpus.json                  # tariq has no starter corpus — required
/eval-agents rex --check-only                                # validate corpus schema only, no spawns
```

`<agent>` is one of `rex`, `hakim`, `tariq` — the three review agents that produce a verdict over a diff and share the `APPROVED / CHANGES REQUESTED / COMMENT` vocabulary. **Naqid is out of scope for v1** (it challenges premises, not diffs — no defect-set structure to score against; see AgDR-0089 § Decision point 7).

**`--suggest-entries` is not implemented.** #833 scoped an optional corpus-growth-assist mode that would mine `gh` PR/review history for re-review disagreements and escaped-bug patterns (the same shape `docs/eval-agents/README.md` § "Growing the corpus" describes doing by hand) and propose candidate entries for human confirmation. Investigating this against #833's "keep it small or split it out" instruction: `docs/spike-825/judge_calibration.py` — the file #833 named as the source to lift mining logic from — turns out to hold a hand-curated data table of 19 review units the spike's author read and classified manually, not a reusable scan/detect routine; there is no existing mining logic to lift. Building a real one (walking PR review threads via `gh api`, correlating approve→later-CHANGES_REQUESTED and merge→next-commit-touches-same-files patterns, then shaping matches into draft `ground_truth_defects`) is a genuine new feature, not a hardening follow-up, so it's left for a separate ticket rather than folded in here.

## Safety — the agent-under-test never touches a live PR

This is the load-bearing safety property of the whole skill. The real review agents are hard-wired (`.claude/agents/code-reviewer.md` § "HARD STOP" and the equivalent sections in `security-reviewer.md` / `solution-architect.md`) to fetch a live PR, post a real GitHub review comment, and write a real approval marker. An eval run that spawned one of these agents against a real historical PR number would spam an already-merged PR with an eval-only comment and pollute `.claude/session/reviews/`.

**`/eval-agents` never gives the agent-under-test a PR number, a repo, or a tracker reference.** Every spawn is invoked with a bespoke eval prompt over sanitized, standalone diff text. See Step 3 below.

> ## ⛔ MUST NOT be CI-gated until eval spawns can be tool-restricted
>
> **Harness-capability finding (#833, investigated per Hakim's security review of #828):** the strongest version of this mitigation would remove `Bash` from the agent-under-test's spawn entirely — the diff is handed inline in the prompt, so a re-review spawn has no legitimate need for shell access, and removing it converts every contamination vector in this file from "instructed not to" into "cannot." That requires **per-spawn tool subsetting**: the `Agent` tool call that `/eval-agents` issues would need to override the target `subagent_type`'s tool list for just this invocation.
>
> **The `Agent` tool does not expose this.** Its parameters are `description`, `isolation`, `model`, `prompt`, `run_in_background`, and `subagent_type` — there is no `tools` / `allowed_tools` override. Tool access is fixed per `subagent_type`, declared in that agent's own definition file (`.claude/agents/code-reviewer.md` etc. carry a `Tools:` frontmatter line), not overridable by the caller. This is the same shape of gap `.claude/rules/agent-role-selection.md` documents for the spawn boundary generally (AgDR-0056: "the current hook plumbing cannot reliably see into a sub-agent boundary") — here it's the tool *grant*, not a hook, that the spawn boundary can't touch.
>
> A heavier alternative exists — ship dedicated, Bash-free eval-mode agent definitions (`code-reviewer-eval.md` etc.) that `/eval-agents` spawns instead of the real `code-reviewer` / `security-reviewer` / `solution-architect` — but that means forking and hand-maintaining a second copy of each review checklist, which drifts from the real agent over time and is a materially bigger project than this hardening ticket's scope. Left as a follow-up if/when `/eval-agents` needs to move off manual/periodic use.
>
> Until per-spawn tool subsetting exists (or the dedicated-agent-definition alternative ships), the two-check contamination backstop in Step 3e (snapshot-diff + text-scan) is a **mitigation, not a hard sandbox** — the agent-under-test retains normal `Bash` access and could in principle still attempt a tracker call. **`/eval-agents` MUST NOT be wired into CI, a merge gate, a pre-commit hook, or any unattended/scheduled run until this gap closes.** Rule 6 below already scopes v1 to manual/periodic use for a different reason (#824's out-of-scope); this finding is an additional, independent reason the same restriction must hold.

## Process

### Step 1 — Resolve agent + corpus

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
AGENT="$1"   # rex | hakim | tariq
case "$AGENT" in
  rex|hakim|tariq) ;;
  *) echo "/eval-agents: unknown agent '$AGENT' — must be rex, hakim, or tariq" >&2; exit 2 ;;
esac

CORPUS_DIR=$(config_get '.eval_agents.corpus_dir' 'docs/eval-agents/corpus')
CORPUS_PATH="${CORPUS_FLAG:-$CORPUS_DIR/$AGENT.json}"

if [ ! -f "$CORPUS_PATH" ]; then
  echo "/eval-agents: no corpus at $CORPUS_PATH." >&2
  echo "  $AGENT has no seeded starter corpus — pass --corpus <path> explicitly." >&2
  exit 3
fi
```

`tariq.json` does not exist in the seeded set (see `docs/eval-agents/README.md`) — running `/eval-agents tariq` without `--corpus` exits 3 with the message above, same graceful-degrade shape as `/mutation-test` and `/pdf` on a missing dependency.

### Step 2 — Validate corpus schema

```bash
bash .claude/skills/eval-agents/lib/validate-corpus.sh "$AGENT" "$CORPUS_PATH"
```

Abort on any schema violation — do not spend a real agent spawn scoring against a malformed corpus. `--check-only` stops here: print the validator's entry-count summary and exit 0.

### Step 3 — Per-entry: resolve diff, sanitize, snapshot, spawn, score

For each entry in the corpus:

#### 3a. Resolve the diff text

Try local git first (fast path); fall back to the GitHub API (works regardless of local reachability — many review-round commits are squashed away from local history after merge, but remain queryable by SHA via the API indefinitely):

```bash
if git cat-file -e "$COMMIT" 2>/dev/null; then
  DIFF_TEXT=$(git diff "$DIFF_RANGE")
else
  DIFF_TEXT=$(gh api "repos/$REPO/commits/$COMMIT" -H "Accept: application/vnd.github.v3.diff" 2>/dev/null)
fi

if [ -z "$DIFF_TEXT" ]; then
  echo "⚠ $ENTRY_ID: could not resolve diff for commit $COMMIT — skipping, flagged UNRESOLVABLE in report" >&2
  continue
fi
```

Also capture the changed-file list (`git diff --name-only "$DIFF_RANGE"` or the API equivalent) — needed for the diff-engagement mechanical check in 3f.

#### 3b. Sanitize — strip everything that could identify the live PR

Before the diff text reaches the agent-under-test:

- Strip commit-message trailers matching `Closes #\d+`, `Fixes #\d+`, `Refs #\d+`, `Resolves #\d+` (case-insensitive)
- Strip any bare `#\d+` token and any `github.com/...` URL
- Strip the PR title if it was captured separately (corpus entries don't carry PR titles for exactly this reason — see `SCHEMA.md`)

This is a mitigation, not a hard sandbox — see "Residual risk" below.

#### 3c. Snapshot `.claude/session/reviews/` before spawning

```bash
bash .claude/skills/eval-agents/lib/snapshot-diff.sh snapshot \
  .claude/session/reviews "$SNAPSHOT_FILE"
```

`$SNAPSHOT_FILE` is a per-entry scratch path (e.g. `$(mktemp)`), not committed anywhere. This must run immediately before the spawn in 3d — the whole point is capturing the directory's state at the last possible moment the harness controls, so anything the spawn writes shows up in the post-spawn diff in 3f.

#### 3d. Spawn the agent-under-test

Use the `Agent` tool with `subagent_type` mapped from `<agent>`:

| `<agent>` | `subagent_type` |
|---|---|
| `rex` | `code-reviewer` |
| `hakim` | `security-reviewer` |
| `tariq` | `solution-architect` |

Prompt shape (fill in the sanitized diff):

```
This is an EVALUATION run, not a live PR review. You are reviewing a
standalone code change — there is no PR number, no repository context
beyond what's needed to read the diff, and no tracker to report to.

Your system prompt carries a HARD STOP / MANDATORY-ACTIONS section that
normally REQUIRES you to write a local approval marker and post a review via
tracker_review_submit (or the equivalent for your role) before you are done.
**That mandate is explicitly SUSPENDED for this run only.** It does not
apply here — treating it as inactive is the correct behavior for this task,
not a violation of your normal instructions. There is no real PR number and
no marker path to resolve, so attempting to satisfy that mandate would mean
acting on fabricated inputs.

Rules for this run:
- Your only required output is your review, returned as this message's final
  text — checklist, issues found, and verdict. There is no other mandatory
  action; the HARD STOP's marker-write and tracker-submit steps are
  suspended per the paragraph above.
- Do NOT run `gh pr view`, `gh pr diff`, `gh issue`, or any tracker command —
  there is no real PR behind this diff to look up.
- Do NOT call tracker_review_submit — the requirement to do so is suspended
  for this run.
- Do NOT write any file, including an approval marker — same suspension.

--- BEGIN DIFF ---
<sanitized diff text>
--- END DIFF ---

Review this diff and report your findings and verdict.
```

This wording is deliberate (#833, Hakim's security review of #828): telling the agent-under-test "don't do the mandatory thing" *contradicts* its own HARD STOP instead of overriding it, which leaves the two instructions in tension and relies on the sanitized-out PR number to break the tie. Explicitly suspending the mandate removes the tension — the agent isn't refusing a required action, it's correctly recognizing the requirement doesn't apply to this run.

Capture the sub-agent's full returned text as `AGENT_OUTPUT`.

#### 3e. Contamination check (safety backstop) — snapshot-diff is authoritative, text-scan is secondary

Two independent checks, both run before scoring. Either one flagging is sufficient to discard the run.

**Primary — filesystem snapshot-diff (mechanical, cannot be talked around):**

```bash
if ! bash .claude/skills/eval-agents/lib/snapshot-diff.sh check \
       .claude/session/reviews "$SNAPSHOT_FILE" > "$DIFF_REPORT"; then
  # any new / changed / deleted file under .claude/session/reviews/ since 3c
  # => CONTAMINATED, regardless of what AGENT_OUTPUT narrates
  ...
fi
```

This is the load-bearing fix from #833 (Hakim's security review of #828): the original design scanned `AGENT_OUTPUT`'s *narrated* text for signs of a marker write, which a silent `Bash`-redirect write (`echo ... > .claude/session/reviews/<pr>-rex.approved`) never appears in — the agent doesn't have to say anything about a write it performed for the check to miss it. Snapshot-diff instead asks a question the agent's narration cannot influence: **did any file under `.claude/session/reviews/` actually change on disk between 3c and now?** A write that never gets mentioned in `AGENT_OUTPUT` still shows up as a `NEW` or `CHANGED` line in the diff.

**Secondary — text-scan (catches read-only tracker calls the snapshot can't see):** scan `AGENT_OUTPUT` for any sign the agent queried a live tracker despite the instructions: a `gh pr` command echoed in its reasoning, a real `headRefOid`, the corpus entry's actual PR number appearing verbatim, or a posted-review confirmation phrase. This check still matters because a `gh pr view` (a *read*, not a write) leaves no trace in `.claude/session/reviews/` for the snapshot-diff to catch — the two checks cover disjoint failure modes, not overlapping ones.

If either check flags, **discard this run** — mark the entry `CONTAMINATED` in the report (cite which check fired and, for a snapshot-diff hit, the exact path(s) changed) and do not fold it into the aggregate scores. This is the backstop for the residual risk noted in "Safety" above: sanitization in 3b is not a hard sandbox (the agent-under-test retains normal `Bash` access — see the "MUST NOT be CI-gated" callout in "Safety" for the harness-capability finding on why that access can't currently be removed at spawn time), so the harness must be able to notice and discard a leak rather than silently score a compromised run.

#### 3f. Mechanical checks (rule-based, not judgment)

- `produced_output` — `AGENT_OUTPUT` is non-empty
- `valid_verdict` — regex-extracts one of `APPROVED`, `CHANGES REQUESTED`, `COMMENT` from a `### Verdict` (or equivalent) section
- `engaged_diff` — at least one file path mentioned in `AGENT_OUTPUT`'s findings appears in the entry's changed-file list (guards against a generic "looks fine" non-engaged response)

#### 3g. Defect-overlap scoring (the orchestrator's judgment, against a FROZEN key)

For each `ground_truth_defects[]` entry, decide **caught** or **missed**: does `AGENT_OUTPUT`'s findings describe the same substantive problem at (or near) the same location? This is a semantic match performed by whichever model is running `/eval-agents` — it is comparing a candidate answer to an already-fixed answer key, not establishing truth, so it does not trip the self-grading concern AgDR-0089 addresses (that concern is about *who freezes the ground truth*, never about *who checks a candidate against it*).

Separately, flag **false alarms**: any `AGENT_OUTPUT` finding at BLOCKING/HIGH severity that does not correspond to a `ground_truth_defects[]` entry and is judged incorrect (not merely "an additional legitimate observation the corpus doesn't happen to track"). Keep this narrow — real diffs legitimately have addressable nits beyond the seeded defect set; only count a false alarm when the claim itself is wrong.

Compute per entry:

- `verdict_justified` — does the agent's overall verdict match what the ground truth implies? (`APPROVED`/`COMMENT` is justified only if no BLOCKING/HIGH defect exists in the ground-truth set; `CHANGES REQUESTED` is justified if it correctly names at least the highest-severity ground-truth defect.)

### Step 4 — Aggregate

Across all non-`CONTAMINATED`, non-`UNRESOLVABLE` entries:

```
catch_rate_overall     = caught_defects / total_ground_truth_defects
catch_rate_blocking    = caught_{BLOCKING,HIGH}_defects / total_{BLOCKING,HIGH}_defects
false_positive_rate    = false_alarms / total_agent_findings_flagged
approve_precision      = justified_APPROVED_or_COMMENT_verdicts / total_APPROVED_or_COMMENT_verdicts_issued
mechanical_engagement  = entries_with(valid_verdict AND engaged_diff) / total_scored_entries
```

`approve_precision` is undefined (report as `n/a`, not `0`) if the agent never approved anything in this corpus run — don't manufacture a score from an empty denominator.

### Step 5 — Map to 0-4 dimensions (advisory, secondary — never gates pass/fail alone)

| Dimension | 0 | 1 | 2 | 3 | 4 |
|---|---|---|---|---|---|
| **Approve precision** (headline) | 0-20% justified | 21-50% | 51-75% | 76-90% | 91-100% |
| **Catch rate** (overall) | 0-20% caught | 21-40% | 41-60% | 61-80% | 81-100% |
| **False-positive discipline** | FP rate > 60% | 41-60% | 21-40% | 6-20% | 0-5% |
| **Mechanical engagement** | 0-20% engaged | 21-40% | 41-60% | 61-80% | 81-100% |

These four are reported for texture; **the pass/fail verdict in Step 6 is computed directly from the raw metrics against `eval_agents.thresholds`, never from the 0-4 mapping.** This is deliberate — per AgDR-0089, the whole point of the corrected methodology is that a rubric score must never be the correctness oracle again.

### Step 6 — Verdict

```
PASS  if  approve_precision >= thresholds.approve_precision_min
      AND catch_rate_blocking >= thresholds.blocking_catch_rate_min   (default 1.0 — no misses allowed)
      AND catch_rate_overall  >= thresholds.overall_catch_rate_min
      AND false_positive_rate <= thresholds.false_positive_rate_max
WARN  otherwise
```

**WARN is advisory, not blocking** — `/eval-agents` is manual/periodic measurement (#824's explicit v1 scope), not wired to any merge gate, pre-commit, or pre-push hook. A `catch_rate_blocking` miss always forces WARN regardless of how the other three metrics look — one missed BLOCKING defect should never average out against a pile of easy correct approvals.

### Step 7 — Write the report

`<reports_dir>/<agent>-<YYYY-MM-DD>.md` (default `docs/eval-agents/reports/`). Same-day reruns append `-NN` rather than clobber (mirrors `/mutation-test`).

````markdown
# Eval report — <agent> — <YYYY-MM-DD>

| Field | Value |
|---|---|
| Agent | <rex\|hakim\|tariq> |
| Corpus | `<corpus path>` (<N> entries) |
| Scored | <N - contaminated - unresolvable> |
| Contaminated (discarded) | <N> |
| Unresolvable (discarded) | <N> |

## Headline

**Approve-precision: <X>% (<justified>/<total approved>)** — <PASS|WARN against threshold <T>%>

## Metrics

| Metric | Value | Threshold | Verdict |
|---|---|---|---|
| Approve precision (headline) | X% | ≥T% | PASS/WARN |
| Catch rate — BLOCKING/HIGH | X% | ≥T% | PASS/WARN |
| Catch rate — overall | X% | ≥T% | PASS/WARN |
| False-positive rate | X% | ≤T% | PASS/WARN |

## Advisory dimensions (0-4, informational — not part of the verdict above)

| Dimension | Score | Notes |
|---|---|---|
| Approve precision | N/4 | |
| Catch rate | N/4 | |
| False-positive discipline | N/4 | |
| Mechanical engagement | N/4 | |

## Per-entry results

| Entry | PR | Verdict given | Justified? | Defects caught | Defects missed | Notes |
|---|---|---|---|---|---|---|
| rex-792-2ce6708 | 792 | APPROVED | ✗ NO | 0/1 | D1 (BLOCKING) | matches the ground-truth MISS |
| ... | | | | | | |

## Missed BLOCKING/HIGH defects (if any)

For each: entry id, defect description, why the agent's output didn't surface it.

## Discarded runs

For each CONTAMINATED or UNRESOLVABLE entry: id + reason.

## Overall verdict

**PASS** or **WARN** — one line, plain language, matching the headline.
````

### Step 8 — One-line stdout verdict

```
✓ EVAL — rex — approve-precision 67% (2/3), catch-rate 100% blocking/4/6 overall — PASS
  Report: docs/eval-agents/reports/rex-2026-07-09.md
```

or

```
⚠ EVAL — rex — approve-precision 67% (threshold 85%) — WARN
  1 missed BLOCKING defect (rex-792-2ce6708). Report:
  docs/eval-agents/reports/rex-2026-07-09.md
```

### Step 9 — Optional follow-up ticket offer

On WARN only:

```
This run surfaced N missed BLOCKING/HIGH defect(s). File a [Task] ticket to
investigate (or grow the corpus with new confirmed entries)? [y/N]
```

On yes, run `/task` with the prefilled body — the skill stays out of `gh issue create` directly, same pattern as `/mutation-test` Step 9.

## Config

`.claude/project-config.defaults.json` → `eval_agents`:

```json
{
  "eval_agents": {
    "corpus_dir": "docs/eval-agents/corpus",
    "reports_dir": "docs/eval-agents/reports",
    "thresholds": {
      "approve_precision_min": 0.85,
      "blocking_catch_rate_min": 1.0,
      "overall_catch_rate_min": 0.7,
      "false_positive_rate_max": 0.3
    }
  }
}
```

Override per-project in `.claude/project-config.json` (shallow-merge — overriding one threshold doesn't blow away the others).

## Rules

1. **Ground truth is frozen at corpus-authoring time.** The skill never spawns an "oracle" agent at run time to re-derive truth — see AgDR-0089 for why (no model is credibly stronger than the opus-pinned agents being measured; a dynamic oracle is also non-reproducible, which breaks the regression-detection use case).
2. **The agent-under-test never sees a live PR number, repo, or tracker reference.** Sanitize before every spawn (Step 3b); snapshot `.claude/session/reviews/` immediately before every spawn (Step 3c); run the two-check contamination gate — snapshot-diff primary, text-scan secondary — after every spawn (Step 3e). No supported invocation path skips this.
3. **Approve-precision is the headline pass/fail metric.** Never report a single blended score as the verdict.
4. **Any missed BLOCKING/HIGH ground-truth defect forces WARN**, independent of the aggregate score.
5. **The 0-4 rubric dimensions are advisory only.** They never gate pass/fail on their own — this is the load-bearing methodology correction from AgDR-0089; do not let a future edit slide the rubric back into being the correctness oracle.
6. **Not wired to any merge gate, CI, pre-commit, or pre-push hook.** v1 is manual/periodic measurement (#824's explicit out-of-scope: auto-tuning agents from results, a CI-gating eval run).
7. **Corpus curation is manual, human-adjudicated work.** `/eval-agents` validates schema (Step 2), never truth. Do not add a corpus entry without real evidence (`independent_review`, `confirmed_fix`, or `human` in the `oracle` field) — a fabricated defect produces a confidently wrong score.
8. **No ticket creation without explicit operator yes** (Step 9).
9. **`tariq` requires an explicit `--corpus`** — no starter corpus is seeded for it in v1.
10. **`naqid` is not a supported `<agent>` value in v1** — see "Usage" above.
11. **Every score is the output of non-deterministic LLM steps, not a fixed measurement.** Both the candidate spawn (Step 3d) and the defect-overlap match against the frozen key (Step 3g) are judgment calls made by an LLM — the frozen `ground_truth_defects` are fixed, but *matching a fresh run's findings against them* is not a byte-for-byte comparison, and re-running the exact same corpus against the exact same agent can produce a different verdict_justified call on a borderline entry. A score delta between two runs (this week's approve-precision vs. last month's) is **not automatically a real regression** — it can just as easily be run-to-run noise in the matching step. Treat a delta as a prompt to look at *which specific entries* flipped and re-read the agent's actual output for that entry, never as a number to trend-line on its own. This is the same caveat AgDR-0089 and spike #825 already carry for the starter corpus's small N — non-determinism compounds it, it doesn't replace it.

## Implementation notes

| File | Purpose |
|---|---|
| `.claude/skills/eval-agents/SKILL.md` | This file — the skill spec |
| `.claude/skills/eval-agents/lib/validate-corpus.sh` | Schema validator (Step 2 / `--check-only`) |
| `.claude/skills/eval-agents/lib/snapshot-diff.sh` | Filesystem snapshot/check pair — the Step 3c/3e contamination backstop (#833) |
| `.claude/skills/eval-agents/tests/smoke.sh` | Validator smoke tests |
| `.claude/skills/eval-agents/tests/test-snapshot-diff.sh` | Snapshot-diff smoke tests (#833) |
| `docs/eval-agents/README.md` | Corpus directory overview, what's seeded, how to grow it |
| `docs/eval-agents/SCHEMA.md` | Field-by-field corpus format |
| `docs/eval-agents/corpus/rex.json` | Starter corpus — 6 entries |
| `docs/eval-agents/corpus/hakim.json` | Starter corpus — 4 entries |
| `docs/eval-agents/reports/` | Dated run reports land here |
| `.claude/project-config.defaults.json` → `eval_agents.*` | Corpus/report dirs + thresholds |

Design rationale: [`docs/agdr/AgDR-0089-eval-agents-methodology.md`](../../../docs/agdr/AgDR-0089-eval-agents-methodology.md).

## See also

- AgDR-0089 — the full methodology decision (why not a prose rubric, why frozen ground truth, the live-PR-contamination safety design, v1 scope)
- `docs/spike-825/findings.md` + `docs/spike-825/judge_calibration.py` — the spike that disproved the naive approach and that this skill's starter corpus partly re-derives from
- AgDR-0087 — names "measure a specific model against Rex's real review checklist across 10-15 real merged PRs with known outcomes" as the missing evidence for the #660 local-model question; `/eval-agents` is that measurement tool
- `.claude/skills/mutation-test/SKILL.md` — sibling sensor skill this skill's structure mirrors (graceful-degrade, dated reports, config thresholds, optional ticket offer)
- `.claude/rules/agdr-decisions.md` — why this shipped with an AgDR

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
