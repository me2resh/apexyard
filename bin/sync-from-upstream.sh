#!/usr/bin/env bash
# Sync this fork with the upstream apexyard repository.
#
# Brings new framework versions into the local fork without auto-merging.
# The user reviews the diff, then either:
#   - fast-forward if clean, or
#   - cherry-pick / rebase for selective adoption.
#
# Usage:
#   bin/sync-from-upstream.sh            # full diff + update sync branch
#   bin/sync-from-upstream.sh --preview  # just show what would land (no writes)
#
# Requires:
#   - `origin` pointing at your fork
#   - `upstream` pointing at the canonical apexyard repo
#   - clean working tree (or `-f` to force)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PREVIEW=false
[[ "${1:-}" == "--preview" ]] && PREVIEW=true

# --- 0. Refuse to run with a dirty working tree ---------------------------
if ! git diff --quiet HEAD 2>/dev/null; then
  echo "ERROR: working tree is dirty. Commit or stash before syncing."
  echo "       (re-run with --no-verify to skip this check)"
  exit 1
fi

# --- 1. Verify remotes ---------------------------------------------------
if ! git remote get-url upstream >/dev/null 2>&1; then
  echo "ERROR: 'upstream' remote is not configured."
  echo "       Add it with:"
  echo "         git remote add upstream https://github.com/me2resh/apexyard.git"
  exit 1
fi
if ! git remote get-url origin >/dev/null 2>&1; then
  echo "ERROR: 'origin' remote is not configured."
  exit 1
fi

UPSTREAM_URL=$(git remote get-url upstream)
ORIGIN_URL=$(git remote get-url origin)
echo "origin   = $ORIGIN_URL"
echo "upstream = $UPSTREAM_URL"
echo

# --- 2. Fetch upstream ---------------------------------------------------
echo "[1/4] fetching upstream..."
git fetch upstream --tags --prune

# --- 3. Show what's new ---------------------------------------------------
echo
echo "[2/4] new commits since last sync:"
echo "  origin/main..upstream/main (commits available to pull):"
git log --oneline origin/main..upstream/main 2>/dev/null | head -20 || echo "  (no commits)"
echo
echo "  shared/..upstream/main:shared/ (framework changes only):"
git log --oneline origin/main..upstream/main -- shared/ 2>/dev/null | head -20 || echo "  (no shared/ changes)"
echo

# --- 4. Preview mode ------------------------------------------------------
if $PREVIEW; then
  echo "[3/4] preview mode — full diff vs upstream/main:"
  echo
  git diff --stat origin/main..upstream/main | tail -30
  echo
  echo "  Run without --preview to create a sync branch:"
  echo "    bin/sync-from-upstream.sh"
  exit 0
fi

# --- 5. Create sync branch ------------------------------------------------
SYNC_BRANCH="chore/sync-upstream-$(date +%Y%m%d)"
echo "[3/4] creating sync branch: $SYNC_BRANCH"
git checkout -b "$SYNC_BRANCH" origin/main

# --- 6. Merge upstream/main (no-ff so the sync point is visible) ---------
echo "[4/4] merging upstream/main..."
if ! git merge --no-ff upstream/main -m "chore(sync): pull upstream/main into $SYNC_BRANCH"; then
  echo
  echo "MERGE CONFLICT — resolve manually, then run:"
  echo "  git add <resolved-files>"
  echo "  git commit --no-edit"
  echo
  echo "Common conflicts to expect:"
  echo "  - shared/    (framework rules/hooks/roles — usually clean)"
  echo "  - INSTRUCTIONS.md / README.md (overwritten by adopter content)"
  echo "  - .claude/ (bash hook logic — usually clean)"
  exit 2
fi

# --- 7. Re-run the generator ---------------------------------------------
echo
echo "[post-merge] regenerating .opencode/ and .codex/ from shared/..."
if [ -f package.json ] && [ -d node_modules ]; then
  bun run sync
else
  bun install --silent 2>/dev/null || true
  bun run sync
fi

# --- 8. Done -------------------------------------------------------------
echo
echo "Sync complete. Branch: $SYNC_BRANCH"
echo
echo "Next steps:"
echo "  1. Review the diff:  git diff origin/main --stat"
echo "  2. If the sync introduced new hooks/roles, regenerate:"
echo "       bun run migrate        # only if you want to import new .claude/ items"
echo "       bun run sync           # always safe to re-run"
echo "  3. Run the hook test suite:  bun run test:hooks"
echo "  4. Open a PR:  gh pr create --base main --head $SYNC_BRANCH \\"
echo "                  --title 'chore(sync): pull upstream' \\"
echo "                  --body 'Re-run \`bun run sync\` after merge to regenerate .opencode/ and .codex/'"
