#!/bin/bash
# Smoke tests for .claude/hooks/check-upstream-drift.sh — focused on the
# CHANGELOG-fallback path added by apexyard#106 (AgDR-0008).
#
# Each case:
#   - builds a tiny upstream + fork pair under $TMPDIR
#   - simulates a specific merge mode (squash-merge / merge-commit / no-sync)
#   - runs the hook from the fork's directory
#   - asserts banner output / silence

set -u

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/check-upstream-drift.sh"
PASS=0
FAIL=0
FAILED=""

# Build an upstream with a v1.0.0 release and a v1.1.0 release; both have
# CHANGELOG entries. Returns the upstream repo path.
make_upstream() {
  local up
  up=$(mktemp -d)
  (
    cd "$up" || exit 1
    git init -q -b main
    git config user.email t@t && git config user.name t
    echo "init" > a.txt && git add a.txt && git commit -q -m "init"
    echo "v1.0.0" > a.txt && git commit -q -am "release v1.0.0"
    printf '# Changelog\n\n## [1.0.0]\nfirst release\n' > CHANGELOG.md
    git add CHANGELOG.md && git commit -q -m "v1.0.0 changelog"
    git tag v1.0.0
    echo "v1.1.0 work" >> a.txt && git commit -q -am "v1.1.0 work"
    printf '# Changelog\n\n## [1.1.0] — 2026-04-19\nnew release\n\n## [1.0.0]\nfirst release\n' > CHANGELOG.md
    git add CHANGELOG.md && git commit -q -m "v1.1.0 changelog"
    git tag v1.1.0
  )
  echo "$up"
}

# Clone upstream as a fork, copy the hook in, configure the upstream remote.
make_fork() {
  local up="$1"
  local fk
  fk=$(mktemp -d)/fork
  git clone -q --no-tags "$up" "$fk"
  (
    cd "$fk" || exit 1
    git config user.email t@t && git config user.name t
    git remote add upstream "$up"
    git fetch upstream --tags --quiet
    mkdir -p .claude/hooks .claude/session
    cp "$HOOK_SRC" .claude/hooks/check-upstream-drift.sh
    chmod +x .claude/hooks/check-upstream-drift.sh
  )
  echo "$fk"
}

run_hook_from() {
  local fk="$1"
  ( cd "$fk" || exit 1; bash .claude/hooks/check-upstream-drift.sh 2>&1 )
}

assert() {
  local label="$1" expected_pattern="$2" output="$3"
  if [ -z "$expected_pattern" ]; then
    if [ -z "$output" ]; then
      echo "PASS [$label] — silent"
      PASS=$((PASS+1)); return
    fi
    echo "FAIL [$label] — expected silent, got: $output" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "; return
  fi
  if echo "$output" | grep -qE "$expected_pattern"; then
    echo "PASS [$label]"
    PASS=$((PASS+1)); return
  fi
  echo "FAIL [$label] — expected /$expected_pattern/, got: $output" >&2
  FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "
}

# CASE 1: squash-merge fork at v1.1.0 (the bug scenario from #106)
case_squash_caught_up() {
  local up; up=$(make_upstream)
  local fk; fk=$(make_fork "$up")
  (
    cd "$fk" || exit 1
    git checkout -q main
    git reset --hard HEAD~3 2>/dev/null
    git merge --squash upstream/main >/dev/null 2>&1
    git commit -q -m "chore: squash sync of v1.1.0"
  )
  assert "squash-merge fork caught up to v1.1.0 → silent (FIXED by #106)" "" "$(run_hook_from "$fk")"
  rm -rf "$up" "$(dirname "$fk")"
}

# CASE 2: merge-commit fork at v1.1.0 (existing path — must not regress)
case_merge_commit_caught_up() {
  local up; up=$(make_upstream)
  local fk; fk=$(make_fork "$up")
  (
    cd "$fk" || exit 1
    git checkout -q main
    git reset --hard HEAD~3 2>/dev/null
    git merge --no-edit upstream/main >/dev/null 2>&1
  )
  assert "merge-commit fork caught up to v1.1.0 → silent" "" "$(run_hook_from "$fk")"
  rm -rf "$up" "$(dirname "$fk")"
}

# CASE 3: fork genuinely behind (no v1.1.0 in CHANGELOG) — banner must fire
case_genuinely_behind() {
  local up; up=$(make_upstream)
  local fk; fk=$(make_fork "$up")
  (
    cd "$fk" || exit 1
    git checkout -q main
    git reset --hard v1.0.0 2>/dev/null
  )
  assert "fork stopped at v1.0.0 → banner fires" "v1.1.0 available" "$(run_hook_from "$fk")"
  rm -rf "$up" "$(dirname "$fk")"
}

# CASE 4: fork has its own newer tag than upstream — silent (not our business)
case_fork_ahead() {
  local up; up=$(make_upstream)
  local fk; fk=$(make_fork "$up")
  (
    cd "$fk" || exit 1
    git checkout -q main
    # Fork merges v1.1.0 cleanly first
    git reset --hard HEAD~3 2>/dev/null
    git merge --no-edit upstream/main >/dev/null 2>&1
    # Then tags its own v2.0.0-acme
    git tag v2.0.0-acme
  )
  assert "fork has its own newer tag → silent" "" "$(run_hook_from "$fk")"
  rm -rf "$up" "$(dirname "$fk")"
}

# CASE 5: squash-merge with NO CHANGELOG entry on fork main (e.g. fork forked
# pre-CHANGELOG, then squash-merged a release without absorbing the file).
# Banner SHOULD fire — fallback fails open, primary tag check fails, so we
# correctly nag.
case_squash_no_changelog() {
  local up; up=$(make_upstream)
  local fk; fk=$(make_fork "$up")
  (
    cd "$fk" || exit 1
    git checkout -q main
    git reset --hard HEAD~3 2>/dev/null
    # Squash-merge but immediately blow away CHANGELOG.md (simulate a fork that
    # doesn't keep the file). The release content is "absorbed" only via the
    # source code, not the changelog.
    git merge --squash upstream/main >/dev/null 2>&1
    rm -f CHANGELOG.md && git add -A && git commit -q -m "chore: squash sync, no CHANGELOG"
  )
  assert "squash-merge but no CHANGELOG on fork → banner fires (no false silence)" "v1.1.0 available" "$(run_hook_from "$fk")"
  rm -rf "$up" "$(dirname "$fk")"
}

case_squash_caught_up
case_merge_commit_caught_up
case_genuinely_behind
case_fork_ahead
case_squash_no_changelog

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED" >&2
  exit 1
fi
exit 0
