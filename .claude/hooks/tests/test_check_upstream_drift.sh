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
GENERATOR_SRC="$(cd "$(dirname "$0")/../../.." && pwd)/bin/sync-codex-adapter.sh"
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

# CASE 6: an installed pre-manifest Codex adapter has drifted (new framework
# skills landed). The SessionStart hook must WARN about the drift but must
# NEVER mutate the tree itself — reconciliation is owned exclusively by an
# explicit `/update` or a manual `--reconcile-installed` run.
case_codex_bootstrap_warns_without_mutating() {
  local up; up=$(make_upstream)
  local fk; fk=$(make_fork "$up")
  (
    cd "$fk" || exit 1
    mkdir -p bin .claude/skills/status .claude/agents
    cp "$GENERATOR_SRC" bin/sync-codex-adapter.sh
    printf '%s\n' '{"hooks":{}}' > .claude/settings.json
    printf '%s\n' '# old status skill' > .claude/skills/status/SKILL.md
    bash bin/sync-codex-adapter.sh >/dev/null
    rm .codex/apexyard-adapter.json
    mkdir -p .claude/skills/tutorial
    printf '%s\n' '# newly synced tutorial skill' > .claude/skills/tutorial/SKILL.md
  )
  local output
  output=$(run_hook_from "$fk")
  if echo "$output" | grep -q 'Codex adapter may be stale' \
    && [ ! -e "$fk/.codex/apexyard-adapter.json" ] \
    && [ ! -e "$fk/.agents/skills/tutorial" ]; then
    echo "PASS [SessionStart warns on Codex adapter drift without mutating the tree]"
    PASS=$((PASS+1))
  else
    echo "FAIL [SessionStart warns on Codex adapter drift without mutating the tree]" >&2
    echo "  output=$output" >&2
    echo "  manifest exists=$([ -e "$fk/.codex/apexyard-adapter.json" ] && echo yes || echo no)" >&2
    echo "  tutorial skill copied=$([ -e "$fk/.agents/skills/tutorial" ] && echo yes || echo no)" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}codex-bootstrap "
  fi
  rm -rf "$up" "$(dirname "$fk")"
}

# CASE 7: carrying the checker without a detected installation must not
# create Codex-specific files for another harness, and must stay silent.
case_codex_bootstrap_uninstalled_noop() {
  local up; up=$(make_upstream)
  local fk; fk=$(make_fork "$up")
  (
    cd "$fk" || exit 1
    mkdir -p bin
    cp "$GENERATOR_SRC" bin/sync-codex-adapter.sh
  )
  run_hook_from "$fk" >/tmp/_upstream_drift_codex_uninstalled.out
  if [ ! -e "$fk/.agents" ] && [ ! -e "$fk/.codex" ]; then
    echo "PASS [SessionStart leaves an uninstalled Codex adapter absent]"
    PASS=$((PASS+1))
  else
    echo "FAIL [SessionStart leaves an uninstalled Codex adapter absent]" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}codex-uninstalled "
  fi
  rm -rf "$up" "$(dirname "$fk")"
}

# CASE 8: a failure inside the staleness check itself is visible but
# advisory. The session hook must still return zero and must not mutate.
case_codex_bootstrap_failure_warns_without_blocking() {
  local up; up=$(make_upstream)
  local fk; fk=$(make_fork "$up")
  (
    cd "$fk" || exit 1
    mkdir -p bin .agents/skills .codex/agents
    printf '%s\n' '{}' > .codex/hooks.json
    cat > bin/sync-codex-adapter.sh <<'SH'
#!/bin/bash
echo "synthetic reconciliation failure" >&2
exit 7
SH
    chmod +x bin/sync-codex-adapter.sh
  )
  local output rc
  output=$(run_hook_from "$fk")
  rc=$?
  if [ "$rc" -eq 0 ] \
    && echo "$output" | grep -q 'Codex adapter may be stale' \
    && echo "$output" | grep -q 'synthetic reconciliation failure' \
    && [ ! -e "$fk/.codex/apexyard-adapter.json" ]; then
    echo "PASS [SessionStart warns without blocking or mutating on check failure]"
    PASS=$((PASS+1))
  else
    echo "FAIL [SessionStart warns without blocking or mutating on check failure] rc=$rc output=$output" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}codex-failure "
  fi
  rm -rf "$up" "$(dirname "$fk")"
}

case_squash_caught_up
case_merge_commit_caught_up
case_genuinely_behind
case_fork_ahead
case_squash_no_changelog
case_codex_bootstrap_warns_without_mutating
case_codex_bootstrap_uninstalled_noop
case_codex_bootstrap_failure_warns_without_blocking

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED" >&2
  exit 1
fi
exit 0
