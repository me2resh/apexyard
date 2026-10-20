# Rex delta corpus — 2026-10-19

The Rex corpus grows from 10 to 15 entries before the prompt changes for #1773.
Each new entry records a real delta round. Historical verdicts are not fresh eval results.

| Entry | Previous review | Reviewed head | Historical verdict | Oracle evidence |
|---|---|---|---|---|
| rex-1765-31e0fd03-delta | 4976ccd1 | 31e0fd03 | CHANGES REQUESTED | acfbdc8a fixes the variable span inside a redirect target and adds regression cases. |
| rex-1620-6229f1c-delta | 758c811 | 6229f1c | CHANGES REQUESTED | 54d8a070 fixes the two false statements in the notes. |
| rex-1683-f85a154-delta | bee035f | f85a154 | APPROVED | The delta adds AgDR-0232 and the off-base test. The local descendants do not change that test file. |
| rex-1711-f401d65-delta | a199475 | f401d65 | APPROVED | The delta names existing commit 400db9b and corrects the notes subject. No assessment status changes. |
| rex-1769-03077369-delta | f77e546a | 03077369 | APPROVED | The delta adds committed-baseline fallback tests. Local descendants do not change the routing hook. |

The local Claude Code transcripts contain each review body and its submit command.
The git objects resolve all five ranges. The first two oracles use confirmed fixes.
The three clean entries use `no_contradiction`, with the limited local evidence above.
GitHub access failed during this build. This report does not claim a fresh forge check.
The original 10 entries remain unchanged.

Validation: `validate-corpus.sh rex docs/eval-agents/corpus/rex.json` passes with 15 entries.
Four original entries skip the defect-path check because their commits are unavailable locally.
All new defect paths pass that check. The validator smoke suite passes 8/8.
