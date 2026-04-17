#!/bin/bash
# SessionStart hook: shows a one-line banner when the fork is behind upstream
# me2resh/apexstack, so the user knows to run /update.
#
# Silent exit paths (no output, no error):
#   - Not a git repo
#   - No `upstream` remote configured (this is the upstream repo itself,
#     or the fork hasn't set up `upstream` yet — /setup reminds them)
#   - Fetch fails (offline, git hosting down, permission)
#   - Fork is up-to-date
#
# Banner emits only when the fork is genuinely behind upstream/<default-branch>.
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
  if ! timeout 5 git fetch upstream --quiet 2>/dev/null; then
    exit 0
  fi
  mkdir -p "$CACHE_DIR"
  echo "$NOW" > "$CACHE_FILE"
fi

# Count commits in upstream/<default-branch> not present in the local
# default-branch tip. rev-list is local after fetch, no network.
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
ApexStack: ${BEHIND} ${SUFFIX} behind upstream/${DEFAULT_BRANCH}. Run /update to sync.
MSG

exit 0
