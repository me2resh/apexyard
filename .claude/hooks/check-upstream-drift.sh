#!/bin/bash
# SessionStart hook: shows a one-line banner when a new tagged release
# exists on upstream me2resh/apexyard that the fork doesn't yet have.
#
# Tag-based drift (new in v1.1.0): small main commits (README typos, CI
# tweaks, docs-only PRs) do NOT fire the banner. Only a new upstream tag
# does. This keeps the signal actionable and avoids training fork owners
# to tune out the banner over time.
#
# Fallback: if upstream has NEVER been tagged (brand-new project, pre-
# release), or the fork has never merged any upstream tag, fall back to
# commit-count drift so newly-forked users still get useful guidance.
#
# Silent exit paths (no output, no error):
#   - Not a git repo
#   - No `upstream` remote configured (this is the upstream repo itself,
#     or the fork hasn't set up `upstream` yet — /setup reminds them)
#   - Fetch fails (offline, git hosting down, permission)
#   - Fork is up-to-date on the latest upstream tag
#   - No upstream tags AND no commit drift
#
# Banner emits only when there's something actionable: a new upstream tag
# the fork hasn't merged, OR (in fallback mode) commits behind main.
#
# Fetch caching: the hook hits the network at most once per 10 minutes per
# clone. A tight-loop of sessions (IDE restarts, `claude --resume`) doesn't
# hammer origin. Cache lives at .claude/session/last-upstream-fetch — session
# state, already gitignored.
#
# Runtime: < 200ms on cache hit, 1-3s on cache miss (depends on fetch latency).

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

cd "$REPO_ROOT" || exit 0

# Bail if no upstream remote — either this IS the upstream repo, or the fork
# owner hasn't run `git remote add upstream …` yet. Either case: silent.
if ! git remote | grep -qx upstream; then
  exit 0
fi

# Default branch (usually `main`, sometimes `master`). Resolve from origin's HEAD.
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD --short 2>/dev/null | sed 's|origin/||')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}

# Fetch cache: skip the network call if we fetched within the last 10 minutes.
CACHE_DIR="${REPO_ROOT}/.claude/session"
CACHE_FILE="${CACHE_DIR}/last-upstream-fetch"
TTL_SECONDS=600
NOW=$(date +%s)

SHOULD_FETCH=1
if [ -f "$CACHE_FILE" ]; then
  LAST=$(cat "$CACHE_FILE" 2>/dev/null)
  if [ -n "$LAST" ] && [ "$((NOW - LAST))" -lt "$TTL_SECONDS" ]; then
    SHOULD_FETCH=0
  fi
fi

if [ "$SHOULD_FETCH" = "1" ]; then
  # Quiet fetch with a short timeout. On failure (no network, no auth), exit
  # silently — we don't want a startup banner yelling about offline state.
  # `--tags --prune-tags` pulls tag refs and removes local copies of any tag
  # upstream has retracted (rare, but keeps the local tag view honest).
  if ! timeout 5 git fetch upstream --tags --prune-tags --quiet 2>/dev/null; then
    exit 0
  fi
  mkdir -p "$CACHE_DIR"
  echo "$NOW" > "$CACHE_FILE"
fi

# ---------------------------------------------------------------------------
# Tag-based drift (primary signal)
# ---------------------------------------------------------------------------
# Latest upstream tag reachable from upstream's default branch, sorted by
# semver descending. We use --merged upstream/<branch> so a tag on a release
# branch we haven't fetched doesn't count.
UPSTREAM_TAG=$(git tag --list --sort=-v:refname --merged "upstream/${DEFAULT_BRANCH}" 2>/dev/null | head -n 1)

# Latest tag the fork has actually merged into its default branch. If the
# fork is up to date on v1.0.0 and upstream is now on v1.1.0, LOCAL_TAG is
# v1.0.0 and UPSTREAM_TAG is v1.1.0.
LOCAL_TAG=$(git tag --list --sort=-v:refname --merged "${DEFAULT_BRANCH}" 2>/dev/null | head -n 1)

if [ -n "$UPSTREAM_TAG" ]; then
  # Upstream has at least one tag. Steady-state path.

  if [ -z "$LOCAL_TAG" ]; then
    # Fork has never merged any tag yet. First release sync is due.
    cat <<MSG
ApexYard: ${UPSTREAM_TAG} available. Run /update to sync.
MSG
    exit 0
  fi

  if [ "$UPSTREAM_TAG" = "$LOCAL_TAG" ]; then
    # Same release. Silent even if upstream/main has unreleased commits.
    exit 0
  fi

  # Both tags exist and differ. Decide which is newer by semver. Naive `!=`
  # would fire when a fork owner tagged their own main past upstream (e.g.
  # a private v2.0.0-acme on the fork while upstream is still v1.1.0), which
  # would nag them about an older upstream release they don't want.
  # `sort -V` does a version-aware sort; the last line is the newer tag.
  NEWER=$(printf '%s\n%s\n' "$UPSTREAM_TAG" "$LOCAL_TAG" | sort -V | tail -n 1)

  if [ "$NEWER" = "$UPSTREAM_TAG" ]; then
    # Upstream is strictly newer. Nag.
    cat <<MSG
ApexYard: ${UPSTREAM_TAG} available. Run /update to sync.
MSG
  fi
  # Local is strictly newer (fork has its own tag ahead of upstream's
  # latest release). Silent — not our business.
  exit 0
fi

# ---------------------------------------------------------------------------
# Fallback: no upstream tags at all.
# ---------------------------------------------------------------------------
# Honour the old commit-count behaviour so a freshly-forked project without
# any tag history still gets a useful banner. Once upstream cuts its first
# tag, subsequent sessions flow through the tag-based path above.
BEHIND=$(git rev-list --count "${DEFAULT_BRANCH}..upstream/${DEFAULT_BRANCH}" 2>/dev/null)

if [ -z "$BEHIND" ] || [ "$BEHIND" = "0" ]; then
  exit 0
fi

if [ "$BEHIND" = "1" ]; then
  SUFFIX="commit"
else
  SUFFIX="commits"
fi

cat <<MSG
ApexYard: ${BEHIND} ${SUFFIX} behind upstream/${DEFAULT_BRANCH} (no tags yet). Run /update to sync.
MSG

exit 0
