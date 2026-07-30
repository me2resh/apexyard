#!/bin/bash
# Smoke tests for bin/install-git-hooks.sh (me2resh/apexyard#1086 step 1).
#
# Each case builds an isolated sandbox git repo under $TMPDIR, puts
# core.hooksPath into a specific starting state, runs the installer against
# it via --repo-dir, and asserts both the stdout/stderr message shape AND
# the exit code AND the resulting `git config --get core.hooksPath` value.
#
# Discriminating by construction: bin/install-git-hooks.sh did not exist
# before me2resh/apexyard#1086 step 1, so every case here fails against the
# pre-change tree (the script is simply absent — `bash: no such file`) and
# passes only once the script exists with the exact branching this suite
# exercises. Cases 3-6 additionally verify the four-way state-classification
# logic in _lib-git-hooks-path.sh (unset / correct / missing / foreign-git-dir
# / third-party) is actually reached, not just that *some* path succeeds.
#
# Cases covered:
#   1. Fresh clone (core.hooksPath unset)                  -> sets it, exit 0
#   2. Already correct (idempotent re-run)                 -> no-op, exit 0
#   3. Stale: core.hooksPath points at a non-existent dir   -> repaired, exit 0
#   4. Stale: core.hooksPath points at a DIFFERENT clone's
#      .git/hooks (the concrete #1086 failure mode)         -> repaired, exit 0
#   5. Deliberate third-party real directory, no --force    -> refused, exit 1,
#                                                               config UNCHANGED
#   6. Deliberate third-party real directory, WITH --force  -> overwritten, exit 0
#   7. --repo-dir target is not a git repository at all     -> exit 2, loud error
#   8. Target repo has no tracked hooks dir to install       -> exit 3, config
#                                                               UNCHANGED
#
# Exit 0 if all cases pass; 1 on first failure tally.

set -u

SCRIPT_SRC="$(cd "$(dirname "$0")/../../.." && pwd)/bin/install-git-hooks.sh"
PASS=0
FAIL=0
FAILED=""

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label] — expected '$expected', got '$actual'" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "
  fi
}

assert_match() {
  local label="$1" pattern="$2" actual="$3"
  if printf '%s' "$actual" | grep -qE "$pattern"; then
    echo "PASS [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label] — expected to match /$pattern/, got: $actual" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "
  fi
}

# Build a tiny standalone git repo at $1 with a tracked .githooks/pre-push.
build_repo() {
  local dir="$1"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q )
  mkdir -p "$dir/.githooks"
  printf '#!/bin/sh\nexit 0\n' > "$dir/.githooks/pre-push"
  ( cd "$dir" && git add .githooks && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.com \
      GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.com \
      git commit -q -m "chore: init" )
}

run_installer() {
  bash "$SCRIPT_SRC" "$@" 2>&1
}

# ---------------------------------------------------------------------------
# CASE 1: fresh clone (unset) -> sets it, exit 0
# ---------------------------------------------------------------------------
case_fresh_unset() {
  local sandbox; sandbox=$(mktemp -d)
  local repo="$sandbox/repo"
  build_repo "$repo"

  local out rc
  out=$(run_installer --repo-dir "$repo"); rc=$?
  assert_eq "fresh unset: exit code" "0" "$rc"
  assert_match "fresh unset: message" "set to \.githooks.*was unset" "$out"
  assert_eq "fresh unset: config value" ".githooks" "$(git -C "$repo" config --get core.hooksPath)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 2: already correct -> no-op, exit 0, message says idempotent
# ---------------------------------------------------------------------------
case_idempotent() {
  local sandbox; sandbox=$(mktemp -d)
  local repo="$sandbox/repo"
  build_repo "$repo"
  git -C "$repo" config core.hooksPath .githooks

  local out rc
  out=$(run_installer --repo-dir "$repo"); rc=$?
  assert_eq "idempotent: exit code" "0" "$rc"
  assert_match "idempotent: message says no change" "idempotent" "$out"
  assert_eq "idempotent: config value unchanged" ".githooks" "$(git -C "$repo" config --get core.hooksPath)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 3: core.hooksPath points at a directory that doesn't exist -> repaired
# ---------------------------------------------------------------------------
case_stale_missing_dir() {
  local sandbox; sandbox=$(mktemp -d)
  local repo="$sandbox/repo"
  build_repo "$repo"
  git -C "$repo" config core.hooksPath "$sandbox/this-does-not-exist"

  local out rc
  out=$(run_installer --repo-dir "$repo"); rc=$?
  assert_eq "stale missing dir: exit code" "0" "$rc"
  assert_match "stale missing dir: message says repaired" "repaired.*non-existent directory" "$out"
  assert_eq "stale missing dir: config now correct" ".githooks" "$(git -C "$repo" config --get core.hooksPath)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 4: core.hooksPath points at a DIFFERENT clone's .git/hooks — the
# concrete failure mode #1086 was filed against.
# ---------------------------------------------------------------------------
case_stale_foreign_clone() {
  local sandbox; sandbox=$(mktemp -d)
  local repo="$sandbox/repo"
  local other="$sandbox/other-clone"
  build_repo "$repo"
  build_repo "$other"

  local other_git_dir
  other_git_dir=$(cd "$other" && git rev-parse --git-dir)
  case "$other_git_dir" in
    /*) : ;;
    *) other_git_dir="$other/$other_git_dir" ;;
  esac
  git -C "$repo" config core.hooksPath "$other_git_dir/hooks"

  local out rc
  out=$(run_installer --repo-dir "$repo"); rc=$?
  assert_eq "stale foreign clone: exit code" "0" "$rc"
  assert_match "stale foreign clone: message says repaired + different clone" "repaired.*different clone" "$out"
  assert_eq "stale foreign clone: config now correct" ".githooks" "$(git -C "$repo" config --get core.hooksPath)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 5: a real, existing, different directory the adopter configured on
# purpose -> refused without --force, exit 1, config left untouched.
# ---------------------------------------------------------------------------
case_third_party_no_force() {
  local sandbox; sandbox=$(mktemp -d)
  local repo="$sandbox/repo"
  build_repo "$repo"
  mkdir -p "$repo/custom-hooks-dir"
  git -C "$repo" config core.hooksPath custom-hooks-dir

  local out rc
  out=$(run_installer --repo-dir "$repo"); rc=$?
  assert_eq "third-party no --force: exit code" "1" "$rc"
  assert_match "third-party no --force: message says refusing" "[Rr]efusing to overwrite" "$out"
  assert_eq "third-party no --force: config UNCHANGED" "custom-hooks-dir" "$(git -C "$repo" config --get core.hooksPath)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 6: same as case 5, but with --force -> overwritten, exit 0
# ---------------------------------------------------------------------------
case_third_party_with_force() {
  local sandbox; sandbox=$(mktemp -d)
  local repo="$sandbox/repo"
  build_repo "$repo"
  mkdir -p "$repo/custom-hooks-dir"
  git -C "$repo" config core.hooksPath custom-hooks-dir

  local out rc
  out=$(run_installer --repo-dir "$repo" --force); rc=$?
  assert_eq "third-party --force: exit code" "0" "$rc"
  assert_match "third-party --force: message says overwritten" "overwritten" "$out"
  assert_eq "third-party --force: config now correct" ".githooks" "$(git -C "$repo" config --get core.hooksPath)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 7: --repo-dir target is not a git repository at all -> loud error, exit 2
# ---------------------------------------------------------------------------
case_not_a_git_repo() {
  local sandbox; sandbox=$(mktemp -d)
  local plain="$sandbox/not-a-repo"
  mkdir -p "$plain"

  local out rc
  out=$(run_installer --repo-dir "$plain"); rc=$?
  assert_eq "not a git repo: exit code" "2" "$rc"
  assert_match "not a git repo: message" "not inside a git repository" "$out"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 8: target repo has no tracked .githooks/ dir -> exit 3, nothing changed
# ---------------------------------------------------------------------------
case_no_hooks_dir() {
  local sandbox; sandbox=$(mktemp -d)
  local repo="$sandbox/repo"
  mkdir -p "$repo"
  ( cd "$repo" && git init -q )
  printf 'x' > "$repo/README.md"
  ( cd "$repo" && git add README.md && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.com \
      GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.com \
      git commit -q -m "chore: init" )

  local out rc
  out=$(run_installer --repo-dir "$repo"); rc=$?
  assert_eq "no hooks dir: exit code" "3" "$rc"
  assert_match "no hooks dir: message" "nothing to install" "$out"
  assert_eq "no hooks dir: config still unset" "" "$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)"

  rm -rf "$sandbox"
}

if [ ! -f "$SCRIPT_SRC" ]; then
  echo "FAIL: bin/install-git-hooks.sh not found at $SCRIPT_SRC" >&2
  exit 1
fi

case_fresh_unset
case_idempotent
case_stale_missing_dir
case_stale_foreign_clone
case_third_party_no_force
case_third_party_with_force
case_not_a_git_repo
case_no_hooks_dir

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED" >&2
  exit 1
fi
exit 0
