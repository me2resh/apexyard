# `/approve-merge` must pass `--subject`/`--body-file` on a release-class squash

> In the context of `/approve-merge` (the mandated human-only merge path,
> #1042) merging a release PR against this repo's
> `squash_merge_commit_message=COMMIT_MESSAGES` setting, facing a bare
> `tracker_pr_merge ... squash` that burns the `Released-From` trailer mid-way
> through a ~445 KB concatenated commit-message body, I decided to
> auto-detect release-class PRs the same way `/approve-merge` already
> auto-detects sync-class PRs and pass an explicit `--subject`/`--body-file`
> for that one merge, accepting the trade-off that `tracker_pr_merge` and
> `/approve-merge` now special-case a second PR class.

## Context

`/release` Rule 11 already requires the release PR to be merged with an
explicit `--subject`/`--body-file` — never a bare `gh pr merge --squash` —
specifically because this repo's `squash_merge_commit_message` setting is
`COMMIT_MESSAGES`. GitHub assembles a squash commit's default body from every
commit message on the PR branch. A release PR's head branch
(`release/vA.B.C`) is cut from `dev`, so from `main`'s perspective it
"contains" the entire dev↔main divergence — currently ~463 commits, ~445 KB
of concatenated messages. The one commit on that branch (`chore: release
vA.B.C`) does carry a `Released-From: <sha>` trailer, but a git trailer is
only recognised in the message's **final paragraph**
(`git interpret-trailers`, and the `%(trailers:...)` pretty-format
`bin/release-changelog.sh` reads back — AgDR-0094). Buried mid-body, the
trailer is invisible to both.

`/approve-merge` became the **mandated** merge path for every PR, release
PRs included, when #1042 locked `disable-model-invocation: true` onto the
approval skills. Before #1042 an operator could still merge a release PR by
hand with the exact command Rule 11 prescribes; after #1042, `/approve-merge`
IS the merge, and it called `tracker_pr_merge "<repo>" "<pr>" "squash" true`
— a bare squash, no `--subject`, no `--body-file`. `/release` Rule 11 and
`/approve-merge` were making contradictory promises about the same merge
call, and the conflict fires on every release cut. It happened live on
v5.4.0 (PR #1134, squash commit `d8a50ff`): the release shipped correctly
(right tag, right CHANGELOG), but the trailer landed mid-body and
`git log -1 --pretty=format:'%(trailers:key=Released-From,valueonly)'`
returned empty.

`/approve-merge` already solves an structurally identical problem for
`sync/`-prefixed PRs (AgDR-0053): step 6 detects the PR's head branch/title
and forces `strategy=merge` instead of the default squash. The release-PR
fix is the same shape — detect, then pass different arguments to the same
`tracker_pr_merge` call — not a new mechanism.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. Auto-detect release-class PRs in `/approve-merge`, pass `--subject`/`--body-file` automatically (mirrors AgDR-0053's sync-PR detection)** | Correct by default; no new operator-facing flag; reuses the exact `--subject`/`--body-file` shape Rule 11 already prescribes for the manual path | A second special case added to a previously general-purpose skill and to `tracker_pr_merge`'s signature |
| **B. Flip the repo's `squash_merge_commit_message` setting to `PR_BODY`** | No special-casing anywhere | Repo-wide default change affecting the squash body of every PR merged to this repo, not just releases — the least-targeted option; explicitly rejected by `/release` Rule 11 already |
| **C. Have `/release` auto-merge once its own body/subject are prepared** | Removes the gap between "Rule 11 prescribes X" and "the actual merge call does Y" entirely | Breaks the discrete per-PR CEO approval moment (`pr-workflow.md` § "Plan-level 'go' is NOT merge approval") — `/release` explicitly does **not** auto-merge, by design |
| **D. Amend the squash commit's message post-merge** | No merge-time change needed | Impossible in practice — the commit is immediately tagged by CI and lands on protected `main`; rewriting it would orphan the tag and violate branch protection |

Options B, C, and D are the same three the issue itself records as considered
and rejected; A is the one this AgDR adopts.

## Decision

Chosen: **Option A**. `tracker_pr_merge` (`_lib-tracker.sh`) gains two
OPTIONAL trailing parameters, `<subject>` and `<body_file>` — empty by
default, so every existing call site (every non-release merge) is
byte-for-byte unchanged. `/approve-merge` step 6 gains a release-class
detection block, structurally identical to the existing sync-class block,
and keeps that detection, title/body-file creation, and `tracker_pr_merge`
invocation in one fenced shell block (#1196). A fenced block is the unit of
shell execution; values must not cross from one documented block to another.
The release-class check uses a head branch that matches
`release/v[0-9]+\.[0-9]+\.[0-9]+`, or a title that starts with `release(`.
When matched, it reads the PR's own title (as `--subject`) and body (written
to a temp file, as `--body-file`) via `gh pr view`, and passes both through to
`tracker_pr_merge`.

**Fail-safe, not fallback.** If the PR body can't be read (`gh pr view`
fails, or the body is empty), `/approve-merge` STOPS before merging rather
than silently falling back to a bare squash — a silent fallback here would
reproduce #1136. `tracker_pr_merge` is a narrower second layer: if a
non-empty `body_file` is unreadable or empty, it returns 1 without attempting
the merge. It cannot distinguish an intentionally omitted body file from a
lost empty shell variable, so it cannot backstop a cross-code-block scope
failure. The one-block instruction is the prevention for that failure mode.

**Scope: `gh` kind only.** The subject/body_file parameters are only wired
into `_tracker_merge_gh`. `/release` — and therefore this bug — only ever
targets the `gh`-hosted `me2resh/apexyard` framework fork; there is no glab
or custom-adapter release flow to fix. `_tracker_merge_glab` and
`_tracker_merge_custom` silently ignore the extra parameters if a future
caller ever passes them for a non-gh project, which is the safe default
(same behaviour as today) rather than a new failure mode.

## Consequences

- Merging a `release/vA.B.C` PR via `/approve-merge` now produces a squash
  commit whose final paragraph is the `Released-From` trailer, matching what
  `/release` Rule 11 has always promised.
- The release subject and body-file variables are created and consumed in the
  same documented shell block, so a harness that executes fenced blocks in
  separate shells cannot silently omit the body file.
- `/release` Rule 11 and `/approve-merge` step 6 now cross-reference each
  other directly, so a future reader of either skill sees the other half of
  the picture instead of two independently-plausible, silently-conflicting
  instructions.
- `tracker_pr_merge`'s signature grows by two optional trailing parameters.
  Every existing caller (the sync-PR path, every ordinary PR merge, every
  test in `test_tracker_pr_merge.sh`) is unaffected — the new parameters
  default to empty strings, which is byte-for-byte today's behaviour.
- The `tracker_pr_merge <owner/repo> <pr> ...` bare-statement invocation
  shape the four merge-gate hooks match on (`Bash(tracker_pr_merge *)`,
  #759) is unchanged — only trailing arguments were added, not the command
  name or its bare-top-level-statement requirement.

## Artifacts

- `.claude/hooks/_lib-tracker.sh` — `_tracker_merge_gh`, `tracker_pr_merge`
- `.claude/hooks/tests/test_tracker_pr_merge.sh` — release-PR body-file
  coverage
- `.claude/skills/approve-merge/SKILL.md` — one-block release-class
  detection and merge wiring
- `.claude/skills/approve-merge/tests/test_merge_invocation_not_substituted.sh`
  — release metadata and merge-invocation co-location coverage
- `.claude/skills/release/SKILL.md` — Rule 11 cross-reference
- Issue: me2resh/apexyard#1136
- Sibling decision: `AgDR-0053` (the `sync/`-class precedent this mirrors)
