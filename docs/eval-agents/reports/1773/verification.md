# Slice #1773 verification

The implementation is a local draft. C4 eval evidence is incomplete.
Do not treat schema validation or static tests as a zero-flip result.
No Snapshot or Reconciliation was created.

## Step checklist

- [x] Step 1: add five real Rex delta entries and validate the 15-entry corpus.
- [x] Step 2: implement trusted tier permission, forge tests, and the AgDR-0116 evolution.
- [x] Step 3: implement the 300-token hand-back cap and six-heading short delta format.
- [x] Step 4: recompute the resume window and require the posted prior review as evidence.
- [x] Step 5: run the o1 reviewer metric and report the comparison with its limits.
- [ ] Run the three isolated Rex prompt comparisons. Each has a separate flip table.
- [x] Commit each step locally. No push, branch change, PR, or merge.

Flip tables remain Not run. No push, branch change, PR, or merge occurred.
The orchestrator owns the PR Snapshot and Reconciliation.
Use this checklist and the measurements below in the slice PR body.

## Before and after

| Metric | Before | Current draft or observation | Limit |
|---|---|---|---|
| Rex corpus entries | 10, no delta entries | 15, five delta entries | Four original defect-path checks skip unavailable commits. |
| Tier permission | Self-declared | Trusted base script and stricter Rex result | No new Reduced-Scope procedure. |
| `/code-review` bytes | 15,930 | 15,736 | Cap: 16,000. |
| Reviewer hand-back | Mean 3,543 bytes, issue evidence | Policy cap: 300 tokens | No measured post-change hand-back yet. Bytes and tokens are different units. |
| Delta posted review | Full output template | Six required validator headings, short bodies | Complete checks and evidence remain required. |
| Expired-cache resume threshold | 80k retained tokens with 49,107-token fresh spawn | 26,813 retained tokens with 26,813-token fresh spawn | Startup comparison only, at equal cache-write rates. |
| Warm resume window | Under 5 minutes | Under 4m30s at 5m TTL, under 59m30s at 1h TTL | Includes a 30-second dispatch margin. |
| Resume rebuilds per 100 reviewer runs | 3.87, 2026-10-10 baseline | 0.00: 0 rebuilds / 34 reviewer runs | Current session predates this implementation. No causal after measurement. |

## ac7-6 metric

Command, with the local session's subagent directory as `SESSION_SUBAGENTS`:

```bash
python3 bin/token-cost.py reviewers --subagents "$SESSION_SUBAGENTS"
```

The 2026-10-19 sample contains 34 reviewer runs, all in the 1h TTL cohort.
It contains 13 Rex runs. No 5m TTL runs exist in this sample.
The o1 output reports 0 resume rebuilds, excluding CI-green messages, and 0.00 per 100 reviewer runs.
The baseline is 3.87, so the observed difference is -3.87 per 100 runs.
This is a different session and an owner-trial cohort. It does not prove an effect of this draft.
A prospective session after deployment must repeat this command and report each TTL cohort.
The owner user setting reads `subagentPromptCacheTtl: "1h"`. Framework settings were not edited.

## Acceptance evidence

- ac7-1: script, matching rule, spawn instructions, unchanged merge gates, and 17 tier tests.
  The tests cover all four required forge cases and copy sources.
  The tier prompt flip table remains unverified.
- ac7-4: the Rex prompt caps the hand-back and defines the short delta format.
  Seven checks exercise the unchanged production validator, including removal of each required heading.
  The short-delta flip table and actual post-change hand-back measurements remain unverified.
- ac7-6: the continuity procedure states both TTL windows and reads prior findings by posted review ID and range.
  The o1 output supplies the observed metric above.
  The resume flip table and prospective policy-effect measurement remain unverified.

## Glossary

- C4: the plan constraint that requires repeated reviewer evals with no new verdict flips.
- TTL: the time a prompt cache entry remains usable after a request.
- Hand-back: the reviewer's return message to the orchestrator after posting the full review.

## Test results

| Command | Passed | Failed |
|---|---:|---:|
| `bash .claude/hooks/tests/test_review_tier.sh` | 17 | 0 |
| `bash .claude/hooks/tests/test_short_delta_review.sh` | 7 | 0 |
| `bash .claude/skills/eval-agents/lib/validate-corpus.sh rex docs/eval-agents/corpus/rex.json` | 15 entries | 0 schema faults |
| `bash .claude/skills/eval-agents/tests/smoke.sh` | 8 | 0 |
| `bash .claude/hooks/tests/test_lean_tier_reachable.sh` | 19 | 0 |
| `bash .claude/hooks/tests/test_validate_rex_review_body.sh` | 9 | 0 |
| `bash .claude/hooks/tests/test_writing_standard.sh` | 214 | 0 |
| `bash .claude/hooks/tests/test_token_efficiency_wave1.sh` | 5 invariant groups and symlink regression | 0 |
| `bash .claude/hooks/tests/test_token_efficiency_wave2.sh` | 6 invariant groups | 0 |
| `bash .claude/hooks/tests/test_block_private_refs.sh` | 116 | 0 |
| `bash .claude/hooks/tests/test_rex_ready_label.sh` | 1 | 0 |
| `bash .claude/hooks/tests/test_subpack_extraction.sh` | 7 invariant groups | 0 |
| `bash .claude/hooks/tests/test_evidence_grounding.sh` | 34 | 0 |
| `bash .claude/hooks/tests/test_proportionate_work.sh` | 36 | 0 |
| `bash .claude/hooks/tests/test_pr_quality_narrative_rule.sh` | 24 | 0 |
| `bash .claude/hooks/tests/test_reviewer_scratch_clone_section.sh` | 6 | 0 |
| `bash .claude/hooks/tests/test_sync_cursor_adapter.sh` | 58 | 0 |
| `bash .claude/hooks/tests/test_warn_review_marker_write.sh` | 58 | 0 |
| `bash .claude/hooks/tests/test_pre_merge_qa_offer.sh` | 11 | 0 |
| `shellcheck -S warning` on the three new shell files | 3 files | 0 warnings |
| `git diff --check` | Clean | 0 faults |

Each flip table has 0/90 planned reviews and 0/45 scored pairs.
Across the three tables, 0/270 planned reviews ran. Verdict preservation remains unknown.
The isolated CLI probe failed authentication. It produced no review output to score.
