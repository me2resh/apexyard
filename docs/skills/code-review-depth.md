# Review depth and reviewer continuity

## Trusted tier check

Before each Rex spawn or resume, resolve the PR base SHA and current head SHA from the forge.
Fetch both commits before the reviewer mutation lock starts.
Export `bin/review-tier.sh` from that base SHA into a temporary file.
For an ops fork, use the trusted ops baseline at its recorded SHA instead.
Never execute the PR's copy of the script.

Run the exported script with the repository path, base SHA, reviewed SHA, and fetched head ref.
You may run it from any working directory. The script changes to a temporary directory and starts Python with `-I`, so a planted module in the PR tree cannot run.
Prefer an absolute `$repo_dir`. A relative path is resolved against the caller's working directory before the script leaves that directory.

```bash
bash "$trusted_script" "$repo_dir" "$base_sha" "$reviewed_sha" "$head_ref"
```

Check every command's exit status. Missing base scripts, export errors, and malformed output mean Full.
Read the script's complete JSON output. Do not pass a file list from the forge.
The script reads the full `base..reviewed` range, with both sides of renames and copies.
It checks an independent list for missing records. Empty lists and all errors mean Full.
It permits only regular `.md`, `.png`, `.jpg`, `.jpeg`, `.gif`, and `.webp` files below `docs/`.
AgDR files, ORBIT records, and paths named by prompt files always mean Full.
JSON, YAML, scripts, lock files, and all other paths always mean Full.
The allowlist accepts only letters, digits, underscores, hyphens, and directory separators before the extension.

Pass the base SHA, reviewed SHA, result, and complete path list to Rex.
`Reduced-scope-allowed` permits the existing Reduced-Scope pass only.
Rex still checks all five eligibility conditions, both rails, and content.
Use the stricter result. A Full result cannot become Reduced-scope.
Re-query the forge head immediately before dispatch and before accepting a review.
A changed head invalidates the result. Fetch and repeat the check for the new head.
The script also checks the fetched head ref before and after classification.
No tier result replaces a review or approval marker.

## Reviewer hand-back

Return at most 300 tokens to the orchestrator after posting the complete review.
Include verdict, reviewed SHA, review ID, blocker count, marker result, and next action.
Keep detailed findings and validation evidence in the posted review.
The cap applies to the return message, not the posted review or required checks.

## Resume window

A fresh Rex first turn costs 26,813 input tokens in the 2026-10-11 trim report.
The earlier 80k threshold used a 49,107-token spawn. It no longer fits that measurement.
For an expired cache, a retained context above 26,813 tokens costs more to rebuild than the fresh first turn.
At the same cache-write rate, the comparison is `rate × retained` versus `rate × 26,813`.
This compares startup only. Retrieval and later review work add costs to both paths.

Use the last model-request timestamp and measured context, not a caller's recollection.
Resume when the cache is warm, or when the context is at most 26,813 tokens.
Use these conservative warm windows, with 30 seconds reserved for dispatch:

| Effective subagent TTL | Resume while idle time is below | After that window |
|---|---|---|
| Framework default: 5 minutes | 4 minutes 30 seconds | Fresh Rex above 26,813 tokens |
| Owner trial: 1 hour | 59 minutes 30 seconds | Fresh Rex above 26,813 tokens |

Unknown TTL uses the 5-minute case. Unknown age or context uses a fresh Rex.
The owner trial sets `subagentPromptCacheTtl` to `"1h"` in user settings.
The framework ships no TTL change. Confirm the effective request TTL in transcript usage.
The owner's user setting was read as `1h` on 2026-10-19. Its provider effect was not re-tested here.

A fresh Rex receives the prior posted review ID, prior reviewed SHA, and current reviewed SHA.
It fetches that review body from the tracker and reads every earlier finding directly.
It compares the recorded commit range with the supplied range before reviewing the delta.
An orchestrator summary is not evidence of earlier findings.
If the posted review or range cannot be verified, run a Full review of the current PR.
Use the existing Opus reviewer. This procedure introduces no lower-effort agent.

## Scratch tests and CI restrictions

Use a plain `git clone` into a literal scratch path for tests against the PR head.
Alternatively, export with `git archive <ref> | tar -x -C <scratchpad>` into the session scratchpad.
A sanctioned review needs no ticket for that write. The agent file states the complete path rule.
If a hook blocks a command, stop that step. Report the exact command, hook, and message to the orchestrator.
Never rephrase, split, encode, or disguise a command to bypass a hook.
Prepare the scratch clone and fetch the head before the active-reviewer marker starts the mutation lock.

The orchestrator waits for green CI with a Monitor, then spawns Rex.
Rex checks CI once and never waits.
`block-reviewer-ci-wait.sh` blocks `gh pr checks --watch`, `gh run watch`, and sleeps of 60 seconds or more.
