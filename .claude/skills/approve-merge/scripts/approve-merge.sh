#!/bin/bash
# Check merge prerequisites. Read markers without changing them.
set -u
fail() { printf '%s\n' "$2" >&2; exit "$1"; }
[ "$#" -eq 3 ] || fail 1 'Usage: approve-merge.sh <pr-number> <repo owner/repo> <marker_home>'
PR=$1 REPO=$2 MARKER_HOME=$3
[[ "$PR" =~ ^[0-9]+$ ]] && [ -n "$REPO" ] || fail 1 'Invalid PR or repo.'
[ -f "$MARKER_HOME/.claude/hooks/_lib-read-config.sh" ] || fail 1 'Cannot load config from marker_home.'
# Read configuration from the supplied ops fork.
cd "$MARKER_HOME" || fail 1 'Cannot enter marker_home.'
MARKER_HOME=$(pwd -P) || fail 1 'Cannot resolve marker_home.'
export APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1
# shellcheck source=/dev/null
source "$MARKER_HOME/.claude/hooks/_lib-read-config.sh" >&2 || fail 1 'Cannot load config library.'
# Pin the config helper to the caller's resolved root.
_CONFIG_ROOT_CACHE="$MARKER_HOME"
_CONFIG_ROOT_CACHE_SET=1
STATE=$(gh pr view "$PR" --repo "$REPO" --json state,isDraft,mergeable,headRefOid,mergeStateStatus,baseRefName) || fail 1 'Cannot read PR state.'
jq -e '.state == "OPEN" and .isDraft == false and .mergeable != "CONFLICTING" and (.headRefOid | type == "string" and length > 0) and (.baseRefName | type == "string" and length > 0)' <<< "$STATE" >/dev/null || fail 1 'PR state does not permit approval.'
HEAD_SHA=$(jq -r '.headRefOid' <<< "$STATE") || fail 1 'Cannot read head SHA.'
BASE=$(jq -r '.baseRefName' <<< "$STATE") || fail 1 'Cannot read base branch.'
REQUIRE_UP_TO_DATE=$(config_get_or '.merge.require_up_to_date' 'true') || fail 1 'Cannot read merge configuration.'
# Load carry-over support even when the behind check is disabled.
# shellcheck source=/dev/null
source "$MARKER_HOME/.claude/hooks/_lib-merge-behind.sh" >&2 || fail 1 'Cannot load behind-base library.'
if [ "$REQUIRE_UP_TO_DATE" != false ]; then
  BEHIND=$(is_pr_behind_base "$REPO" "$BASE" "$HEAD_SHA") || fail 11 'Behind-base check could not run.'
  case "$BEHIND" in
    false) ;;
    true)
      BASE_MERGE_COMMIT_SHA=$(gh api "repos/${REPO}/compare/${BASE}...${HEAD_SHA}" -q '.merge_base_commit.sha') || fail 10 'Cannot verify base changes. Refresh required.'
      SHARED_PATTERNS=$(config_get '.merge.shared_file_patterns[]') || fail 10 'Cannot read shared file patterns. Refresh required.'
      REFRESH=$(merge_refresh_required "$REPO" "$BASE" "$PR" "$BASE_MERGE_COMMIT_SHA" "$SHARED_PATTERNS") || fail 10 'Cannot verify refresh requirements.'
      if [ "$REFRESH" = skippable ]; then
        printf '%s\n' 'Refresh skipped: base changes overlap neither PR files nor shared file patterns.' >&2
      else
        fail 10 "PR #$PR is behind its base branch ($BASE) and the base's new commits touch a file this PR shares.
Before this can merge:
  1. Update the branch: gh pr update-branch $PR --repo $REPO
  2. Wait for green CI on the updated branch.
  3. Run rex_approval_carries_over first. Request a Rex delta review unless it returns true. Write no marker by hand.
  4. Run /approve-merge $PR again."
      fi
      ;;
    *) fail 11 "PR #$PR's behind-base check could not run (the compare API call failed). Retry or verify $BASE manually, then run /approve-merge again." ;;
  esac
fi
# shellcheck source=/dev/null
source "$MARKER_HOME/.claude/hooks/_lib-review-markers.sh" >&2 || fail 12 'Cannot load marker library.'
PR_HOST_REPO=$(pr_base_repo "$PR" "$REPO") || fail 12 'Cannot resolve PR host repo.'
[ -n "$PR_HOST_REPO" ] || fail 12 'PR host repo is empty.'
REX=$(review_marker_path "$PR_HOST_REPO" "$PR" rex "$MARKER_HOME") || fail 12 'Cannot resolve Rex marker.'
if [ ! -f "$REX" ]; then
  NEAR_MISS=$(unqualified_marker_path "$MARKER_HOME" "$PR" rex) || fail 12 'Cannot diagnose missing marker.'
  if [ -f "$NEAR_MISS" ]; then
    printf 'Gate-invisible marker found: %s\nExpected: %s\n' "$NEAR_MISS" "$REX" >&2
    printf '%s\n' 'do not move, rename or copy that file into place. Delete it and re-run /code-review without a marker path.' >&2
  fi
  fail 12 "Rex marker missing: $REX. Run /code-review $PR."
fi
REX_SHA=$(tr -d '[:space:]' < "$REX") || fail 12 'Cannot read Rex marker.'
if [ "$REX_SHA" != "$HEAD_SHA" ]; then
  [ -n "$REX_SHA" ] && command -v rex_approval_carries_over >/dev/null 2>&1 || fail 12 'Rex marker is stale. Re-run /code-review on the current HEAD.'
  CARRY_OVER=$(rex_approval_carries_over "$PR_HOST_REPO" "$REX_SHA" "$HEAD_SHA" "$BASE") || fail 12 'Rex carry-over check failed.'
  [ "$CARRY_OVER" = true ] || fail 12 'Rex marker is stale. Re-run /code-review on the current HEAD.'
fi
PR_HEAD_BRANCH=$(gh pr view "$PR" --repo "$PR_HOST_REPO" --json headRefName -q '.headRefName') || fail 13 'Cannot read PR branch.'
PR_TITLE=$(gh pr view "$PR" --repo "$PR_HOST_REPO" --json title -q '.title') || fail 13 'Cannot read PR title.'
STRATEGY=squash
SYNC_TITLE_PATTERN='^chore(\([^)]*\))?: sync ops fork with upstream'
if [[ "$PR_HEAD_BRANCH" =~ ^(sync/main-to-dev-after-|chore/(#[^/]+-)?sync-upstream-(apexyard|dev)$) ]] ||
   [[ "$PR_TITLE" =~ ^sync\( ]] || [[ "$PR_TITLE" =~ $SYNC_TITLE_PATTERN ]]; then
  STRATEGY=merge
fi
RELEASE_CLASS=false
if [[ "$PR_HEAD_BRANCH" =~ ^release/v[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$PR_TITLE" =~ ^release\( ]]; then
  RELEASE_CLASS=true
  [ -n "$PR_TITLE" ] || fail 13 "Cannot read the release PR's title. Retry /approve-merge."
  BODY=$(gh pr view "$PR" --repo "$PR_HOST_REPO" --json body -q '.body') || fail 13 "Cannot read the release PR's body. Retry /approve-merge."
  [ -n "$BODY" ] || fail 13 'Release body is empty. Refusing to drop the Released-From trailer.'
fi
jq -cn --arg marker_home "$MARKER_HOME" --arg pr_host_repo "$PR_HOST_REPO" --arg strategy "$STRATEGY" --arg head_sha "$HEAD_SHA" --argjson release_class "$RELEASE_CLASS" '{marker_home:$marker_home,pr_host_repo:$pr_host_repo,strategy:$strategy,head_sha:$head_sha,release_class:$release_class}' || fail 1 'Cannot produce result JSON.'
