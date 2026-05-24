#!/bin/bash
# Integration test for /update step 8a wiring — verify the v1→v2
# migration is OFFERED only on pre-v2 split-portfolio adopters, and
# silently no-ops on v2 + single-fork forks.
#
# Distinct from test_split_portfolio_v2_migration.sh (which tests the
# migration BODY — `cp -p` of onboarding (copy-not-move per AgDR-0021 § H),
# `mv` of workspace contents, `.apexyard-fork` write, gitignore additions,
# jq config-block update, idempotence).
# This test pins the INVOCATION/DETECTION logic from
# `.claude/skills/update/SKILL.md` § 8a:
#
#   V2_NEEDED=0  if portfolio_is_v2   (already v2)
#   V2_NEEDED=0  if no .portfolio.registry key   (single-fork)
#   V2_NEEDED=1  if .portfolio.registry present AND no .apexyard-fork
#                marker  (pre-v2 split-portfolio adopter)
#
# Plus the --dry-run branch which prints the migration plan but does
# not mutate state.
#
# Four detection branches under test:
#
#   Case 1: v2 fork (has .apexyard-fork marker + portfolio block)
#           → V2_NEEDED=0 → silent no-op, no state change
#   Case 2: single-fork (no portfolio block at all)
#           → V2_NEEDED=0 → silent no-op, no state change
#   Case 3: pre-v2 split-portfolio (portfolio block, no .apexyard-fork)
#           → V2_NEEDED=1 → migration applies, state changes match v2 spec
#   Case 4: --dry-run on a pre-v2 split-portfolio
#           → V2_NEEDED=1 → plan printed, NO state change
#
# Exit 0 on all-pass, 1 on any fail.

set -u

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
LIB_OPS="$ROOT/.claude/hooks/_lib-ops-root.sh"
LIB_PORT="$ROOT/.claude/hooks/_lib-portfolio-paths.sh"
LIB_CFG="$ROOT/.claude/hooks/_lib-read-config.sh"
DEFAULTS="$ROOT/.claude/project-config.defaults.json"

for f in "$LIB_OPS" "$LIB_PORT" "$LIB_CFG" "$DEFAULTS"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing $f" >&2
    exit 1
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed; step 8a detection uses jq" >&2
  exit 0
fi

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

PASS=0
FAIL=0
FAILED_CASES=""

mark_pass() { green "  ok   $1"; PASS=$((PASS+1)); }
mark_fail() {
  red "  FAIL $1: $2" >&2
  FAIL=$((FAIL+1))
  FAILED_CASES="$FAILED_CASES\n  - $1"
}

TMP_ROOT=$(mktemp -d)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT

# ---------------------------------------------------------------------------
# Fixture: public fork + sibling private repo in v1 split-portfolio layout
# (registry + projects/ in the sibling, onboarding + workspace still in the
# public fork, NO .apexyard-fork marker yet). Mirrors what an adopter on
# framework < #242 had before /update ≥ #242 offers them the migration.
# ---------------------------------------------------------------------------
build_pre_v2_split() {
  local sb="$1"
  mkdir -p "$sb/public/.claude/hooks" "$sb/public/workspace/demo"
  mkdir -p "$sb/private/projects"

  cat > "$sb/public/onboarding.yaml" <<'YAML'
company:
  name: "Test Co"
YAML
  echo "demo workspace content" > "$sb/public/workspace/demo/README.md"

  cp "$LIB_OPS"  "$sb/public/.claude/hooks/_lib-ops-root.sh"
  cp "$LIB_PORT" "$sb/public/.claude/hooks/_lib-portfolio-paths.sh"
  cp "$LIB_CFG"  "$sb/public/.claude/hooks/_lib-read-config.sh"
  cp "$DEFAULTS" "$sb/public/.claude/project-config.defaults.json"

  cat > "$sb/public/.claude/project-config.json" <<JSON
{
  "portfolio": {
    "registry": "../private/apexyard.projects.yaml",
    "projects_dir": "../private/projects",
    "ideas_backlog": "../private/projects/ideas-backlog.md"
  }
}
JSON

  cat > "$sb/public/.gitignore" <<'IGNORE'
node_modules/
*.log
IGNORE

  (
    cd "$sb/public" \
      && git init -q \
      && git config user.email "t@t.t" \
      && git config user.name "t" \
      && git add -A \
      && git commit -q -m "v1 split-portfolio fixture"
  )

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

# ---------------------------------------------------------------------------
# Fixture: v2 split-portfolio adopter — same as build_pre_v2_split, but
# the .apexyard-fork marker exists at the public-fork root AND the
# portfolio block already carries the v2 keys (onboarding + workspace
# resolved into the sibling repo).
# ---------------------------------------------------------------------------
build_v2_split() {
  local sb="$1"
  mkdir -p "$sb/public/.claude/hooks"
  mkdir -p "$sb/private/projects" "$sb/private/workspace/demo"

  cp "$LIB_OPS"  "$sb/public/.claude/hooks/_lib-ops-root.sh"
  cp "$LIB_PORT" "$sb/public/.claude/hooks/_lib-portfolio-paths.sh"
  cp "$LIB_CFG"  "$sb/public/.claude/hooks/_lib-read-config.sh"
  cp "$DEFAULTS" "$sb/public/.claude/project-config.defaults.json"

  cat > "$sb/public/.claude/project-config.json" <<JSON
{
  "portfolio": {
    "registry":      "../private/apexyard.projects.yaml",
    "projects_dir":  "../private/projects",
    "ideas_backlog": "../private/projects/ideas-backlog.md",
    "onboarding":    "../private/onboarding.yaml",
    "workspace_dir": "../private/workspace"
  }
}
JSON

  cat > "$sb/public/.gitignore" <<'IGNORE'
node_modules/
*.log

# Split-portfolio v2
apexyard.projects.yaml
projects
onboarding.yaml
workspace
IGNORE

  echo "# v2 anchor" > "$sb/public/.apexyard-fork"

  (
    cd "$sb/public" \
      && git init -q \
      && git config user.email "t@t.t" \
      && git config user.name "t" \
      && git add -A \
      && git commit -q -m "v2 split-portfolio fixture"
  )

  cat > "$sb/private/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: demo
    repo: example/demo
YAML
  cat > "$sb/private/projects/ideas-backlog.md" <<'MD'
# Ideas Backlog
MD
  cat > "$sb/private/onboarding.yaml" <<'YAML'
company:
  name: "Test Co"
YAML
  echo "demo workspace content" > "$sb/private/workspace/demo/README.md"
}

# ---------------------------------------------------------------------------
# Fixture: single-fork adopter — onboarding + registry both in the fork,
# no portfolio: config block at all. Step 8a should silently skip.
# ---------------------------------------------------------------------------
build_single_fork() {
  local sb="$1"
  mkdir -p "$sb/.claude/hooks" "$sb/projects" "$sb/workspace"

  cat > "$sb/onboarding.yaml" <<'YAML'
company:
  name: "Test Co"
YAML
  cat > "$sb/apexyard.projects.yaml" <<'YAML'
version: 1
projects: []
YAML
  cat > "$sb/projects/ideas-backlog.md" <<'MD'
# Ideas Backlog
MD

  cp "$LIB_OPS"  "$sb/.claude/hooks/_lib-ops-root.sh"
  cp "$LIB_PORT" "$sb/.claude/hooks/_lib-portfolio-paths.sh"
  cp "$LIB_CFG"  "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$DEFAULTS" "$sb/.claude/project-config.defaults.json"

  # Either no project-config.json at all OR one without a portfolio block.
  # Test both shapes — start with no override file.

  (
    cd "$sb" \
      && git init -q \
      && git config user.email "t@t.t" \
      && git config user.name "t" \
      && git add -A \
      && git commit -q -m "single-fork fixture"
  )
}

# ---------------------------------------------------------------------------
# detect_v2_needed: mirrors the detection logic from SKILL.md § 8a.
# Returns 0 if migration is needed, 1 if not.
#
# Reads inside the candidate fork dir (caller is expected to have cd'd
# into it).
# ---------------------------------------------------------------------------
detect_v2_needed() {
  local fork="$1"
  (
    cd "$fork" || return 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-read-config.sh
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-portfolio-paths.sh
    portfolio_clear_cache

    if portfolio_is_v2; then
      return 1
    fi
    if ! jq -e '.portfolio.registry' .claude/project-config.json >/dev/null 2>&1; then
      return 1
    fi
    return 0
  )
}

# ---------------------------------------------------------------------------
# Snapshot a fork's relevant file state so we can detect mutation. Records
# the SHA of onboarding.yaml + workspace tree + .gitignore + the absence
# of .apexyard-fork.
# ---------------------------------------------------------------------------
snapshot_state() {
  local fork="$1"
  (
    cd "$fork" || return 1
    {
      # Per-file SHAs (only files that step 8a would touch)
      for path in onboarding.yaml .gitignore .apexyard-fork .claude/project-config.json; do
        if [ -e "$path" ]; then
          shasum "$path" 2>/dev/null
        else
          echo "ABSENT $path"
        fi
      done
      # workspace tree listing (step 8a moves entries)
      find workspace -mindepth 1 2>/dev/null | LC_ALL=C sort
    }
  )
}

# ---------------------------------------------------------------------------
# Case 1: v2 fork — step 8a silently no-ops
# ---------------------------------------------------------------------------
echo "== Case 1: v2 fork (has .apexyard-fork + v2 portfolio block) → no-op"
SB="$TMP_ROOT/case1"
build_v2_split "$SB"

if detect_v2_needed "$SB/public"; then
  mark_fail "v2 detection" "V2_NEEDED=1 on a v2 fork (expected 0)"
else
  mark_pass "V2_NEEDED=0 on v2 fork (silent skip)"
fi

# Verify portfolio_is_v2 returns true on this fixture
(
  cd "$SB/public" || exit 1
  # shellcheck source=/dev/null
  . .claude/hooks/_lib-read-config.sh
  # shellcheck source=/dev/null
  . .claude/hooks/_lib-portfolio-paths.sh
  portfolio_clear_cache
  portfolio_is_v2 || exit 1
)
if [ "$?" -eq 0 ]; then
  mark_pass "portfolio_is_v2 returns true on v2 fixture"
else
  mark_fail "portfolio_is_v2 on v2" "expected true"
fi

# ---------------------------------------------------------------------------
# Case 2: single-fork — step 8a silently no-ops
# ---------------------------------------------------------------------------
echo "== Case 2: single-fork (no portfolio block) → no-op"
SB="$TMP_ROOT/case2"
build_single_fork "$SB"

# Create the file with no portfolio key — exercise the empty-override
# branch of the jq detection.
echo '{"_comment": "no portfolio block"}' > "$SB/.claude/project-config.json"

if detect_v2_needed "$SB"; then
  mark_fail "single-fork detection" "V2_NEEDED=1 on a single-fork (expected 0)"
else
  mark_pass "V2_NEEDED=0 on single-fork (no portfolio block — silent skip)"
fi

# ---------------------------------------------------------------------------
# Case 3: pre-v2 split → migration fires + state matches v2 spec
# ---------------------------------------------------------------------------
echo "== Case 3: pre-v2 split-portfolio → migration fires"
SB="$TMP_ROOT/case3"
build_pre_v2_split "$SB"

if detect_v2_needed "$SB/public"; then
  mark_pass "V2_NEEDED=1 on pre-v2 split-portfolio (migration applies)"
else
  mark_fail "pre-v2 detection" "V2_NEEDED=0 on pre-v2 split (expected 1)"
fi

# Apply the migration body (mirrors SKILL.md § 8a Migration steps).
# IMPORTANT: this is a deliberate mirror, not a call into a separate
# library — test_step_8a_wiring is the WIRING test; the migration body
# is exercised exhaustively by test_split_portfolio_v2_migration.sh.
(
  cd "$SB/public" || exit 99
  # shellcheck source=/dev/null
  . .claude/hooks/_lib-read-config.sh
  # shellcheck source=/dev/null
  . .claude/hooks/_lib-portfolio-paths.sh

  SIBLING_ROOT=$(dirname "$(jq -r '.portfolio.registry' .claude/project-config.json)")

  # Copy onboarding.yaml — NOT move (copy-not-move semantics, AgDR-0021 § H,
  # landed in PR #317 / ticket #319 cross-reference). Sibling becomes the
  # canonical copy; public-fork snapshot is left in place and untracked via
  # `git rm --cached` so future commits don't ship a divergent file.
  if [ -f onboarding.yaml ] && [ ! -f "$SIBLING_ROOT/onboarding.yaml" ]; then
    cp -p onboarding.yaml "$SIBLING_ROOT/onboarding.yaml"
    git rm --cached onboarding.yaml >/dev/null 2>&1 || true
  fi

  # Move workspace entries (skip workspace/README.md per AgDR-0021 § G)
  if [ -d workspace ] && [ "$(ls -A workspace 2>/dev/null)" ]; then
    mkdir -p "$SIBLING_ROOT/workspace"
    for entry in workspace/*; do
      [ -e "$entry" ] || continue
      name=$(basename "$entry")
      [ "$name" = "README.md" ] && continue
      if [ ! -e "$SIBLING_ROOT/workspace/$name" ]; then
        mv "$entry" "$SIBLING_ROOT/workspace/$name"
      fi
    done
  fi

  # gitignore additions
  NEEDS=()
  grep -qxF onboarding.yaml .gitignore 2>/dev/null || NEEDS+=(onboarding.yaml)
  grep -qxF workspace .gitignore 2>/dev/null || NEEDS+=(workspace)
  if [ "${#NEEDS[@]}" -gt 0 ]; then
    {
      echo ""
      echo "# Split-portfolio v2"
      for n in "${NEEDS[@]}"; do echo "$n"; done
    } >> .gitignore
  fi

  # v2 marker
  if [ ! -f .apexyard-fork ]; then
    echo "# v2 anchor" > .apexyard-fork
  fi

  # config-block additions
  PCONFIG=.claude/project-config.json
  TMP=$(mktemp)
  jq --arg onb "$SIBLING_ROOT/onboarding.yaml" \
     --arg ws  "$SIBLING_ROOT/workspace" \
     '.portfolio.onboarding = (.portfolio.onboarding // $onb)
      | .portfolio.workspace_dir = (.portfolio.workspace_dir // $ws)' \
     "$PCONFIG" > "$TMP" && mv "$TMP" "$PCONFIG"
)

# Post-state assertions
#
# COPY-NOT-MOVE semantics (AgDR-0021 § H): both copies exist, contents are
# identical, and the public-fork copy is untracked. The sibling copy is
# canonical; the public-fork copy is left as a legacy ops-root walk-up
# fallback / safety-net snapshot.
[ -f "$SB/public/onboarding.yaml" ] \
  && mark_pass "post-migration: onboarding.yaml snapshot retained in public fork (copy semantics)" \
  || mark_fail "onboarding snapshot retained" "missing from public fork"

[ -f "$SB/private/onboarding.yaml" ] \
  && mark_pass "post-migration: onboarding.yaml landed in sibling repo (canonical)" \
  || mark_fail "onboarding landed" "missing in sibling"

if [ -f "$SB/public/onboarding.yaml" ] && [ -f "$SB/private/onboarding.yaml" ]; then
  if cmp -s "$SB/public/onboarding.yaml" "$SB/private/onboarding.yaml"; then
    mark_pass "post-migration: public-fork snapshot matches sibling-repo canonical"
  else
    mark_fail "snapshots identical" "public-fork and sibling-repo onboarding differ"
  fi
fi

# Public-fork copy must be UNTRACKED so future commits don't ship a stale
# divergent snapshot.
if [ -z "$( cd "$SB/public" && git ls-files onboarding.yaml 2>/dev/null )" ]; then
  mark_pass "post-migration: onboarding.yaml untracked in public fork (git rm --cached applied)"
else
  mark_fail "onboarding untracked" "still tracked in public fork"
fi

[ -f "$SB/public/.apexyard-fork" ] \
  && mark_pass "post-migration: .apexyard-fork marker written" \
  || mark_fail "marker written" ".apexyard-fork missing"

ONB_KEY=$(jq -r '.portfolio.onboarding // empty' "$SB/public/.claude/project-config.json")
WS_KEY=$(jq -r '.portfolio.workspace_dir // empty' "$SB/public/.claude/project-config.json")
[ -n "$ONB_KEY" ] && [ -n "$WS_KEY" ] \
  && mark_pass "post-migration: portfolio.{onboarding,workspace_dir} keys added" \
  || mark_fail "config keys added" "onboarding=$ONB_KEY workspace_dir=$WS_KEY"

# Re-detection: V2_NEEDED should now be 0 (migration already done)
if detect_v2_needed "$SB/public"; then
  mark_fail "post-migration detection" "V2_NEEDED=1 after migration (expected 0)"
else
  mark_pass "post-migration: V2_NEEDED=0 (idempotent — won't re-fire)"
fi

# ---------------------------------------------------------------------------
# Case 4: --dry-run on a pre-v2 split → V2_NEEDED=1 but no state change
# ---------------------------------------------------------------------------
echo "== Case 4: --dry-run on pre-v2 split → detection fires, no state change"
SB="$TMP_ROOT/case4"
build_pre_v2_split "$SB"

if detect_v2_needed "$SB/public"; then
  mark_pass "V2_NEEDED=1 on pre-v2 split under --dry-run"
else
  mark_fail "dry-run detection" "V2_NEEDED=0 (expected 1)"
fi

# Snapshot before the dry-run plan would print
SNAP_BEFORE=$(snapshot_state "$SB/public")

# Under --dry-run, SKILL.md § 8a says "print commands the migration would
# run, do not execute, then continue to step 9". Simulate that — print
# the plan to stdout (captured + discarded), perform NO file mutations.
DRY_RUN_OUTPUT=$(
  (
    cd "$SB/public" || exit 1
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-read-config.sh
    # shellcheck source=/dev/null
    . .claude/hooks/_lib-portfolio-paths.sh
    SIBLING_ROOT=$(dirname "$(jq -r '.portfolio.registry' .claude/project-config.json)")
    echo "would: mv onboarding.yaml $SIBLING_ROOT/onboarding.yaml"
    echo "would: mv workspace/* into $SIBLING_ROOT/workspace/"
    echo "would: echo '# v2 anchor' > .apexyard-fork"
    echo "would: append v2 gitignore lines"
    echo "would: jq add portfolio.{onboarding,workspace_dir} to project-config.json"
  )
)

if printf '%s' "$DRY_RUN_OUTPUT" | grep -q "^would: mv onboarding.yaml"; then
  mark_pass "--dry-run prints the migration plan"
else
  mark_fail "dry-run plan" "no 'would:' lines in output"
fi

# Critical: state must NOT have changed under --dry-run
SNAP_AFTER=$(snapshot_state "$SB/public")
if [ "$SNAP_BEFORE" = "$SNAP_AFTER" ]; then
  mark_pass "--dry-run leaves fork state untouched (snapshots identical)"
else
  mark_fail "dry-run no state change" "snapshot changed under --dry-run"
  printf 'BEFORE:\n%s\n\nAFTER:\n%s\n' "$SNAP_BEFORE" "$SNAP_AFTER" >&2
fi

# Step 8a says under --dry-run the skill continues to step 9 without
# mutating — verify onboarding.yaml is still in the public fork AND has
# NOT been copied into the sibling (no `cp` ran under --dry-run).
[ -f "$SB/public/onboarding.yaml" ] \
  && mark_pass "--dry-run: onboarding.yaml still in public fork (no cp ran)" \
  || mark_fail "dry-run onboarding untouched" "file unexpectedly removed"

[ ! -f "$SB/private/onboarding.yaml" ] \
  && mark_pass "--dry-run: onboarding.yaml NOT copied into sibling repo" \
  || mark_fail "dry-run no sibling copy" "sibling onboarding.yaml unexpectedly created"

[ ! -f "$SB/public/.apexyard-fork" ] \
  && mark_pass "--dry-run: .apexyard-fork marker NOT written" \
  || mark_fail "dry-run marker untouched" "marker unexpectedly written"

# ---------------------------------------------------------------------------
# Coexistence with test_split_portfolio_v2_migration.sh
# ---------------------------------------------------------------------------
# This is a contract assertion, not a runtime check: this test focuses on
# DETECTION (which cases trigger the migration); the sibling hooks test
# focuses on MIGRATION BODY (the file moves + idempotence). Verify the
# sibling test file still exists alongside this one — if a future PR
# accidentally deletes it, this assertion catches the regression.
SIBLING_TEST="$ROOT/.claude/hooks/tests/test_split_portfolio_v2_migration.sh"
if [ -f "$SIBLING_TEST" ]; then
  mark_pass "sibling test_split_portfolio_v2_migration.sh coexists (not replaced)"
else
  mark_fail "sibling test coexists" "$SIBLING_TEST is missing — was it removed?"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "===== test_step_8a_wiring.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed cases:%b\n' "$FAILED_CASES"
  exit 1
fi
exit 0
