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
#   15. Installer's OWN _lib-path-resolve.sh missing, target has a
#       deliberate third-party core.hooksPath (#1089, closing #1087's
#       LOW-3 + LOW-2)                                     -> non-zero exit,
#                                                               config UNCHANGED
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

# ---------------------------------------------------------------------------
# CASE 9 (PR #1087 review §2a — kills the _resolve_real_path passthrough
# mutant): core.hooksPath set through a SYMLINK to the repo's own real
# .githooks dir must classify as "correct" (idempotent no-op), not
# "third-party". A mutant that replaces _resolve_real_path's body with a
# bare passthrough (`printf '%s' "$1"`) makes this flip from rc=0
# "idempotent" to rc=1 "refuses" — proven by direct probe during review;
# this case pins the shipped (correct) behaviour so a regression is caught.
# ---------------------------------------------------------------------------
case_symlinked_repo_idempotent() {
  local sandbox; sandbox=$(mktemp -d)
  local repo="$sandbox/repo"
  build_repo "$repo"
  local link="$sandbox/githooks-link"
  ln -s "$repo/.githooks" "$link"
  git -C "$repo" config core.hooksPath "$link"

  local out rc
  out=$(run_installer --repo-dir "$repo"); rc=$?
  assert_eq "symlinked repo idempotent: exit code" "0" "$rc"
  assert_match "symlinked repo idempotent: message says idempotent" "idempotent" "$out"
  assert_eq "symlinked repo idempotent: config UNCHANGED (still the symlink path)" "$link" "$(git -C "$repo" config --get core.hooksPath)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 10 (PR #1087 review §2c — kills the classifier's external-third-party
# fallthrough mutant, the branch guarding this PR's central safety
# property): core.hooksPath pointing at a real, existing directory OUTSIDE
# the repo tree, with no `.git` component in its path — the canonical
# "adopter configured a company-wide shared hooks dir" shape the lib's own
# comment names. Cases 5/6 above only exercise the third-party branch via a
# directory INSIDE the repo (the "$repo_root"/* prefix branch); this one
# exercises the DIFFERENT, final fallthrough branch. A mutant that turns
# that fallthrough into `unset` makes the installer silently CLOBBER this
# deliberate value with no --force — proven during review; this case pins
# the shipped (refuse) behaviour.
# ---------------------------------------------------------------------------
case_external_third_party_no_force() {
  local sandbox; sandbox=$(mktemp -d)
  local repo="$sandbox/repo"
  local external="$sandbox/company-wide-hooks"
  build_repo "$repo"
  mkdir -p "$external"

  git -C "$repo" config core.hooksPath "$external"

  local out rc
  out=$(run_installer --repo-dir "$repo"); rc=$?
  assert_eq "external third-party no --force: exit code" "1" "$rc"
  assert_match "external third-party no --force: message says refusing" "[Rr]efusing to overwrite" "$out"
  assert_eq "external third-party no --force: config UNCHANGED" "$external" "$(git -C "$repo" config --get core.hooksPath)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 11 (PR #1087 review MEDIUM-3): --repo-dir naming a directory that
# exists but is NOT itself a repo root must refuse rather than silently
# walk up and configure the ENCLOSING repo. Reproduced during review via
# workspace/<project> on a partial clone; this sandbox reproduces the
# general shape (a plain subdirectory of a real repo).
# ---------------------------------------------------------------------------
case_repo_dir_retarget_refused() {
  local sandbox; sandbox=$(mktemp -d)
  local outer="$sandbox/outer"
  build_repo "$outer"
  local not_a_repo="$outer/subdir-not-a-repo"
  mkdir -p "$not_a_repo"

  local out rc
  out=$(run_installer --repo-dir "$not_a_repo"); rc=$?
  assert_eq "repo-dir retarget: exit code" "2" "$rc"
  assert_match "repo-dir retarget: message names the enclosing repo" "ENCLOSING repo" "$out"
  assert_eq "repo-dir retarget: outer repo's config UNCHANGED" "" "$(git -C "$outer" config --get core.hooksPath 2>/dev/null || true)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 12 (PR #1087 review LOW-4): --hooks-dir resolving outside the repo
# tree (path traversal) must be refused, not written verbatim.
# ---------------------------------------------------------------------------
case_hooks_dir_traversal_refused() {
  local sandbox; sandbox=$(mktemp -d)
  local repo="$sandbox/repo"
  build_repo "$repo"
  mkdir -p "$sandbox/evil-outside-hooks"

  local out rc
  out=$(run_installer --repo-dir "$repo" --hooks-dir "../evil-outside-hooks"); rc=$?
  assert_eq "hooks-dir traversal: exit code" "2" "$rc"
  assert_match "hooks-dir traversal: message says outside" "outside" "$out"
  assert_eq "hooks-dir traversal: config UNCHANGED" "" "$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 13 (PR #1087 review LOW-5): a tracked hooks dir committed as a
# SYMLINK must be refused, not silently followed.
# ---------------------------------------------------------------------------
case_symlinked_hooks_dir_refused() {
  local sandbox; sandbox=$(mktemp -d)
  local repo="$sandbox/repo"
  local elsewhere="$sandbox/real-hooks-elsewhere"
  mkdir -p "$repo" "$elsewhere"
  ( cd "$repo" && git init -q )
  printf '#!/bin/sh\nexit 0\n' > "$elsewhere/pre-push"
  ln -s "$elsewhere" "$repo/.githooks"
  ( cd "$repo" && git add .githooks && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.com \
      GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.com \
      git commit -q -m "chore: init" )

  local out rc
  out=$(run_installer --repo-dir "$repo"); rc=$?
  assert_eq "symlinked hooks dir: exit code" "2" "$rc"
  assert_match "symlinked hooks dir: message says symlink" "symlink" "$out"
  assert_eq "symlinked hooks dir: config UNCHANGED" "" "$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 14 (PR #1087 review MEDIUM-2): a `git config` write that fails (a
# stale .git/config.lock — routine when several worktree agents run in
# parallel) must fail CLOSED: non-zero exit, no false success message, and
# the config value left exactly as it was. Uses a REAL git lock file, not
# a mock, so this is a genuine end-to-end reproduction of the review's
# finding, not a simulation of one.
# ---------------------------------------------------------------------------
case_config_lock_fails_closed() {
  local sandbox; sandbox=$(mktemp -d)
  local repo="$sandbox/repo"
  build_repo "$repo"

  : > "$repo/.git/config.lock"

  local out rc
  out=$(run_installer --repo-dir "$repo"); rc=$?
  rm -f "$repo/.git/config.lock"

  assert_eq "config.lock fails closed: exit code is 4 (fail-closed), not 0" "4" "$rc"
  if printf '%s' "$out" | grep -qE "core\.hooksPath set to \.githooks.*was unset"; then
    echo "FAIL [config.lock fails closed: must NOT print the success message]" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}config.lock-no-false-success "
  else
    echo "PASS [config.lock fails closed: no false success message]"
    PASS=$((PASS+1))
  fi
  assert_eq "config.lock fails closed: config still unset (write never took)" "" "$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)"

  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# CASE 15 (#1089, closing #1087's LOW-3 + LOW-2): the installer's OWN copy
# of _lib-path-resolve.sh missing (genuine corruption — not the TARGET
# repo's state, which every case above exercises) must NOT clobber a
# deliberate third-party core.hooksPath. Builds a standalone scratch
# "install root" at bin/install-git-hooks.sh + .claude/hooks/
# _lib-git-hooks-path.sh (mirroring the real repo's relative layout so
# $SCRIPT_DIR/../.claude/hooks/... resolves the same way it does for a
# real clone), deliberately WITHOUT .claude/hooks/_lib-path-resolve.sh
# next to it, then runs THAT copy (not $SCRIPT_SRC) against an ordinary
# target repo with a real, existing, external core.hooksPath already set
# — invoked with NO --repo-dir (cwd-based, the /setup call shape) so the
# LOW-4 hooks-dir containment check is what actually resolves
# _resolve_real_path first, matching the exact ordering the "load-bearing
# ordering" comment in bin/install-git-hooks.sh describes. Pins: exit
# non-zero, no false-success message, config UNCHANGED — the LOW-4 check
# refuses before ghp_classify's auto-repair branch is ever reached.
# Discriminating: reordering the LOW-4 check to run AFTER
# `STATE=$(ghp_classify ...)` — the exact regression the ordering comment
# warns against — makes ghp_classify report "missing:<raw>" for this
# real, deliberate third-party value, and the installer would then
# AUTO-REPAIR it with no --force (traced by hand against the shipped
# ghp_classify logic while developing this test; the shipped ordering,
# unmodified, keeps this case green).
# ---------------------------------------------------------------------------
case_installer_own_lib_missing_no_clobber() {
  local sandbox; sandbox=$(mktemp -d)
  local install_root="$sandbox/install-root"
  local repo="$sandbox/repo"
  local external="$sandbox/company-wide-hooks"

  # Standalone install root: bin/install-git-hooks.sh + the one lib it
  # requires ($LIB in the script), WITHOUT _lib-path-resolve.sh.
  mkdir -p "$install_root/bin" "$install_root/.claude/hooks"
  cp "$SCRIPT_SRC" "$install_root/bin/install-git-hooks.sh"
  local repo_root_for_script
  repo_root_for_script="$(cd "$(dirname "$SCRIPT_SRC")/.." && pwd)"
  cp "$repo_root_for_script/.claude/hooks/_lib-git-hooks-path.sh" "$install_root/.claude/hooks/_lib-git-hooks-path.sh"
  # NOTE: _lib-path-resolve.sh intentionally NOT copied into install_root.

  build_repo "$repo"
  mkdir -p "$external"
  git -C "$repo" config core.hooksPath "$external"

  local out rc
  out=$(cd "$repo" && bash "$install_root/bin/install-git-hooks.sh" 2>&1); rc=$?

  if [ "$rc" = "0" ]; then
    echo "FAIL [installer's own lib missing: must NOT report success] — rc=0, out: $out" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}installer-lib-missing-no-false-success "
  else
    echo "PASS [installer's own lib missing: non-zero exit, no false success]"
    PASS=$((PASS+1))
  fi
  assert_eq "installer's own lib missing: deliberate third-party config UNCHANGED" "$external" "$(git -C "$repo" config --get core.hooksPath)"

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
case_symlinked_repo_idempotent
case_external_third_party_no_force
case_repo_dir_retarget_refused
case_hooks_dir_traversal_refused
case_symlinked_hooks_dir_refused
case_config_lock_fails_closed
case_installer_own_lib_missing_no_clobber

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED" >&2
  exit 1
fi
exit 0
