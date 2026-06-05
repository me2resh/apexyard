# Review Marker Repo Qualifier — Scoping Markers to (repo, pr) Pairs

> In the context of a multi-repo portfolio where `.claude/session/reviews/` holds approval markers keyed by bare PR number, facing a collision hazard when two different managed repos share the same PR number, I decided to encode the repo as a double-underscore-separated owner/repo prefix in the marker filename to achieve unambiguous (repo, pr) scoping, accepting a one-time re-approval cost for any markers that existed before the upgrade.

## Context

Review markers (`<pr>-rex.approved`, `<pr>-ceo.approved`, `<pr>-design.approved`, `<pr>-architecture.approved`) are written to `.claude/session/reviews/` and are consumed by four gate hooks: `block-unreviewed-merge.sh`, `require-design-review-for-ui.sh`, `require-architecture-review.sh`, and `warn-stale-review-markers.sh`. The markers are also written by the `/approve-merge`, `/approve-design`, `/approve-architecture`, and `/design-review` skills, plus the `code-reviewer` (Rex) and `solution-architect` (Tariq) agents.

Because PR numbers are per-repository and routinely overlap across repos (every new repo starts from #1), two distinct managed repos can each have a PR #429. The bare-number scheme means `429-rex.approved` is indistinguishable at read-time regardless of which repo's PR produced it. Observed in practice: a leftover CEO marker from repo A's PR #429 sitting in `reviews/` appeared as if it belonged to repo B's freshly-opened PR #429 in a later session. The SHA-match check in the merge gate prevents a *wrong merge* from occurring (the stale marker's SHA will not match the new PR's GitHub HEAD), but the correctness/hygiene defect is real:

- `warn-stale-review-markers.sh` cannot reason about which repo a marker belongs to.
- A same-session same-PR-number scenario (two concurrent merge operations on different repos) results in one marker overwriting the other's filename with no signal to either gate.
- Stale cross-repo markers are confusing to operators and to gate diagnostics.

The fix must encode the repo in every marker filename, consistently, with a single source of truth for path construction that all readers and writers share.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **`<owner>__<repo>__<pr>-<role>.approved` (flat file, double-underscore separator)** | Flat `reviews/` directory; simple glob scan; `__` is filesystem-safe and visually distinct; sanitise `/` → `__` in owner/repo; zero ambiguity on the (repo, pr) pair | Filenames grow longer; some find/glob patterns need updating |
| `<owner>-<repo>-<pr>-<role>.approved` (single-hyphen separator) | Shorter filenames | `owner` or `repo` slugs can themselves contain hyphens (e.g. `my-org/my-repo`) making it impossible to reliably parse back the components |
| `<owner>/<repo>/<pr>-<role>.approved` (subdirectory per repo) | Matches GitHub's URL shape; OS-friendly tree view | Requires `mkdir -p` for each new owner/repo; glob patterns become `*/*/<pr>-*.approved`; `warn-stale-review-markers.sh` must recurse; slightly more complex |
| Leave naming alone; rely solely on SHA mismatch as safety backstop | Zero migration cost | Does not remove the misleading-stale-marker or same-session-overwrite hazard; `warn-stale-review-markers.sh` remains unable to reason about repo; defect is explicitly called out in the bug report as major |

## Decision

Chosen: **`<owner>__<repo>__<pr>-<role>.approved` flat-file scheme**, because:

1. The double-underscore separator is unambiguous — GitHub owner and repo slugs use only `[a-zA-Z0-9._-]`, which never includes `__`. Splitting on `__` reliably recovers the three components.
2. The flat `reviews/` directory stays flat — no subdirectory creation required, existing glob logic (`"$REVIEWS_DIR"/"$PR_NUMBER"-*.approved`) becomes `"$REVIEWS_DIR"/"$OWNER_REPO"__"$PR_NUMBER"-*.approved`; `warn-stale-review-markers.sh` still iterates with a simple for-loop.
3. A single shared lib (`_lib-review-markers.sh`) owns path construction; all four gate hooks and all six writers (four skills + two agents) source it. One change point for any future scheme evolution.

Implementation: the `review_marker_path <owner/repo> <pr> <role>` function in `_lib-review-markers.sh` sanitises the repo string (`/` → `__`) and returns the absolute path anchored at the resolved `MARKER_HOME/.claude/session/reviews/` directory.

## Backward Compatibility

**New scheme only — no dual-read fallback.** Markers are session state, gitignored, and ephemeral. The SHA-match check in the gate hooks is the safety backstop that ensures a stale or unrelated marker cannot produce a wrong merge. The only cost of the hard-cutover is that any marker written under the old bare-number scheme must be re-approved (one re-invocation of the relevant skill or agent). This cost is per-session (markers don't persist across sessions in any meaningful way) and far cheaper than maintaining a dual-read path indefinitely.

A dual-read fallback was considered: read new-scheme first, fall back to bare-number on miss. Rejected because:

- It would silently perpetuate the collision hazard for old markers already in `reviews/`.
- The SHA backstop means a stale old marker can't produce a wrong merge anyway, so the fallback buys convenience at the cost of false reassurance.
- The cleanup message (`/approve-merge <pr>` or re-invoke Rex) is one turn of work, not a breaking experience.

The upgrade path: any adopter who had markers in `reviews/` before the upgrade simply re-approves. The gate hooks report the exact missing file path in their BLOCKED messages, so the operator knows exactly what to re-run.

## Consequences

- All four gate hooks (`block-unreviewed-merge.sh`, `require-design-review-for-ui.sh`, `require-architecture-review.sh`, `warn-stale-review-markers.sh`) updated to source `_lib-review-markers.sh` and use `review_marker_path`.
- All six writers updated: `/approve-merge`, `/approve-design`, `/approve-architecture`, `/design-review` skills; `code-reviewer` and `solution-architect` agents.
- Tests updated to write markers at the new qualified paths. New regression test proves two repos sharing the same PR number get distinct, non-colliding markers.
- `_lib-review-markers.sh` is a `_lib-*` file and is excluded from the hook count in `test_site_counts.sh` — no count drift.
- `_lib-extract-pr.sh` gains a sibling `extract_repo_from_command` function (non-breaking addition; existing `extract_pr_number` contract unchanged).

## Artifacts

- PR: `atlas-apex:fix/GH-485-review-marker-repo-qualifier` → `me2resh/apexyard` `dev`
- Closes me2resh/apexyard#485
