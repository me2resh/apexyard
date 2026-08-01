#!/bin/bash
# Smoke tests for .claude/hooks/check-git-hooks-installed.sh — SessionStart
# advisory that warns when this clone's core.hooksPath is unset, stale, or
# pointing at a foreign clone (me2resh/apexyard#1086 step 1).
#
# Discriminating by construction: this hook (and the _lib-git-hooks-path.sh
# lib it sources) did not exist before #1086 step 1, so every case here
# fails against the pre-change tree and passes only once both files exist
# with the exact behaviour this suite exercises.
#
# Each case builds an isolated sandbox git repo, sets core.hooksPath to a
# specific state, runs the hook from inside that repo, and asserts banner
# output / silence. Same harness shape as test_check_jq_installed.sh.
#
# Cases covered:
#   1. core.hooksPath unset               -> banner fires
#   2. core.hooksPath already correct     -> silent
#   3. core.hooksPath points at a missing dir           -> banner fires
#   4. core.hooksPath points at a different clone's
#      .git/hooks (the concrete #1086 failure mode)      -> banner fires
#   5. No tracked .githooks/ dir in the repo at all      -> silent (nothing
#      to advise on — a managed-project clone that hasn't adopted the
#      framework's git hooks yet)
#   6b. _lib-path-resolve.sh missing, core.hooksPath already correct
#      (#1089, closing #1087's LOW-2)                     -> banner STILL
#      fires (fails toward over-warning, never silently passes)
#   6. Not inside a git repo at all                       -> silent
#
# Exit 0 if all cases pass; 1 on first failure tally.

set -u

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/check-git-hooks-installed.sh"
LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-git-hooks-path.sh"
LIB_PATH_RESOLVE_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-path-resolve.sh"
# me2resh/apexyard#1102 / AgDR-0118: _lib-git-hooks-path.sh's self-location
# now sources _lib-ops-root.sh (via the shared resolve_anchored_lib_dir
# guard) before it can reach _lib-path-resolve.sh — every sandbox that
# ships the git-hooks-path lib must ship this too, or the bootstrap never
# gets far enough to hit the (correctly tested) missing-path-resolve case.
LIB_OPS_ROOT_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-ops-root.sh"
PASS=0
FAIL=0
FAILED=""

assert_silent() {
  local label="$1" output="$2"
  if [ -z "$output" ]; then
    echo "PASS [$label] — silent"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label] — expected silent, got: $output" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "
  fi
}

assert_fires() {
  local label="$1" pattern="$2" output="$3"
  if [ -n "$output" ] && printf '%s' "$output" | grep -qE "$pattern"; then
    echo "PASS [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label] — expected /$pattern/, got: $output" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "
  fi
}

# Build a sandbox with a copy of the hook + lib, so the test doesn't depend
# on the real ops fork's checked-out state.
build_repo() {
  local dir="$1"
  mkdir -p "$dir/.claude/hooks"
  cp "$HOOK_SRC" "$dir/.claude/hooks/check-git-hooks-installed.sh"
  chmod +x "$dir/.claude/hooks/check-git-hooks-installed.sh"
  if [ -f "$LIB_SRC" ]; then
    cp "$LIB_SRC" "$dir/.claude/hooks/_lib-git-hooks-path.sh"
  fi
  if [ -f "$LIB_PATH_RESOLVE_SRC" ]; then
    cp "$LIB_PATH_RESOLVE_SRC" "$dir/.claude/hooks/_lib-path-resolve.sh"
  fi
  if [ -f "$LIB_OPS_ROOT_SRC" ]; then
    cp "$LIB_OPS_ROOT_SRC" "$dir/.claude/hooks/_lib-ops-root.sh"
  fi
  ( cd "$dir" && git init -q )
}

add_githooks() {
  local dir="$1"
  mkdir -p "$dir/.githooks"
  printf '#!/bin/sh\nexit 0\n' > "$dir/.githooks/pre-push"
  ( cd "$dir" && git add .githooks .claude && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.com \
      GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.com \
      git commit -q -m "chore: init" )
}

run_hook_from() {
  local dir="$1"
  ( cd "$dir" && bash .claude/hooks/check-git-hooks-installed.sh 2>&1 )
}

if [ ! -f "$HOOK_SRC" ]; then
  echo "FAIL: hook not found at $HOOK_SRC" >&2
  exit 1
fi

# CASE 1: unset -> banner
case_unset() {
  local sandbox; sandbox=$(mktemp -d)
  build_repo "$sandbox"
  add_githooks "$sandbox"
  assert_fires "unset -> banner fires" "core\.hooksPath is unset" "$(run_hook_from "$sandbox")"
  rm -rf "$sandbox"
}

# CASE 2: already correct -> silent
case_correct() {
  local sandbox; sandbox=$(mktemp -d)
  build_repo "$sandbox"
  add_githooks "$sandbox"
  git -C "$sandbox" config core.hooksPath .githooks
  assert_silent "already correct -> silent" "$(run_hook_from "$sandbox")"
  rm -rf "$sandbox"
}

# CASE 3: missing dir -> banner
case_missing_dir() {
  local sandbox; sandbox=$(mktemp -d)
  build_repo "$sandbox"
  add_githooks "$sandbox"
  git -C "$sandbox" config core.hooksPath "$sandbox/nope-not-here"
  assert_fires "missing dir -> banner fires" "doesn't exist" "$(run_hook_from "$sandbox")"
  rm -rf "$sandbox"
}

# CASE 4: foreign clone's .git/hooks -> banner
# repo and other-clone are SIBLINGS (both directly under $parent), not
# nested — nesting them would make other-clone's path resolve as "inside
# repo's own tree" and get classified as third-party instead of
# foreign-git-dir, which is a different code path this case must exercise.
case_foreign_clone() {
  local parent; parent=$(mktemp -d)
  local repo="$parent/repo"
  local other="$parent/other-clone"
  build_repo "$repo"
  add_githooks "$repo"
  build_repo "$other"
  add_githooks "$other"

  local other_git_dir
  other_git_dir=$(cd "$other" && git rev-parse --git-dir)
  case "$other_git_dir" in
    /*) : ;;
    *) other_git_dir="$other/$other_git_dir" ;;
  esac
  git -C "$repo" config core.hooksPath "$other_git_dir/hooks"

  assert_fires "foreign clone -> banner fires" "different clone" "$(run_hook_from "$repo")"
  rm -rf "$parent"
}

# CASE 4b (PR #1087 review §2b + LOW-6 — the third-party branch had ZERO
# coverage; deleting it outright still passed the suite 6/6). A real,
# existing directory OUTSIDE the repo with no `.git` component (the
# canonical "adopter configured a shared hooks dir" shape) must fire the
# banner, AND the banner must NOT recommend --force (LOW-6: a banner that
# suggests overriding a deliberate choice erodes the one guard protecting
# it — dropped in favour of pointing at --help).
case_third_party() {
  local parent; parent=$(mktemp -d)
  local repo="$parent/repo"
  local external="$parent/company-wide-hooks"
  build_repo "$repo"
  add_githooks "$repo"
  mkdir -p "$external"
  git -C "$repo" config core.hooksPath "$external"

  local out
  out=$(run_hook_from "$repo")
  assert_fires "third-party -> banner fires" "isn't this" "$out"
  if printf '%s' "$out" | grep -qE -- '--force'; then
    echo "FAIL [third-party banner must NOT recommend --force] — got: $out" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}third-party-no-force-mention "
  else
    echo "PASS [third-party banner must NOT recommend --force]"
    PASS=$((PASS+1))
  fi
  rm -rf "$parent"
}

# CASE 5: no tracked .githooks/ at all -> silent
case_no_githooks_dir() {
  local sandbox; sandbox=$(mktemp -d)
  build_repo "$sandbox"
  # Commit without adding .githooks/ — the repo has .claude/hooks but no
  # tracked pre-push hooks dir of its own.
  ( cd "$sandbox" && git add .claude && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.com \
      GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.com \
      git commit -q -m "chore: init" )
  assert_silent "no .githooks/ -> silent" "$(run_hook_from "$sandbox")"
  rm -rf "$sandbox"
}

# CASE 6b (#1089, closing #1087's LOW-2): _lib-path-resolve.sh missing —
# the deliberate degrade must fail TOWARD over-warning, never silently
# pass. With core.hooksPath already CORRECTLY configured but the resolver
# unavailable, _resolve_real_path's stand-in echoes nothing for both the
# target and the current value, so ghp_classify can no longer confirm they
# match and reports "missing" instead of "correct" — the advisory banner
# fires with a spurious nudge on a clone that's actually fine. Annoying,
# but the safe direction: staying silent here would risk masking a
# genuinely broken clone the next time this exact code path is hit for
# real. Discriminating: a hypothetical "fix" that made the stand-in return
# some non-empty placeholder instead of empty could make this classify as
# "correct" and go silent — this case would catch that regression.
case_correct_but_pathresolve_missing() {
  local sandbox; sandbox=$(mktemp -d)
  # Build the repo WITHOUT copying _lib-path-resolve.sh (build_repo copies
  # it conditionally; skip straight to the pieces we DO want).
  mkdir -p "$sandbox/.claude/hooks"
  cp "$HOOK_SRC" "$sandbox/.claude/hooks/check-git-hooks-installed.sh"
  chmod +x "$sandbox/.claude/hooks/check-git-hooks-installed.sh"
  cp "$LIB_SRC" "$sandbox/.claude/hooks/_lib-git-hooks-path.sh"
  [ -f "$LIB_OPS_ROOT_SRC" ] && cp "$LIB_OPS_ROOT_SRC" "$sandbox/.claude/hooks/_lib-ops-root.sh"
  # NOTE: _lib-path-resolve.sh intentionally NOT copied here.
  ( cd "$sandbox" && git init -q )
  add_githooks "$sandbox"
  git -C "$sandbox" config core.hooksPath .githooks
  assert_fires "lib missing + already correct -> still banners (fail toward over-warn)" "doesn't exist" "$(run_hook_from "$sandbox")"
  rm -rf "$sandbox"
}

# CASE 6: not inside a git repo -> silent
case_not_a_repo() {
  local outside; outside=$(mktemp -d)
  mkdir -p "$outside/.claude/hooks"
  cp "$HOOK_SRC" "$outside/.claude/hooks/check-git-hooks-installed.sh"
  chmod +x "$outside/.claude/hooks/check-git-hooks-installed.sh"
  [ -f "$LIB_SRC" ] && cp "$LIB_SRC" "$outside/.claude/hooks/_lib-git-hooks-path.sh"
  [ -f "$LIB_PATH_RESOLVE_SRC" ] && cp "$LIB_PATH_RESOLVE_SRC" "$outside/.claude/hooks/_lib-path-resolve.sh"
  [ -f "$LIB_OPS_ROOT_SRC" ] && cp "$LIB_OPS_ROOT_SRC" "$outside/.claude/hooks/_lib-ops-root.sh"
  assert_silent "not a git repo -> silent" "$(run_hook_from "$outside")"
  rm -rf "$outside"
}

case_unset
case_correct
case_missing_dir
case_foreign_clone
case_third_party
case_no_githooks_dir
case_correct_but_pathresolve_missing
case_not_a_repo

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED" >&2
  exit 1
fi
exit 0
