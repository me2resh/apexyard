---
id: AgDR-0220
timestamp: 2026-10-05T12:00:00Z
agent: platform-engineer
model: claude-sonnet-5-5
session: 01DKGj3WRoxN9XaezJqY22Kg
trigger: user-prompt
status: executed
category: security
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Scan for private references at push time, not at every commit

> In the context of a private ops fork whose own files name every registered project, facing a staged scan that blocks nearly every commit, I decided to scan pushed commits for private references unless the remote is confirmed private, and to skip the commit-time scan when origin is confirmed private, to keep leak protection where content leaves while removing the reason to skip git hooks, accepting that a stale visibility cache can misclassify a remote for up to 24 hours.

## Context

Issue #1528. The staged scan (AgDR-0142) blocks a commit that names a registered project. In a private single-fork ops repo the registry names projects across the repo, so the scan blocks most commits. Operators then skip git hooks on commit. That also skips the protected-branch guard in the same `.githooks/pre-commit`.

The leak risk is content leaving for a public repository. A local commit leaks nothing. A commit scan alone also misses a commit that is pushed or cherry-picked to a public repo later.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Config list of private origins that skip the scan | Offline, simple | Manual upkeep. A wrong or stale entry fails open. |
| Pre-push scan only | Scans where content leaves | The commit-time scan still blocks private-repo commits. |
| Pre-push scan plus a commit-time skip for a confirmed-private origin | Scans at the boundary. Removes the commit-time friction | Needs a visibility lookup and a cache. |

## Decision

Chosen: **pre-push scan plus a commit-time skip for a confirmed-private origin**.

1. A shared matcher (`_lib-private-refs-match.sh`) holds the matching. The staged and push scans both use it. Semantics are unchanged: registered names, slugs, workspace paths, `public: true` entries exempt, whole-content case-insensitive match.
2. `check-private-refs-push.sh`, called from `.githooks/pre-push`, scans objects, not diff lines. For each non-delete ref update it lists the new objects with `git rev-list --objects <local-sha> --not <known>` and checks every new blob and every new commit and annotated-tag object with the shared matcher. Binary and `-diff` files, merge resolutions, odd file names, and tag pushes are covered because no diff is parsed and no pathspec is built. A fixed-string prefilter (`tr` to lowercase, then `grep -F`) over `git cat-file --batch` chunks of 200 objects skips clean chunks. Only a chunk with a hit goes through the precise matcher. The registry file's own blob is exempt, as in the staged scan.
   - "Known" is (a) the remote sha the pre-push hook receives on stdin for each ref, when that commit exists locally, (b) tips this hook already scanned clean over their full reachable history for the same registry content, and (c) every commit the destination itself currently advertises via `git ls-remote --heads --tags` of the URL git pushes to (the hook's second argument), when that object also exists locally as a commit (annotated tags are peeled with `^{}` / `^{commit}`). (a) and (c) are destination-derived: those objects are already on the destination, so excluding them does not weaken the *current* push — a new-branch push (remote sha all zeros, no clean-scan record yet) no longer re-scans history the destination already holds. The shas are fed to `git rev-list --objects --stdin` as `^sha` lines, never as bulk argv, so a large ref list stays under the Linux argv limit. If ls-remote fails or times out, (c) adds nothing and the hook prints a stderr note then scans the full reachable history (fail closed). A tip is written to the clean-scan record **only** when that ref's scan used no destination-derived exclusion — i.e. the scan covered the tip's full reachable history apart from tips that are themselves already full-history-clean records. Destination exclusions stay in the scan for the current push; they must not produce a record, because a partial-history "clean" tip is not safe to reuse for another destination (Rex B-1: a leak already on a private origin, then a clean tip pushed through a mirror that already held that history, was incorrectly recorded and later allowed onto a public remote). A recorded tip therefore means "full history clean for this registry content" and is reusable across remotes. Records live in `<git-common-dir>/apexyard-leak-scanned/<hash>`, one tip per line. The hash covers the registry tokens and public flags, the name/repo pairs, the origin and upstream identity, the registry path, and a matcher version, so a registry change leaves the old file unused. Remote-tracking refs are never trusted: after `git remote set-url` or with a differing `pushurl` they describe another repository, and trusting them let a leak through. Destination refs come only from ls-remote of the push URL, never from `refs/remotes/*`.
   - Any git failure on the scan path exits 2. It is never read as "nothing to scan".
   - The scan also matches file and directory names (so `projects/<name>/` in a push blocks), the pushed local and remote ref names, and the whole text of each commit and tag object, including author, committer and tagger name and email. The diagnostic withholds a matched path. A missing prefilter, a failing `cut`, `split`, `grep` or `tr`, or an unreadable object exits 2 with "could not complete".
3. Classification (`_lib-leak-remote-visibility.sh`) fails closed. The remote is classified by the URL git pushes to (the hook's second argument, with pushurl and insteadOf applied). Only when that URL is a local path equal to the configured remote's resolved push URL does the hook use the configured pre-rewrite URL (pushurl, else url). The URL is normalised to lowercase `owner/name` with an anchored github.com host (https, http, git, ssh with optional userinfo and port, and scp style). Any other host, a bare `owner/name`, or a local path is not GitHub and means scan. A remote is skipped only when a fresh cache entry or a live `gh api repos/<slug> --jq .private` lookup says private. Public-class slugs (`leak_protection.public_framework_repos`, the `upstream` remote, a `public: true` registry entry) are never skipped. An unknown result, error, timeout, missing or unauthenticated `gh`, or non-GitHub host means scan. The cache lives in local git config as `apexyard-leak.<owner>/<name>.state = "<state> <epoch>"`. A subsection key is valid for any slug. A private or public entry lasts 24 hours. A failed lookup is cached as `unknown` for 10 minutes, so an offline or hanging lookup does not repeat on every commit. The lookup has a 5 second limit, using `timeout` or `gtimeout` when present and a bash-native watchdog otherwise. Both hooks load the registry first, so a repo with nothing to scan never calls `gh`.
4. The commit-time scan exits 0 only when origin is confirmed private by the same classification. Public, unknown, and failed-lookup origins, and the #1477 offline-proof path, still scan. The protected-branch guard runs in every case.
5. No new skip variable. Skipping hooks on push skips the scan like any git hook.

Tests stub the lookup with `APEXYARD_LEAK_VISIBILITY_CMD` (honoured only when `APEXYARD_LEAK_TEST_MODE=1`), shorten its timeout with `APEXYARD_LEAK_VISIBILITY_TIMEOUT`, force the watchdog with `APEXYARD_LEAK_FORCE_WATCHDOG`, and may stub destination ls-remote with `APEXYARD_LEAK_LS_REMOTE_CMD` (also requires `APEXYARD_LEAK_TEST_MODE=1`; or shorten it with `APEXYARD_LEAK_LS_REMOTE_TIMEOUT`). Without the test-mode flag, command overrides are ignored and the real `gh` / `git ls-remote` run. Override answers are never written to the visibility cache; cache tests plant entries directly. Timeout and trace variables only fail closed or append debug — they cannot skip the scan. None of these variables is for production use. Local bare remotes exercise real `git ls-remote <path>`.

## Consequences

- A private ops fork can commit freely and still gets a scan before content reaches a public or unknown remote.
- Each commit in a private repo with no fresh cache costs one lookup of up to 5 seconds. A failed lookup is cached as `unknown` for 10 minutes, so offline commits repeat the lookup at most once per 10 minutes and run the scan in between.
- Known limits:
  - Visibility can change after caching. A repo made public stays "private" for up to 24 hours.
  - A push through another tool, or with hooks skipped, is not scanned.
  - Setting the test-only override variables (`APEXYARD_LEAK_TEST_MODE` plus a command stub) on a push is a one-off skip equivalent to running the push with another hooks path (`git -c core.hooksPath=...`), which this framework does not block either; it no longer persists via the visibility cache.
  - A clean-scan record is local state. Someone with write access to `.git` can forge one. The hook does not defend against that.
  - The registry file is exempt by path, the same as the commit-time scan. A push of a single-fork ops repo to a public remote therefore carries the registry blob unscanned. Blocking it outright was considered and not done: the registry is committed in every single-fork repo, so an adopter whose origin is a non-GitHub or unknown host (always scanned, never confirmed private) would be blocked on every push. The split-portfolio public half has no registry file, so it is unaffected either way. Revisit with a per-remote opt-out if adopters ask.
  - A byte-identical copy of the registry under another path is listed once by `rev-list`. When the registry path is reported first, the copy is skipped too.
  - SSH host aliases, GitHub Enterprise hosts, and an unauthenticated or missing `gh` are never "confirmed private". Such adopters keep the commit-time scan and the push scan. An `ssh -G` alias resolution was not added.
  - A partial clone may lazy-fetch missing objects from the promisor remote inside the hook. If the fetch fails, the scan exits 2.
  - A very large object is scanned correctly but slowly (a 150 MB single-line blob took about 20 seconds).
  - A path with an embedded newline yields a junk line in `rev-list --objects`. The junk line is dropped, and the blob is still listed under its own id.
- Measured on this repository (802 commits, 9622 objects, 85 MB) with nothing known: one full scan takes about 6 seconds. A first push of 100 clean commits with a 10-project registry takes about 2 seconds, down from 86 seconds for the earlier diff-line design.

## Architecture evolution

### Before (Rex B-1 clean-scan records)

Clean-scan records assumed a tip scanned clean once was reusable for every
destination. The scan still excluded what the *current* destination already
held (stdin remote sha and `git ls-remote` commits). Recording that tip meant
later pushes treated its whole reachable history as clean, including private
commits that had only been excluded because another remote already had them
(Rex B-1 on the #1528 follow-up).

### After (Rex B-1)

Destination exclusions stay in the scan for the current push. A tip is
recorded only when that ref's exclusion list used none of them — full
reachable history clean apart from tips that are themselves already
full-history-clean records. Records then mean "full history clean for this
registry content" and stay safe to reuse for any destination. Reasoning:
keep the incremental-scan speed for remotes that already hold history,
without inventing a cross-remote "clean" claim the scan never proved.

### Before (M-1 test-override persistence)

`APEXYARD_LEAK_VISIBILITY_CMD` and `APEXYARD_LEAK_LS_REMOTE_CMD` were
honoured in any environment. A push with the visibility stub printing
`true` skipped the scan and wrote `apexyard-leak.<slug>.state = private`
for 24 hours, so later pushes and commits skipped without the stub. The
same class of risk applied to a malicious ls-remote stub for one push.

### After (M-1)

Command overrides require `APEXYARD_LEAK_TEST_MODE=1`. Without it they are
ignored. Override answers are never cached; cache tests plant entries
directly. Timeouts and `APEXYARD_LEAK_PUSH_TRACE` stay ungated because they
only fail closed or append debug. Reasoning: a one-off env override is
equivalent to swapping `core.hooksPath` for that push; persistence via the
local visibility cache is what turned a test knob into a lasting bypass.

## Artifacts

- `.claude/hooks/_lib-private-refs-match.sh`
- `.claude/hooks/_lib-leak-remote-visibility.sh`
- `.claude/hooks/check-private-refs-push.sh`
- `.claude/hooks/check-private-refs-staged.sh`
- `.githooks/pre-push`
- `.claude/hooks/tests/test_check_private_refs_push.sh`
- Related: AgDR-0142, AgDR-0182, AgDR-0190
