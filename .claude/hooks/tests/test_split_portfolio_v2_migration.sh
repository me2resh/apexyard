#!/bin/bash
# Smoke test for the split-portfolio v2 migration logic in /update.
#
# Builds a synthetic pre-v2 split-portfolio layout (sibling private repo
# + public fork with onboarding.yaml + workspace/ still in-fork), runs
# the move steps the /update skill would run, and asserts the post-state
# matches the v2 layout (onboarding + workspace in sibling, marker
# present in public, gitignore updated, project-config.json carries the
# new keys, portfolio_validate happy).
#
# This is a SHELL test of the migration recipe — it doesn't drive the
# /update skill itself (skills are markdown). The recipe lives inside
# the skill's step 8a; this test pins the bash to ensure the recipe
# stays runnable.
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB_OPS="$SRC_ROOT/.claude/hooks/_lib-ops-root.sh"
LIB_PORT="$SRC_ROOT/.claude/hooks/_lib-portfolio-paths.sh"
LIB_CFG="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"

for f in "$LIB_OPS" "$LIB_PORT" "$LIB_CFG" "$DEFAULTS"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed; migration logic uses jq" >&2
  exit 0
fi

PASS=0
FAIL=0
FAILED=""

mark_pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
mark_fail() { echo "  ✗ $1: $2" >&2; FAIL=$((FAIL+1)); FAILED="$FAILED\n  - $1"; }

# Builds a synthetic pre-v2 split-portfolio layout under $1:
#   $1/public/                 ← public fork
#   $1/public/onboarding.yaml
#   $1/public/workspace/demo/  (committed sample workspace)
#   $1/public/.claude/...      (libs + project-config.json with v1 portfolio block)
#   $1/private/                ← sibling private repo
#   $1/private/apexyard.projects.yaml
#   $1/private/projects/
#   $1/private/projects/ideas-backlog.md
build_pre_v2() {
  local sb="$1"
  mkdir -p "$sb/public/.claude/hooks" "$sb/public/workspace/demo"
  mkdir -p "$sb/private/projects"

  # Public fork — pre-v2 has onboarding.yaml + workspace/ here
  cat > "$sb/public/onboarding.yaml" <<'YAML'
company:
  name: "Test Co"
YAML
  echo "demo workspace content" > "$sb/public/workspace/demo/README.md"

  # Public fork has copies of the libs (production setup mirror)
  cp "$LIB_OPS" "$sb/public/.claude/hooks/_lib-ops-root.sh"
  cp "$LIB_PORT" "$sb/public/.claude/hooks/_lib-portfolio-paths.sh"
  cp "$LIB_CFG" "$sb/public/.claude/hooks/_lib-read-config.sh"
  mkdir -p "$sb/public/.claude"
  cp "$DEFAULTS" "$sb/public/.claude/project-config.defaults.json"

  # v1 split-portfolio config: portfolio block points at sibling repo
  # but only for registry / projects_dir / ideas_backlog (no v2 keys).
  cat > "$sb/public/.claude/project-config.json" <<JSON
{
  "portfolio": {
    "registry": "../private/apexyard.projects.yaml",
    "projects_dir": "../private/projects",
    "ideas_backlog": "../private/projects/ideas-backlog.md"
  }
}
JSON

  # Initial .gitignore (no v2 entries yet)
  cat > "$sb/public/.gitignore" <<'IGNORE'
node_modules/
*.log
IGNORE

  # Init the public fork as a git repo so portfolio_root finds toplevel
  ( cd "$sb/public" && git init -q && git config user.email "t@t.t" && git config user.name "t" \
    && git add -A && git commit -q -m "pre-v2 fixture" )

  # Sibling private repo
  cat > "$sb/private/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: demo
    repo: example/demo
YAML
  cat > "$sb/private/projects/ideas-backlog.md" <<'MD'
# Ideas Backlog
MD
}

# Run the migration recipe from /update step 8a in a subshell rooted at
# the public fork. Uses the same bash that the skill prescribes.
run_migration() {
  local public="$1"
  (
    cd "$public" || exit 99
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-read-config.sh
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-portfolio-paths.sh

    SIBLING_ROOT=$(dirname "$(jq -r '.portfolio.registry' .claude/project-config.json)")

    # Copy onboarding.yaml (NOT move — see AgDR-0021 § H).
    # Sibling becomes canonical; public-fork copy is untracked and left on
    # disk as a legacy ops-root walk-up fallback / safety-net snapshot.
    if [ -f onboarding.yaml ] && [ ! -f "$SIBLING_ROOT/onboarding.yaml" ]; then
      cp -p onboarding.yaml "$SIBLING_ROOT/onboarding.yaml"
      git rm --cached onboarding.yaml >/dev/null 2>&1 || true
    elif [ -f "$SIBLING_ROOT/onboarding.yaml" ] && [ -f onboarding.yaml ]; then
      # Idempotence: sibling is canonical, just ensure public-fork copy is untracked.
      git rm --cached onboarding.yaml >/dev/null 2>&1 || true
    fi

    # Move workspace contents
    if [ -d workspace ] && [ "$(ls -A workspace 2>/dev/null)" ]; then
      mkdir -p "$SIBLING_ROOT/workspace"
      for entry in workspace/*; do
        [ -e "$entry" ] || continue
        name=$(basename "$entry")
        if [ -e "$SIBLING_ROOT/workspace/$name" ]; then continue; fi
        mv "$entry" "$SIBLING_ROOT/workspace/$name"
      done
    fi

    # Update .gitignore
    NEEDS=()
    grep -qxF onboarding.yaml .gitignore 2>/dev/null || NEEDS+=(onboarding.yaml)
    grep -qxF workspace .gitignore 2>/dev/null || NEEDS+=(workspace)
    if [ "${#NEEDS[@]}" -gt 0 ]; then
      {
        echo ""
        echo "# Split-portfolio v2 (framework ≥ #242)"
        for n in "${NEEDS[@]}"; do echo "$n"; done
      } >> .gitignore
    fi

    # Write the .apexyard-fork marker
    if [ ! -f .apexyard-fork ]; then
      echo "# v2 anchor" > .apexyard-fork
    fi

    # Update project-config.json
    PCONFIG=.claude/project-config.json
    TMP=$(mktemp)
    jq --arg onb "$SIBLING_ROOT/onboarding.yaml" \
       --arg ws  "$SIBLING_ROOT/workspace" \
       '.portfolio.onboarding = (.portfolio.onboarding // $onb)
        | .portfolio.workspace_dir = (.portfolio.workspace_dir // $ws)' \
       "$PCONFIG" > "$TMP" && mv "$TMP" "$PCONFIG"
  )
}

# ---------------------------------------------------------------------------
# Case 1: end-to-end migration produces v2 layout
# ---------------------------------------------------------------------------
SB=$(mktemp -d)
SB=$(cd "$SB" && pwd -P)
build_pre_v2 "$SB"

# Sanity pre-checks
if [ ! -f "$SB/public/onboarding.yaml" ]; then
  mark_fail "pre-state" "expected onboarding.yaml in public fork"; rm -rf "$SB"; exit 1
fi
if [ ! -d "$SB/public/workspace/demo" ]; then
  mark_fail "pre-state" "expected workspace/demo in public fork"; rm -rf "$SB"; exit 1
fi

run_migration "$SB/public"

# Post-checks
#
# onboarding.yaml: COPY semantics (refined #317, see AgDR-0021 § H).
# Both copies exist, contents are identical, and the public-fork copy
# is untracked (git rm --cached'd) so it can't drift into commits.
[ -f "$SB/public/onboarding.yaml" ] \
  && mark_pass "onboarding.yaml snapshot retained in public fork (copy semantics)" \
  || mark_fail "onboarding snapshot retained" "missing from public fork"

[ -f "$SB/private/onboarding.yaml" ] \
  && mark_pass "onboarding.yaml landed in sibling private repo (canonical)" \
  || mark_fail "onboarding landed" "missing in sibling repo"

if [ -f "$SB/public/onboarding.yaml" ] && [ -f "$SB/private/onboarding.yaml" ]; then
  if cmp -s "$SB/public/onboarding.yaml" "$SB/private/onboarding.yaml"; then
    mark_pass "onboarding.yaml: public-fork snapshot matches sibling-repo canonical"
  else
    mark_fail "onboarding identical" "public-fork and sibling-repo copies differ"
  fi
fi

# The public-fork copy must be UNTRACKED so future commits don't ship it.
# `git ls-files` lists tracked paths only — empty output means untracked.
if [ -z "$( cd "$SB/public" && git ls-files onboarding.yaml 2>/dev/null )" ]; then
  mark_pass "onboarding.yaml untracked in public fork (git rm --cached applied)"
else
  mark_fail "onboarding untracked" "still tracked in public fork"
fi

[ ! -d "$SB/public/workspace/demo" ] \
  && mark_pass "workspace/demo moved out of public fork" \
  || mark_fail "workspace moved" "still present in public fork"

[ -d "$SB/private/workspace/demo" ] && [ -f "$SB/private/workspace/demo/README.md" ] \
  && mark_pass "workspace/demo landed in sibling private repo" \
  || mark_fail "workspace landed" "missing or incomplete in sibling repo"

[ -f "$SB/public/.apexyard-fork" ] \
  && mark_pass ".apexyard-fork marker written in public fork" \
  || mark_fail "marker present" ".apexyard-fork missing"

grep -qxF onboarding.yaml "$SB/public/.gitignore" \
  && mark_pass "onboarding.yaml added to public-fork .gitignore" \
  || mark_fail "gitignore onboarding" "not added"

grep -qxF workspace "$SB/public/.gitignore" \
  && mark_pass "workspace added to public-fork .gitignore" \
  || mark_fail "gitignore workspace" "not added"

ONB_KEY=$(jq -r '.portfolio.onboarding // empty' "$SB/public/.claude/project-config.json")
WS_KEY=$(jq -r '.portfolio.workspace_dir // empty' "$SB/public/.claude/project-config.json")
[ -n "$ONB_KEY" ] \
  && mark_pass "portfolio.onboarding key added to project-config.json (=$ONB_KEY)" \
  || mark_fail "config key onboarding" "not added"
[ -n "$WS_KEY" ] \
  && mark_pass "portfolio.workspace_dir key added to project-config.json (=$WS_KEY)" \
  || mark_fail "config key workspace_dir" "not added"

# Validate the post-state
(
  cd "$SB/public" || exit 1
  # shellcheck source=/dev/null
  . .claude/hooks/_lib-read-config.sh
  # shellcheck source=/dev/null
  . .claude/hooks/_lib-portfolio-paths.sh
  portfolio_clear_cache
  if portfolio_validate >/dev/null 2>&1; then
    exit 0
  else
    err=$(portfolio_validate 2>&1)
    echo "validate failed: $err" >&2
    exit 1
  fi
)
if [ "$?" -eq 0 ]; then
  mark_pass "portfolio_validate happy on post-migration v2 layout"
else
  mark_fail "validate post-state" "see error above"
fi

# ---------------------------------------------------------------------------
# Case 2: re-running the migration is a no-op (idempotence)
# ---------------------------------------------------------------------------
# Capture state, re-run, compare.
PRE_LIST=$(find "$SB/public" "$SB/private" -type f 2>/dev/null | sort)
run_migration "$SB/public"
POST_LIST=$(find "$SB/public" "$SB/private" -type f 2>/dev/null | sort)

# .gitignore should have exactly one entry per v2 file class even after re-run.
GI_ONB=$(grep -cxF onboarding.yaml "$SB/public/.gitignore" 2>/dev/null || echo 0)
GI_WS=$(grep -cxF workspace "$SB/public/.gitignore" 2>/dev/null || echo 0)
if [ "$GI_ONB" -eq 1 ] && [ "$GI_WS" -eq 1 ]; then
  mark_pass "idempotence: .gitignore has exactly one entry per file class"
else
  mark_fail "idempotence gitignore" "got onboarding=$GI_ONB workspace=$GI_WS (expected 1 each)"
fi

if [ "$PRE_LIST" = "$POST_LIST" ]; then
  mark_pass "idempotence: file listing unchanged on re-run"
else
  mark_fail "idempotence files" "file listing changed on re-run"
  diff <(echo "$PRE_LIST") <(echo "$POST_LIST") | head -20 >&2
fi

rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 3: ops-root walk finds the v2 fork via .apexyard-fork marker
# (proves the v2 layout works even though onboarding+apexyard.projects.yaml
#  are no longer in the public fork)
# ---------------------------------------------------------------------------
SB=$(mktemp -d)
SB=$(cd "$SB" && pwd -P)
build_pre_v2 "$SB"
run_migration "$SB/public"

(
  # shellcheck source=/dev/null
  . "$LIB_OPS"
  out=$(cd "$SB/public" && resolve_ops_root)
  [ "$out" = "$SB/public" ] || { echo "ops_root expected $SB/public got $out" >&2; exit 1; }
  exit 0
)
if [ "$?" -eq 0 ]; then
  mark_pass "post-v2: resolve_ops_root finds the public fork via .apexyard-fork"
else
  mark_fail "post-v2 ops_root" "see error above"
fi

rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 4: onboarding.yaml is COPIED (not moved) — explicit semantics check
#
# Refined in #317 (see AgDR-0021 § H): the public-fork onboarding.yaml is
# left on disk as an untracked gitignored snapshot so the legacy ops-root
# walk-up fallback (_lib-ops-root.sh) keeps working even if .apexyard-fork
# is accidentally removed. The sibling-repo copy is canonical.
#
# This case modifies the public-fork copy AFTER migration and asserts the
# sibling-repo copy is NOT affected — proves the two are independent files
# (a `mv` followed by `cp` to recreate would have the same observable
# pre-state but reading would still be a single canonical copy; this test
# specifically pins that we have two real files on disk).
# ---------------------------------------------------------------------------
SB=$(mktemp -d)
SB=$(cd "$SB" && pwd -P)
build_pre_v2 "$SB"

# Capture pre-migration content for comparison
ORIG_CONTENT=$(cat "$SB/public/onboarding.yaml")

run_migration "$SB/public"

# Sanity: both files exist after migration
if [ ! -f "$SB/public/onboarding.yaml" ] || [ ! -f "$SB/private/onboarding.yaml" ]; then
  mark_fail "case-4 sanity" "expected both copies of onboarding.yaml post-migration"
else
  # Modify the public-fork snapshot
  echo "# touched by case 4" >> "$SB/public/onboarding.yaml"

  # The sibling-repo copy must be untouched (independent file, not a hard link)
  SIB_CONTENT=$(cat "$SB/private/onboarding.yaml")
  if [ "$SIB_CONTENT" = "$ORIG_CONTENT" ]; then
    mark_pass "copy-not-move: sibling-repo onboarding.yaml unaffected by public-fork edits"
  else
    mark_fail "copy semantics" "sibling-repo copy changed when public-fork copy was edited (hard link or move-with-symlink?)"
  fi

  # And both must be on disk simultaneously (the load-bearing semantic of copy vs move)
  if [ -f "$SB/public/onboarding.yaml" ] && [ -f "$SB/private/onboarding.yaml" ]; then
    mark_pass "copy-not-move: both public-fork and sibling-repo onboarding.yaml exist after migration"
  else
    mark_fail "both copies exist" "one of the copies is missing"
  fi

  # And the public-fork .gitignore must list onboarding.yaml so the snapshot can't drift back into commits
  if grep -qxF onboarding.yaml "$SB/public/.gitignore"; then
    mark_pass "copy-not-move: public-fork .gitignore lists onboarding.yaml (snapshot can't drift into commits)"
  else
    mark_fail "gitignore guards snapshot" "onboarding.yaml not in public-fork .gitignore"
  fi
fi

rm -rf "$SB"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "===== test_split_portfolio_v2_migration.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED"
  exit 1
fi
exit 0
