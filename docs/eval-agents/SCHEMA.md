# Corpus schema — `docs/eval-agents/corpus/<agent>.json`

One file per agent (`rex.json`, `hakim.json`, `tariq.json`, …). Each file is a single JSON object:

```json
{
  "agent": "rex",
  "schema_version": 1,
  "entries": [ /* array of entries — see below */ ]
}
```

| Field | Type | Notes |
|---|---|---|
| `agent` | string | Must match the filename stem (`rex.json` → `"agent": "rex"`). One of `rex`, `hakim`, `tariq` in v1. |
| `schema_version` | integer | `1`. `/eval-agents` refuses to run against a corpus with an unrecognised version rather than silently misinterpreting it. |
| `entries` | array | The labeled corpus. Order doesn't matter. |

## Entry shape

```json
{
  "id": "rex-792-2ce6708",
  "pr": 792,
  "repo": "me2resh/apexyard",
  "commit": "2ce6708",
  "diff_range": "2ce6708~1..2ce6708",
  "oracle": {
    "source": "independent_review",
    "established_by": "Hakim's independent review of the identical commit (PR #792) caught this defect the same day; the fix landed in the next review round.",
    "reference": "me2resh/apexyard#792"
  },
  "ground_truth_defects": [
    {
      "id": "D1",
      "description": "Prefix-strip loop consumes the real create verb, so genuine PR-create invocations silently skip validation (a shape-4 gate-bypass).",
      "severity": "BLOCKING",
      "location": ".claude/hooks/validate-pr-create.sh"
    }
  ],
  "recorded_verdict": {
    "verdict": "APPROVED",
    "was_justified": false
  },
  "notes": "Canonical false-confidence case from spike #825 (row R1): a fluent, verification-heavy APPROVED review of a commit that carried a real BLOCKING defect Hakim caught on the identical commit."
}
```

| Field | Type | Notes |
|---|---|---|
| `id` | string | Unique within the file. Convention: `<agent>-<pr>-<commit-short>`. |
| `pr` | integer | The PR number this entry traces to. Used for traceability and report citations — **never** passed to the agent-under-test (see "Why the PR number never reaches the agent" below). |
| `repo` | string | `owner/repo`. Passed to `git`/`gh` for diff resolution only. |
| `commit` | string | The commit SHA whose diff is being re-reviewed (short or full form; the skill resolves either). This is the specific review round the ground truth applies to — a PR usually has several. |
| `diff_range` | string | A `git diff`-compatible range (`<sha>~1..<sha>`) used as the primary local-resolution attempt. If the commit isn't reachable in local history (common after a squash-merge), the skill falls back to `gh api repos/<repo>/commits/<sha>` (works regardless of local reachability, since it queries GitHub directly). |
| `oracle.source` | enum | `independent_review` \| `confirmed_fix` \| `no_contradiction` \| `human`. How this entry's ground truth was established. **Never** the agent being measured — see AgDR-0089. |
| `oracle.established_by` | string | One sentence: what evidence backs this ground truth. |
| `oracle.reference` | string | Optional — a PR/issue reference for the evidence. |
| `ground_truth_defects` | array | Zero or more. Empty array = a genuinely clean diff (a correct approval should score against nothing). |
| `ground_truth_defects[].id` | string | Unique within the entry (`D1`, `D2`, …). |
| `ground_truth_defects[].description` | string | What the defect actually is — specific enough that a scorer can tell whether the agent-under-test's findings describe the same thing. |
| `ground_truth_defects[].severity` | enum | `BLOCKING` \| `HIGH` \| `MEDIUM` \| `LOW` \| `NIT`. Drives the BLOCKING/HIGH-only catch-rate cut and the automatic-WARN rule. |
| `ground_truth_defects[].location` | string | File path (± line) the defect lives in. Used for the diff-engagement mechanical check. |
| `recorded_verdict.verdict` | enum | `APPROVED` \| `CHANGES REQUESTED` \| `COMMENT`. What the real reviewer actually said, historically — **not** what the agent-under-test says on this run (that's computed fresh each run). |
| `recorded_verdict.was_justified` | boolean | Ground truth: given `ground_truth_defects`, was that verdict the right call? `false` for `APPROVED` entries that shipped with an undiscovered BLOCKING/HIGH defect. |
| `notes` | string | Optional free text — context for a human reading the corpus. |

## Why the PR number never reaches the agent-under-test

`/eval-agents` strips `pr`, `repo`, `Closes #N` / `Fixes #N` trailers, and any URL from the diff text before handing it to the agent-under-test, and instructs it explicitly not to call `gh`/tracker commands or write approval markers. The real review agents (Rex, Hakim, Tariq) are hard-wired to post a live GitHub comment and write a real approval marker on a live PR number — an eval run must never trigger that against an already-merged historical PR. See AgDR-0089 § Decision point 6 for the full rationale and the residual-risk note (this is a mitigation, not a hard sandbox; the skill's contamination check is the backstop).

## Validating a corpus file

```
/eval-agents rex --check-only
```

Runs schema validation only (`.claude/skills/eval-agents/lib/validate-corpus.sh`) — no agent spawns, no diff resolution. Confirms `schema_version`, required fields, and enum values before you spend a real run on it.
