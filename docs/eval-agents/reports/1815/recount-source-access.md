# Rex recount check with read-only source access — #1815

Status: **Phase A run, 2026-10-20. Phase B not run. With read-only source access and prompt `a7b3`, Rex catches rex-1620 D1 in 1 of 3 runs. AC2 stays open on #1815.**

This change ships the source-snapshot option only. It does not change the Rex prompt.
Phase A used 1,904,884 tokens for 3 runs. That is about 3.8 times the budget of about 0.5 M tokens. Thus phase B (the draft prompt `bb87`, k=3) did not start.
The CEO decided to ship the tooling without the untested prompt edit (CEO decision, 2026-10-20).

## Prompt hashes

SHA-256, first 12 hex characters, of the full `.claude/agents/code-reviewer.md` file:

- `a7b38bd17fe3`: the #1798 prompt, current on `dev` at `7f82bd5e`. Phase A used it. This change keeps it.
- `bb87ea3ca150`: a draft, not shipped. It makes Rex run the count command, quote the command and its output, and count by the record's own definition. The draft text is kept in the private eval folder, not in this repository. No eval run used it.

## Protocol

The protocol is the #1798 targeted protocol with the read-only source option added. See [`../../README.md`](../../README.md) § "Read-only source access (option)".

- Entry: `rex-1620-6229f1c-delta`. It is the only entry that used read-only source access.
- Head commit: `6229f1c2`. Delta range: `758c8115..6229f1c2`.
- Reviewer: Opus CLI (`--model opus`, which ran `claude-opus-5-5`), with the full prompt file as the system prompt.
- Tools: Read, Grep and Glob only, with `--permission-mode dontAsk`. There was no shell, no web tool and no MCP server.
- Source: for each run, a new snapshot of the files at `6229f1c2` in `./src`, built by `source-snapshot.sh`. The deny list had 46 names. The script redacted 39 files and found no name left.
- Memory: `claudeMdExcludes` stopped the CLAUDE.md and rule files of the snapshot from loading.
- Input: the sanitized earlier review (round 1 at `758c8115`), the sanitized delta diff, the delta range and the head SHA. The input also states that CI is green. The no-tools sentence was replaced with the source-access sentence.
- Sandbox probe (Haiku, 2 runs): a Read, a Glob and a Grep of the live repository were all refused. A Read inside `./src` worked.
- Scoring: a defect counts as caught only when a finding names it as blocking. A hint, a suggestion or an "Unverified" note counts as missed. The scores come from reading each review.

## Eval results

A is APPROVED, C is COMMENT and CR is CHANGES REQUESTED.

| Run | Prompt | Source access | Verdict | D1 (24 walk-ups claimed, 18 in source) | D2 (Bedrock setting set) | Tokens |
|---|---|---|---|---|---|---|
| k1 | `a7b3` | Yes | CR | Missed. It accepts "24 for the walk-up" as resolved | Missed. No Bedrock finding | 368,369 |
| k2 | `a7b3` | Yes | C | Missed. It counts the `.apexyard-fork` string in 24 skills and accepts the count | Missed. It lists the CLI setting facts as Unverified | 772,745 |
| k3 | `a7b3` | Yes | CR | **Caught.** Issue 6, blocking kind 3: 24 skills name the string, 18 carry the `[ -f "$r/.apexyard-fork" ]` test. It names the 6 other files | Missed. No Bedrock finding | 763,770 |
| Phase B | `bb87` | Yes | Not run | Not run | Not run | 0 |

Summary against the #1798 no-tools runs with the same prompt:

| Defect | `a7b3`, no tools (#1798, k=3) | `a7b3`, read-only source (k=3) |
|---|---|---|
| D1 | 0 of 3 | 1 of 3 |
| D2 | 1 of 3 | 0 of 3 |

### Reading the results

- D1: each run reports a search of `./src`.
  - k1 does not recount the walk-ups. It checks only that the records agree on 24.
  - k2 counts the anchor string `.apexyard-fork` (24) and stops there.
  - k3 also counts the walk-up test (18) and reads the 6 other files.
  - Thus the k2 miss is a wrong signature, and the k1 miss is a skipped count. The `bb87` draft targets both misses.
- D2: the snapshot cannot prove D2. The related setting `ENABLE_PROMPT_CACHING_1H` and the rule that an explicit `promptCacheTtl` takes precedence are not in the repository at `6229f1c2`. Only the notes under review name a Bedrock flag. A D2 catch needs product knowledge, not source access. The change from 1 of 3 to 0 of 3 is within run-to-run noise at k=3.
- Verdicts: k1 and k3 block on a second finding, a missing condition in the ac4-3 fail-open sentence. k2 gives the same point as a suggestion. That finding is not in the frozen key. The 1798 report does not record it for the no-tools runs.
- Cost: cache reads are 1,741,018 of the 1,904,884 tokens. Each tool turn reads the full context again. The runs had 16, 28 and 20 turns. A source-access run costs 9 to 19 times a no-tools run (about 40k).

## Acceptance criteria — #1815

| Criterion | Result | Evidence |
|---|---|---|
| AC1: the protocol describes the read-only source option, and the report states which entries used it | Met | `docs/eval-agents/README.md` § "Read-only source access (option)", the SKILL.md Step 3d note, and the entry list in the README and in this report |
| AC2: with read-only source access at k=3, Rex names rex-1620 D1 in at least 2 of 3 runs | Not met. Open on #1815 | `a7b3`: 1 of 3. The `bb87` draft is not shipped and not run |
| AC3: the Rex prompt stays under the caps that `test_token_efficiency_wave1.sh` checks | Met | The prompt is unchanged (`a7b3`), and the test passes. The `/code-review` skill body is 15,736 of 16,000 bytes |

## Planning note for the next attempt

- Real cost: 3 source-access runs used 1,904,884 tokens, 368k to 773k each.
- A source-access run costs 9 to 19 times a no-tools run (about 40k).
- Most of the cost is cache reads: each tool turn reads the full context again.
- Phase B with the `bb87` draft needs 3 more runs, about 1.9 M tokens. Ask the CEO before this spend.
- To cut the cost, give Rex only Grep and Glob, or a smaller snapshot. That is a new condition, so record it separately.

## Condition difference for future runs

The 3 phase A runs loaded the user-level settings and the installed plugins of the operator. Later runs limit them with `--setting-sources project` and an empty `--plugin-dir`, as the README shows. The context of a later run can differ from phase A for this reason. Record it as a condition difference, and do not mix the counts.

## Cost totals

Tokens are input, cache creation, cache read and output tokens from the CLI JSON usage blocks.

| Part | Runs | Tokens |
|---|---|---|
| Phase A, Opus, `a7b3` with source access | 3 | 1,904,884 |
| Sandbox probes, Haiku | 2 | 108,989 |
| Phase B, Opus, `bb87` | 0 | 0 |
| **Total for #1815** | **5** | **2,013,873** |

The CLI reported a cost of USD 2.19 for the 3 Opus runs.

## Glossary

| Term | Definition |
|---|---|
| Frozen defect | A real defect fixed in a corpus entry's ground truth, set once by a human |
| Sanitized source snapshot | A copy of the files at the reviewed commit, with names that identify a private project removed |
| Signature | The text pattern that a count command matches |
| Phase A, phase B | Phase A runs the current prompt with source access. Phase B runs the edited prompt with source access |
