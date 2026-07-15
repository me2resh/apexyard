#!/bin/bash
# Smoke tests for .claude/hooks/print-portfolio-primer.sh (me2resh/apexyard#900)
#
# Each case builds an isolated sandbox git repo under $TMPDIR, drops the
# hook + its shared libs (_lib-ops-root.sh, _lib-read-config.sh,
# _lib-portfolio-paths.sh, project-config.defaults.json) into it, then
# asserts the hook's banner / silence behavior:
#
#   1. split-portfolio v2 (marker + sibling-pointing portfolio block)
#      → banner fires, naming all four absolute paths
#   2. single-fork mode (no .apexyard-fork marker at all)
#      → silent
#   3. marker present but portfolio block still resolves in-fork
#      (single-fork adopter who merely carries the v2 marker)
#      → silent
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/print-portfolio-primer.sh"
LIB_OPS="$SRC_ROOT/.claude/hooks/_lib-ops-root.sh"
LIB_PORT="$SRC_ROOT/.claude/hooks/_lib-portfolio-paths.sh"
LIB_CFG="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"

for f in "$HOOK_SRC" "$LIB_OPS" "$LIB_PORT" "$LIB_CFG" "$DEFAULTS"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED=""

mark_pass() { echo "PASS [$1]"; PASS=$((PASS+1)); }
mark_fail() { echo "FAIL [$1] — $2" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}${1}; "; }

assert_silent() {
  local label="$1" output="$2"
  if [ -z "$output" ]; then
    mark_pass "$label"
  else
    mark_fail "$label" "expected silent, got: $output"
  fi
}

assert_contains_all() {
  local label="$1" output="$2"; shift 2
  local missing=""
  for pattern in "$@"; do
    if ! printf '%s' "$output" | grep -qF -- "$pattern"; then
      missing="${missing}[$pattern] "
    fi
  done
  if [ -z "$missing" ]; then
    mark_pass "$label"
  else
    mark_fail "$label" "missing patterns: $missing — got: $output"
  fi
}

# ---------------------------------------------------------------------------
# make_public_fork_base: build a public-fork-shaped sandbox with the hook +
# shared libs copied in and initialised as a git repo. No portfolio config
# or marker yet — callers add those per-case.
# ---------------------------------------------------------------------------
make_public_fork_base() {
  local sb
  sb=$(mktemp -d)
  sb=$(cd "$sb" && pwd -P)
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOK_SRC" "$sb/.claude/hooks/print-portfolio-primer.sh"
  cp "$LIB_OPS" "$sb/.claude/hooks/_lib-ops-root.sh"
  cp "$LIB_PORT" "$sb/.claude/hooks/_lib-portfolio-paths.sh"
  cp "$LIB_CFG" "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$DEFAULTS" "$sb/.claude/project-config.defaults.json"
  chmod +x "$sb/.claude/hooks/print-portfolio-primer.sh"
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    git add -A
    git commit -q -m "fixture: base fork"
  )
  echo "$sb"
}

run_hook_from() {
  local dir="$1"
  ( cd "$dir" || exit 1; APEXYARD_OPS_DISABLE_PIN=1 bash .claude/hooks/print-portfolio-primer.sh 2>&1 )
}

# ---------------------------------------------------------------------------
# CASE 1: split-portfolio v2 — marker present, portfolio block points at a
# sibling repo. Banner must fire and name all four absolute paths.
# ---------------------------------------------------------------------------
case_split_v2_prints_paths() {
  local pub priv
  pub=$(make_public_fork_base)
  priv=$(mktemp -d); priv=$(cd "$priv" && pwd -P)/acme-portfolio
  mkdir -p "$priv/projects" "$priv/workspace"
  cat > "$priv/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: demo
    repo: example/demo
YAML
  echo "# Ideas" > "$priv/projects/ideas-backlog.md"
  echo "company: {name: Acme}" > "$priv/onboarding.yaml"

  (
    cd "$pub" || exit 1
    echo "# v2 marker" > .apexyard-fork
    cat > .claude/project-config.json <<JSON
{
  "portfolio": {
    "registry": "$priv/apexyard.projects.yaml",
    "projects_dir": "$priv/projects",
    "ideas_backlog": "$priv/projects/ideas-backlog.md",
    "onboarding": "$priv/onboarding.yaml",
    "workspace_dir": "$priv/workspace"
  }
}
JSON
    git add -A
    git commit -q -m "fixture: split-portfolio v2 config"
  )

  local out
  out=$(run_hook_from "$pub")
  assert_contains_all "split-portfolio v2 prints all four absolute paths" "$out" \
    "$pub" \
    "$priv" \
    "$priv/workspace" \
    "$priv/apexyard.projects.yaml"

  rm -rf "$pub" "$(dirname "$priv")"
}

# ---------------------------------------------------------------------------
# CASE 2: single-fork mode — no .apexyard-fork marker at all, no portfolio
# override. Must stay silent.
# ---------------------------------------------------------------------------
case_single_fork_silent() {
  local sb
  sb=$(make_public_fork_base)
  # Legacy v1 anchor so the ops-root resolver still finds a root, but no
  # .apexyard-fork marker and no portfolio config override.
  (
    cd "$sb" || exit 1
    touch onboarding.yaml
    cat > apexyard.projects.yaml <<'YAML'
version: 1
projects: []
YAML
    git add -A
    git commit -q -m "fixture: single-fork v1 anchor"
  )

  assert_silent "single-fork mode (no v2 marker) → silent" "$(run_hook_from "$sb")"
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# CASE 3: marker present but every portfolio path still resolves in-fork
# (a single-fork adopter who has the v2 marker from /setup but never split
# out a sibling repo). Must stay silent — marker alone is not sufficient.
# ---------------------------------------------------------------------------
case_marker_without_split_silent() {
  local sb
  sb=$(make_public_fork_base)
  (
    cd "$sb" || exit 1
    echo "# v2 marker, single-fork adopter" > .apexyard-fork
    mkdir -p projects
    cat > apexyard.projects.yaml <<'YAML'
version: 1
projects: []
YAML
    echo "# Ideas" > projects/ideas-backlog.md
    touch onboarding.yaml
    # No .claude/project-config.json override at all — every portfolio.*
    # path resolves to its in-fork default.
    git add -A
    git commit -q -m "fixture: v2 marker, no sibling split"
  )

  assert_silent "v2 marker present but no sibling split → silent" "$(run_hook_from "$sb")"
  rm -rf "$sb"
}

case_split_v2_prints_paths
case_single_fork_silent
case_marker_without_split_silent

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED" >&2
  exit 1
fi
exit 0
