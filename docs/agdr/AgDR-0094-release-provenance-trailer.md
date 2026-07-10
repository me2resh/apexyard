# Release provenance: record the cut SHA in the squash commit, don't infer it

> In the context of `release-changelog.sh` needing the exact dev SHA a release was cut from, facing proof (#872) that this fact is unrecoverable from the git DAG once main/dev drift, I decided to have `/release` write a `Released-From: <dev-sha>` trailer into the release squash commit (plus an interim count-mismatch warning) to achieve deterministic changelog ranges, accepting that pre-trailer releases still rely on the old heuristic.

## Context

The v5.0.0 release notes were nearly generated from 5 commits instead of 329 (#872): `release-changelog.sh`'s `#737` sync-boundary heuristic anchors on the *most recent* `sync: merge main into dev` commit, and a `/release-sync` PR that merges **late** lands near dev's tip — silently discarding everything merged before it.

The #872 investigation (validated against real history, not the synthetic test repo) established why no read-time fix works:

- The naive ancestor fix (`PREV_TAG..dev` when the tag is an ancestor) returns **334 commits including two months of released work** — a squash commit never has dev's individual commits as ancestors, so post-sync the range re-expands to everything since the tag. That silently re-creates the `#737` over-count (v4.1.0: 102 feats reported for a ~1-feature delta).
- A tree-identity heuristic (find the dev commit whose tree equals `PREV_TAG^{tree}`) worked for v4.4.0 but **fails for v5.0.0** — main and dev have persistent, legitimate content divergence (CHANGELOG carry-forward, `site/` removed on dev), so no dev commit matches the tag's tree.
- The needed fact — *dev's exact tip at release-cut time* — therefore cannot be reliably reconstructed topologically. It must be **recorded when it is known**, i.e. at cut time by `/release`.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. `Released-From: <dev-sha>` trailer in the release squash commit message** (via the release PR body → squash commit) | Deterministic; travels with the commit forever (`git log` readable); survives squash by construction; no new files; standard git-trailer convention (`git interpret-trailers`); helper falls back to old heuristic for pre-trailer releases | `/release` + the merge flow must ensure the trailer survives into the squash message; one-time helper change to prefer the trailer |
| B. Record the cut SHA in the release PR body only | Trivial to write | Requires GitHub API at changelog time (offline/detached use breaks); PR bodies are editable after the fact — weaker provenance than an immutable commit message |
| C. Record the cut SHA in a committed file (e.g. `.release-provenance`) | Plain-file simple | Churn commit every release; the file on dev goes stale between releases; merge/sync noise for zero benefit over a trailer |
| D. Keep the heuristic; add a loud count-mismatch warning in `/release` | Zero design change; mechanises exactly the manual catch that saved v5.0.0 | Not a fix — the human is still the oracle; silent under-count returns the day the warning is ignored |

## Decision

Chosen: **A + D together** — A is the durable fix, D is the immediate guard and the permanent backstop.

1. `/release` records the dev SHA it cuts from as a `Released-From: <sha>` git trailer, carried into the release squash commit message (the release PR body already becomes the squash message under GitHub squash-merge; keep the trailer in its final line block so `git interpret-trailers` parses it).
2. `release-changelog.sh` resolves its range as: **trailer if present** (`Released-From..HEAD_REF`) → else the existing `#737` sync-boundary heuristic → else merge-base/tag fallback. Old releases without the trailer keep working exactly as today.
3. `/release` additionally prints the `main..dev` commit count next to the generated changelog's entry count and **warns loudly on a large mismatch** — cheap, immediate, and it stays even after the trailer exists (defence in depth; also guards option A against a mangled trailer).

## Consequences

- The next release cut after implementation carries provenance; every release after that gets a deterministic changelog range, immune to late syncs and branch drift.
- The `#737` heuristic is demoted from load-bearing to fallback — its known failure modes only apply to pre-trailer history.
- `test_release_changelog.sh` gains trailer-present, trailer-absent-fallback, and count-mismatch-warning cases; its synthetic repos should model main/dev divergence (the current linear model cannot distinguish the failure modes — a finding from #872).
- Implementation touches `/release` (skill), `bin/release-changelog.sh`, and the auto-tag workflow's assumption set — a normal `[Task]`-sized change, tracked on #872.

## Artifacts

- Issue: me2resh/apexyard#872 (incident, investigation, and the irreconcilability proof)
- Incident: v5.0.0 changelog under-count, caught manually 2026-07-10
- Prior art: `#737` (the over-count this design must not re-introduce), AgDR-0076 (release automation), AgDR-0052/0053 (release-sync)
