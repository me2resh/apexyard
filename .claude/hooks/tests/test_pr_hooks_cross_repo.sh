#!/bin/bash
# Tests for the cross-repo false-positive fix (me2resh/apexyard#464).
#
# WHAT IS BEING TESTED
# --------------------
# Two PreToolUse hooks (`require-agdr-for-arch-pr.sh` and
# `validate-pr-create.sh`) previously resolved the session-pinned ops-fork
# for both their git diff and tracker lookups, regardless of what repo the
# `gh pr create` command was actually targeting. This produced false-positive
# blocks for PRs that targeted a sibling repo (e.g. me2resh/apexyard-premium):
#
#  1. require-agdr-for-arch-pr.sh — diffed the ops-fork tree, which includes
#     framework paths (.claude/hooks/, topologies/, handbooks/domain/) that are
#     not present in the premium PR. Blocked even with a valid AgDR.
#
#  2. validate-pr-create.sh — consulted me2resh/apexyard (the ops-fork's
#     upstream remote) as an additional ticket-existence fallback even when the
#     PR was for me2resh/apexyard-premium. A premium ticket could collide with a
#     closed/missing framework issue and get blocked.
#
# STRUCTURE
# ---------
# Each test builds two isolated sandboxes:
#   (a) ops-fork sandbox — a git repo whose origin is me2resh/apexyard (or any
#       fork of it) with an `upstream` remote pointing at me2resh/apexyard.
#       This is the "session-pinned" repo. The hook runs from here.
#   (b) diff content — we simulate the PR's cwd-independent git diff by setting
#       up changed files in the ops-fork. For require-agdr tests, the diff seen
#       by the hook is always the ops-fork diff, so the cross-repo guard must
#       fire BEFORE the diff runs. For validate-pr tests, the tracker lookup
#       is what needs to target the right repo.
#
# The fix adds:
#   - _lib-pr-repo.sh:  `pr_repo_matches_cwd` helper
#   - require-agdr-for-arch-pr.sh: exits 0 early when PR targets a different repo
#   - validate-pr-create.sh: suppresses the `upstream` fallback when CMD_REPO is
#     set and doesn't match the current origin or its upstream
#
# COVERAGE
# --------
#   A. require-agdr-for-arch-pr.sh
#      A1. --repo sibling (non-matching): arch paths present in ops-fork diff →
#          PASS (cross-repo guard fires, no false-block)
#      A2. --repo matches ops-fork origin: arch paths present → BLOCK (no AgDR)
#          [regression: framework PR still gated]
#      A3. --repo matches ops-fork origin, body has AgDR → PASS
#          [regression: framework PR with AgDR still passes]
#      A4. No --repo flag (implicit same-repo): arch paths present → BLOCK
#          [regression: implicit-origin PR still gated]
#      A5. --repo=VALUE (equals form): sibling → PASS (cross-repo guard fires)
#          [F1: equals form was previously un-parsed → guard skipped → false-block]
#      A6. -R VALUE (short alias, space): sibling → PASS
#          [F1: short alias was previously un-parsed]
#      A7. -R=VALUE (short alias, equals): sibling → PASS
#          [F1: short alias+equals was previously un-parsed]
#
#   B. validate-pr-create.sh
#      (existing B1–B6 unchanged)
#      B7. --repo=VALUE (equals form): sibling, ticket in sibling → PASS
#          [F1: equals form was previously un-parsed → CMD_REPO empty → wrong guard]
#      B8. -R VALUE (short alias, space): sibling, ticket in sibling → PASS
#      B9. -R=VALUE (short alias, equals): sibling, ticket in sibling → PASS
#
#   B. validate-pr-create.sh
#      B1. --repo sibling, ticket in sibling → PASS
#          (upstream-fallback suppressed: ops-fork upstream not consulted)
#      B2. --repo sibling, ticket in sibling (CLOSED) → BLOCK
#          (tracker lookup reaches correct repo; closed ticket still blocked)
#      B3. --repo sibling, ticket present in ops-fork upstream but NOT in sibling
#          → BLOCK (ops-fork upstream must NOT serve as a fallback for a
#          completely different repo — the ticket truly doesn't exist in the
#          sibling tracker)
#      B4. --repo = ops-fork origin: ticket in origin → PASS [regression]
#      B5. --repo = ops-fork upstream (me2resh/apexyard): ticket in upstream →
#          PASS, upstream fallback allowed [regression: #207 still works]
#          NOTE: B5 does NOT reach the new cross-repo guard (CMD_REPO==UPSTREAM_REPO
#          is deduped before the guard block). See B6 for guard coverage.
#      B6. --repo = ops-fork origin (fork-org/apexyard), ticket in upstream only →
#          PASS: the guard's allow-path (CMD_REPO_LC == ORIGIN_LC) runs and correctly
#          permits the upstream fallback. A deliberate bug in the guard makes B6 FAIL.
#          [new — finding 2 from PR #465 review]
#
#   C. missing _lib-pr-repo.sh → WARN, not silent
#      C1. require-agdr-for-arch-pr.sh, lib absent, --repo=sibling → WARN + BLOCK (rc=2)
#          (guard degraded: falls through to ops-fork diff which has arch paths → blocked)
#      C2. validate-pr-create.sh, lib absent, --repo=sibling + upstream → WARN emitted
#          [new — finding 1 from PR #465 review]
#
# To run:  ./.claude/hooks/tests/test_pr_hooks_cross_repo.sh
# Exit 0 = all pass, 1 = at least one failure.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)

AGDR_HOOK="$REPO_ROOT/.claude/hooks/require-agdr-for-arch-pr.sh"
VALIDATE_HOOK="$REPO_ROOT/.claude/hooks/validate-pr-create.sh"

# shellcheck source=_lib-mock-gh.sh
source "$SCRIPT_DIR/_lib-mock-gh.sh"

for hook in "$AGDR_HOOK" "$VALIDATE_HOOK"; do
  if [ ! -x "$hook" ]; then
    echo "FAIL: hook not found or not executable: $hook" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_NAMES=""

assert_case() {
  local name="$1" actual_rc="$2" expected_rc="$3" stderr_content="$4" expected_stderr_substr="${5:-}"
  local ok=1
  if [ "$actual_rc" != "$expected_rc" ]; then ok=0; fi
  if [ -n "$expected_stderr_substr" ] && ! echo "$stderr_content" | grep -qF -- "$expected_stderr_substr"; then
    ok=0
  fi
  if [ "$ok" = 1 ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    echo "   expected rc=$expected_rc, got $actual_rc"
    if [ -n "$expected_stderr_substr" ]; then
      echo "   expected stderr to contain: $expected_stderr_substr"
      echo "   stderr was: $(echo "$stderr_content" | head -5)"
    fi
    FAIL=$((FAIL + 1))
    FAILED_NAMES="${FAILED_NAMES} | ${name}"
  fi
}

# ---------------------------------------------------------------------------
# Sandbox factory for require-agdr-for-arch-pr tests.
#
# Creates a git repo that:
#   - has origin = git@github.com:<origin_slug>.git
#   - has commits on main + a feature branch with arch-triggering changes
#     (src/domain/x.ts modified → matches **/domain/** trigger path)
#
# The hook runs with cwd=$dir so `git rev-parse --show-toplevel` returns $dir.
# ---------------------------------------------------------------------------
make_agdr_sandbox() {
  local origin_slug="$1"  # owner/repo for the origin remote
  local dir
  dir=$(mktemp -d)
  (
    cd "$dir" || exit 1
    git init -q -b main
    git config user.email t@test.test
    git config user.name test
    git remote add origin "git@github.com:${origin_slug}.git"
    # Base: a domain file exists on main.
    mkdir -p src/domain
    echo "export const x = 1" > src/domain/widget.ts
    git add src/domain/widget.ts
    git commit -q -m "base"
    # Feature branch: modify the domain file (arch trigger).
    git checkout -q -b "fix/GH-464-test"
    echo "export const x = 2" > src/domain/widget.ts
    git add src/domain/widget.ts
    git commit -q -m "feat: change domain"
  )
  echo "$dir"
}

# ---------------------------------------------------------------------------
# Sandbox factory for validate-pr-create tests.
#
# Creates a sandbox identical to what test_validate_pr_create_upstream.sh uses,
# but with configurable origin AND upstream remotes to simulate the cross-repo
# scenario accurately.
# ---------------------------------------------------------------------------
make_validate_sandbox() {
  local origin_slug="$1"        # origin remote (the ops-fork or project clone)
  local upstream_slug="${2:-}"  # upstream remote (optional; simulates fork setup)
  local local_branch="${3:-fix/GH-464-cross-repo}"
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "t@test.test"
    git config user.name "test"
    git remote add origin "git@github.com:${origin_slug}.git"
    if [ -n "$upstream_slug" ]; then
      git remote add upstream "git@github.com:${upstream_slug}.git"
    fi
    git checkout -q -b "$local_branch" 2>/dev/null || git checkout -q -B "$local_branch"
    touch onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
  )
  # Copy hook + libs into the sandbox so it can run self-contained.
  mkdir -p "$sb/.claude/hooks"
  cp "$VALIDATE_HOOK" "$sb/.claude/hooks/validate-pr-create.sh"
  chmod +x "$sb/.claude/hooks/validate-pr-create.sh"
  for lib in \
    _lib-read-config.sh \
    _lib-tracker.sh \
    _lib-ops-root.sh \
    _lib-pr-repo.sh; do
    [ -f "$REPO_ROOT/.claude/hooks/$lib" ] && cp "$REPO_ROOT/.claude/hooks/$lib" "$sb/.claude/hooks/$lib"
  done
  [ -f "$REPO_ROOT/.claude/project-config.defaults.json" ] && \
    cp "$REPO_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  echo "$sb"
}

# A minimal valid PR body (has Testing + Glossary so body checks don't fire).
VALID_BODY="## Summary
test change

## Testing
unit tests pass

## Glossary
| Term | Definition |
|------|------------|
| cross-repo | PR targets a different repo than the session cwd |"

# ---------------------------------------------------------------------------
# Section A — require-agdr-for-arch-pr.sh cross-repo guard
# ---------------------------------------------------------------------------

echo "--- Section A: require-agdr-for-arch-pr.sh ---"

# A1: --repo targets sibling repo, arch paths present in ops-fork diff → PASS
# The guard fires because CMD_REPO (me2resh/apexyard-premium) ≠ origin
# (fork-org/apexyard). The hook exits 0 without evaluating the diff.
DIR=$(make_agdr_sandbox "fork-org/apexyard")
STDERR=$( cd "$DIR" && \
  printf '{"tool_input":{"command":"gh pr create --repo me2resh/apexyard-premium --base main --title '"'"'feat(#1): premium thing'"'"' --body '"'"'Just a change, no AgDR'"'"'"}}' \
  | "$AGDR_HOOK" 2>&1 >/dev/null )
RC=$?
rm -rf "$DIR"
assert_case "A1: --repo=sibling, arch in ops-fork diff → PASS (cross-repo guard)" "$RC" 0 "$STDERR"

# A2: --repo matches ops-fork origin, arch paths present, no AgDR → BLOCK
# The guard does NOT fire because CMD_REPO = origin. Framework PR still gated.
DIR=$(make_agdr_sandbox "fork-org/apexyard")
STDERR=$( cd "$DIR" && \
  printf '{"tool_input":{"command":"gh pr create --repo fork-org/apexyard --base main --title '"'"'feat(#1): framework arch change'"'"' --body '"'"'Just a change, no AgDR'"'"'"}}' \
  | "$AGDR_HOOK" 2>&1 >/dev/null )
RC=$?
rm -rf "$DIR"
assert_case "A2: --repo=origin (framework PR), no AgDR → BLOCK (regression)" "$RC" 2 "$STDERR" "no AgDR reference"

# A3: --repo matches ops-fork origin, arch paths present, body has AgDR → PASS
DIR=$(make_agdr_sandbox "fork-org/apexyard")
STDERR=$( cd "$DIR" && \
  printf '{"tool_input":{"command":"gh pr create --repo fork-org/apexyard --base main --title '"'"'feat(#1): framework arch change'"'"' --body '"'"'See AgDR-0007-pr-hooks for rationale.'"'"'"}}' \
  | "$AGDR_HOOK" 2>&1 >/dev/null )
RC=$?
rm -rf "$DIR"
assert_case "A3: --repo=origin (framework PR), AgDR present → PASS (regression)" "$RC" 0 "$STDERR"

# A4: No --repo flag, arch paths present, no AgDR → BLOCK
# Implicit same-repo (no --repo flag means pr_repo_matches_cwd returns 0).
# Framework gating still runs.
DIR=$(make_agdr_sandbox "fork-org/apexyard")
STDERR=$( cd "$DIR" && \
  printf '{"tool_input":{"command":"gh pr create --base main --title '"'"'feat(#1): implicit origin'"'"' --body '"'"'No AgDR here'"'"'"}}' \
  | "$AGDR_HOOK" 2>&1 >/dev/null )
RC=$?
rm -rf "$DIR"
assert_case "A4: no --repo flag (implicit origin), no AgDR → BLOCK (regression)" "$RC" 2 "$STDERR" "no AgDR reference"

# A5: --repo=VALUE (equals form), sibling → PASS
# F1: the previous parser only matched `--repo SPACE VALUE`, so `--repo=VALUE`
# produced an empty CMD_REPO, making the cross-repo guard a no-op.  The hook
# would then fall through to the ops-fork diff, which has arch paths, and
# produce a false-positive block.  After the fix the guard fires correctly.
DIR=$(make_agdr_sandbox "fork-org/apexyard")
STDERR=$( cd "$DIR" && \
  printf '{"tool_input":{"command":"gh pr create --repo=me2resh/apexyard-premium --base main --title '"'"'feat(#1): premium thing'"'"' --body '"'"'Just a change, no AgDR'"'"'"}}' \
  | "$AGDR_HOOK" 2>&1 >/dev/null )
RC=$?
rm -rf "$DIR"
assert_case "A5: --repo=VALUE (equals form), sibling → PASS (cross-repo guard, F1)" "$RC" 0 "$STDERR"

# A6: -R VALUE (short alias, space), sibling → PASS
DIR=$(make_agdr_sandbox "fork-org/apexyard")
STDERR=$( cd "$DIR" && \
  printf '{"tool_input":{"command":"gh pr create -R me2resh/apexyard-premium --base main --title '"'"'feat(#1): premium thing'"'"' --body '"'"'Just a change, no AgDR'"'"'"}}' \
  | "$AGDR_HOOK" 2>&1 >/dev/null )
RC=$?
rm -rf "$DIR"
assert_case "A6: -R VALUE (short alias, space), sibling → PASS (cross-repo guard, F1)" "$RC" 0 "$STDERR"

# A7: -R=VALUE (short alias, equals), sibling → PASS
DIR=$(make_agdr_sandbox "fork-org/apexyard")
STDERR=$( cd "$DIR" && \
  printf '{"tool_input":{"command":"gh pr create -R=me2resh/apexyard-premium --base main --title '"'"'feat(#1): premium thing'"'"' --body '"'"'Just a change, no AgDR'"'"'"}}' \
  | "$AGDR_HOOK" 2>&1 >/dev/null )
RC=$?
rm -rf "$DIR"
assert_case "A7: -R=VALUE (short alias, equals), sibling → PASS (cross-repo guard, F1)" "$RC" 0 "$STDERR"

# ---------------------------------------------------------------------------
# Section B — validate-pr-create.sh cross-repo tracker guard
# ---------------------------------------------------------------------------

echo "--- Section B: validate-pr-create.sh ---"

# B1: --repo sibling, ticket in sibling → PASS
# The ops-fork upstream (me2resh/apexyard) must NOT be consulted as a
# fallback for the sibling repo. The ticket exists only in the sibling.
SB=$(make_validate_sandbox "fork-org/apexyard" "me2resh/apexyard" "fix/GH-464-cross-repo")
mock_gh_install "$SB"
# Issue #99 exists in apexyard-premium (sibling) but NOT in apexyard (upstream).
mock_gh_set_repo_existence "$SB" 99 me2resh/apexyard-premium yes
mock_gh_set_repo_existence "$SB" 99 me2resh/apexyard no
mock_gh_set_repo_existence "$SB" 99 fork-org/apexyard no
BODY_FILE="$SB/body.md"
printf '%s' "$VALID_BODY" > "$BODY_FILE"
CMD="gh pr create --repo me2resh/apexyard-premium --base main --title 'fix(#99): sibling ticket' --body-file $BODY_FILE --head fix/GH-464-cross-repo"
INPUT=$(jq -nc --arg c "$CMD" '{tool_input:{command:$c}}')
STDERR=$(cd "$SB" && echo "$INPUT" | bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
RC=$?
rm -rf "$SB"
assert_case "B1: --repo=sibling, ticket in sibling → PASS (no upstream bleed)" "$RC" 0 "$STDERR"

# B2: --repo sibling, ticket in sibling but CLOSED → BLOCK
# Tracker lookup must reach the sibling and return the real state.
SB=$(make_validate_sandbox "fork-org/apexyard" "me2resh/apexyard" "fix/GH-464-cross-repo")
mock_gh_install "$SB"
mock_gh_set_repo_existence "$SB" 77 me2resh/apexyard-premium yes
mock_gh_set_repo_existence "$SB" 77 fork-org/apexyard no
mock_gh_set_state "$SB" 77 CLOSED
BODY_FILE="$SB/body.md"
printf '%s' "$VALID_BODY" > "$BODY_FILE"
CMD="gh pr create --repo me2resh/apexyard-premium --base main --title 'fix(#77): closed sibling ticket' --body-file $BODY_FILE --head fix/GH-464-cross-repo"
INPUT=$(jq -nc --arg c "$CMD" '{tool_input:{command:$c}}')
STDERR=$(cd "$SB" && echo "$INPUT" | bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
RC=$?
rm -rf "$SB"
assert_case "B2: --repo=sibling, ticket CLOSED in sibling → BLOCK" "$RC" 2 "$STDERR" "CLOSED"

# B3: --repo sibling, ticket in ops-fork upstream (me2resh/apexyard) NOT in sibling → BLOCK
# The ops-fork's upstream remote must not be a false fallback for the sibling.
# The ticket genuinely doesn't exist in the target repo → must block.
SB=$(make_validate_sandbox "fork-org/apexyard" "me2resh/apexyard" "fix/GH-464-cross-repo")
mock_gh_install "$SB"
# Issue #55 exists in me2resh/apexyard (framework) but NOT in the sibling.
mock_gh_set_repo_existence "$SB" 55 me2resh/apexyard yes
mock_gh_set_repo_existence "$SB" 55 me2resh/apexyard-premium no
mock_gh_set_repo_existence "$SB" 55 fork-org/apexyard no
BODY_FILE="$SB/body.md"
printf '%s' "$VALID_BODY" > "$BODY_FILE"
CMD="gh pr create --repo me2resh/apexyard-premium --base main --title 'fix(#55): framework ticket in wrong tracker' --body-file $BODY_FILE --head fix/GH-464-cross-repo"
INPUT=$(jq -nc --arg c "$CMD" '{tool_input:{command:$c}}')
STDERR=$(cd "$SB" && echo "$INPUT" | bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
RC=$?
rm -rf "$SB"
assert_case "B3: --repo=sibling, ticket in ops-fork upstream only → BLOCK (no cross-lineage fallback)" "$RC" 2 "$STDERR" "does not"

# B4: --repo = ops-fork origin (framework PR), ticket in origin → PASS [regression]
SB=$(make_validate_sandbox "fork-org/apexyard" "" "fix/GH-464-regression")
mock_gh_install "$SB"
BODY_FILE="$SB/body.md"
printf '%s' "$VALID_BODY" > "$BODY_FILE"
CMD="gh pr create --repo fork-org/apexyard --base dev --title 'fix(#42): framework ticket' --body-file $BODY_FILE --head fix/GH-464-regression"
INPUT=$(jq -nc --arg c "$CMD" '{tool_input:{command:$c}}')
STDERR=$(cd "$SB" && echo "$INPUT" | bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
RC=$?
rm -rf "$SB"
assert_case "B4: --repo=origin (framework PR), ticket in origin → PASS (regression)" "$RC" 0 "$STDERR"

# B5: --repo = ops-fork upstream (me2resh/apexyard), ticket in upstream → PASS
# The fork-→-upstream case from #207 must still work after this fix.
# NOTE: B5 does NOT exercise the new cross-repo guard because CMD_REPO equals
# UPSTREAM_REPO, which is deduped to UPSTREAM_REPO="" at line ~170, so the
# guard block (CMD_REPO non-empty AND UPSTREAM_REPO non-empty) is never reached.
# The guard's allow-path is tested in B6 below.
SB=$(make_validate_sandbox "fork-org/apexyard" "me2resh/apexyard" "fix/GH-464-upstream")
mock_gh_install "$SB"
# Issue #207 exists in upstream (me2resh/apexyard) only — the fork doesn't have it.
mock_gh_set_repo_existence "$SB" 207 me2resh/apexyard yes
mock_gh_set_repo_existence "$SB" 207 fork-org/apexyard no
BODY_FILE="$SB/body.md"
printf '%s' "$VALID_BODY" > "$BODY_FILE"
CMD="gh pr create --repo me2resh/apexyard --base dev --title 'fix(#207): upstream issue' --body-file $BODY_FILE --head fix/GH-464-upstream"
INPUT=$(jq -nc --arg c "$CMD" '{tool_input:{command:$c}}')
STDERR=$(cd "$SB" && echo "$INPUT" | bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
RC=$?
rm -rf "$SB"
assert_case "B5: --repo=upstream (fork→upstream PR), ticket in upstream → PASS (#207 regression)" "$RC" 0 "$STDERR"

# B6: --repo = origin (fork-org/apexyard), ticket in upstream only → PASS
#
# This is the test that GENUINELY exercises the new cross-repo guard's allow-path
# (me2resh/apexyard#464 review finding 2).
#
# Why B5 doesn't cover it: in B5, CMD_REPO == UPSTREAM_REPO == me2resh/apexyard.
# The pre-existing dedup at the top of the upstream-resolve block zeros UPSTREAM_REPO
# when it equals TRACKER_REPO, so the guard block (both CMD_REPO and UPSTREAM_REPO
# non-empty) is never reached. B5 passes regardless of whether the new guard is correct.
#
# B6 sets CMD_REPO = origin (fork-org/apexyard) ≠ upstream (me2resh/apexyard).
# TRACKER_REPO = fork-org/apexyard.  UPSTREAM_REPO = me2resh/apexyard ≠ TRACKER_REPO
# → dedup does NOT zero UPSTREAM_REPO → the guard block runs.
# The guard checks: CMD_REPO_LC == ORIGIN_LC → true → allow fallback.
# The ticket exists in upstream only → upstream fallback finds it → PASS.
#
# A deliberate bug in the guard (e.g. comparing CMD_REPO_LC to a wrong value
# so the allow-path condition fails) makes this test FAIL:
#   UPSTREAM_REPO would be zeroed prematurely → ticket-not-found → exit 2.
SB=$(make_validate_sandbox "fork-org/apexyard" "me2resh/apexyard" "fix/GH-464-b6")
mock_gh_install "$SB"
# Ticket #300 lives only in upstream; fork/origin doesn't have it.
mock_gh_set_repo_existence "$SB" 300 me2resh/apexyard yes
mock_gh_set_repo_existence "$SB" 300 fork-org/apexyard no
BODY_FILE="$SB/body.md"
printf '%s' "$VALID_BODY" > "$BODY_FILE"
# PR targets the fork origin — this is the CMD_REPO == ORIGIN_LC allow-path.
CMD="gh pr create --repo fork-org/apexyard --base dev --title 'fix(#300): upstream-only ticket, targeting fork origin' --body-file $BODY_FILE --head fix/GH-464-b6"
INPUT=$(jq -nc --arg c "$CMD" '{tool_input:{command:$c}}')
STDERR=$(cd "$SB" && echo "$INPUT" | bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
RC=$?
rm -rf "$SB"
assert_case "B6: --repo=origin, ticket in upstream only → PASS (new guard allow-path, CMD_REPO==ORIGIN_LC)" "$RC" 0 "$STDERR"

# B7: --repo=VALUE (equals form), sibling, ticket in sibling → PASS
# F1: the previous CMD_REPO parser missed the equals form, so CMD_REPO was
# empty → TRACKER_REPO fell back to the ops-fork origin → wrong tracker
# queried.  After the fix, CMD_REPO=me2resh/apexyard-premium → correct.
SB=$(make_validate_sandbox "fork-org/apexyard" "me2resh/apexyard" "fix/GH-464-f1-b7")
mock_gh_install "$SB"
mock_gh_set_repo_existence "$SB" 88 me2resh/apexyard-premium yes
mock_gh_set_repo_existence "$SB" 88 me2resh/apexyard no
mock_gh_set_repo_existence "$SB" 88 fork-org/apexyard no
BODY_FILE="$SB/body.md"
printf '%s' "$VALID_BODY" > "$BODY_FILE"
CMD="gh pr create --repo=me2resh/apexyard-premium --base main --title 'fix(#88): equals form ticket' --body-file $BODY_FILE --head fix/GH-464-f1-b7"
INPUT=$(jq -nc --arg c "$CMD" '{tool_input:{command:$c}}')
STDERR=$(cd "$SB" && echo "$INPUT" | bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
RC=$?
rm -rf "$SB"
assert_case "B7: --repo=VALUE (equals form), ticket in sibling → PASS (F1)" "$RC" 0 "$STDERR"

# B8: -R VALUE (short alias, space), sibling, ticket in sibling → PASS
SB=$(make_validate_sandbox "fork-org/apexyard" "me2resh/apexyard" "fix/GH-464-f1-b8")
mock_gh_install "$SB"
mock_gh_set_repo_existence "$SB" 88 me2resh/apexyard-premium yes
mock_gh_set_repo_existence "$SB" 88 me2resh/apexyard no
mock_gh_set_repo_existence "$SB" 88 fork-org/apexyard no
BODY_FILE="$SB/body.md"
printf '%s' "$VALID_BODY" > "$BODY_FILE"
CMD="gh pr create -R me2resh/apexyard-premium --base main --title 'fix(#88): short alias ticket' --body-file $BODY_FILE --head fix/GH-464-f1-b8"
INPUT=$(jq -nc --arg c "$CMD" '{tool_input:{command:$c}}')
STDERR=$(cd "$SB" && echo "$INPUT" | bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
RC=$?
rm -rf "$SB"
assert_case "B8: -R VALUE (short alias, space), ticket in sibling → PASS (F1)" "$RC" 0 "$STDERR"

# B9: -R=VALUE (short alias, equals), sibling, ticket in sibling → PASS
SB=$(make_validate_sandbox "fork-org/apexyard" "me2resh/apexyard" "fix/GH-464-f1-b9")
mock_gh_install "$SB"
mock_gh_set_repo_existence "$SB" 88 me2resh/apexyard-premium yes
mock_gh_set_repo_existence "$SB" 88 me2resh/apexyard no
mock_gh_set_repo_existence "$SB" 88 fork-org/apexyard no
BODY_FILE="$SB/body.md"
printf '%s' "$VALID_BODY" > "$BODY_FILE"
CMD="gh pr create -R=me2resh/apexyard-premium --base main --title 'fix(#88): short-alias-equals ticket' --body-file $BODY_FILE --head fix/GH-464-f1-b9"
INPUT=$(jq -nc --arg c "$CMD" '{tool_input:{command:$c}}')
STDERR=$(cd "$SB" && echo "$INPUT" | bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
RC=$?
rm -rf "$SB"
assert_case "B9: -R=VALUE (short alias+equals), ticket in sibling → PASS (F1)" "$RC" 0 "$STDERR"

# ---------------------------------------------------------------------------
# Section C — missing _lib-pr-repo.sh emits a visible WARN (finding 1)
# ---------------------------------------------------------------------------

echo "--- Section C: missing _lib-pr-repo.sh → WARN, not silent ---"

# C1: require-agdr-for-arch-pr.sh — lib absent, --repo=sibling present → WARN on stderr
# The hook must NOT silently proceed as if the guard ran successfully; it must
# emit a WARN naming the missing lib so the degraded state is visible.
# With lib absent, the hook evaluates the diff against the ops-fork working
# tree (degraded mode). The sandbox has arch paths (src/domain/widget.ts) that
# trigger the arch check, so the hook exits 2 (BLOCK).
# The critical assertion is that WARN is emitted — degradation is visible, not silent.
# rc=2 confirms the hook correctly blocks when cross-repo guard is missing.
#
# SAFETY: we copy the hook + lib into a temp sandbox and remove the lib FROM
# THE SANDBOX, never touching $REPO_ROOT/.claude/hooks/ (the live hooks dir).
# Mutating the live dir without a trap risks permanently losing the lib if the
# test is killed between the two mv calls (CI timeout, Ctrl+C, OOM).
DIR_C1=$(make_agdr_sandbox "fork-org/apexyard")
# Build a sandbox with the hook and all its deps, then remove just the lib.
SB_C1=$(mktemp -d)
mkdir -p "$SB_C1/.claude/hooks"
cp "$AGDR_HOOK" "$SB_C1/.claude/hooks/require-agdr-for-arch-pr.sh"
chmod +x "$SB_C1/.claude/hooks/require-agdr-for-arch-pr.sh"
for lib in \
  _lib-read-config.sh \
  _lib-ops-root.sh \
  _lib-pr-repo.sh; do
  [ -f "$REPO_ROOT/.claude/hooks/$lib" ] && cp "$REPO_ROOT/.claude/hooks/$lib" "$SB_C1/.claude/hooks/$lib"
done
[ -f "$REPO_ROOT/.claude/project-config.defaults.json" ] && \
  cp "$REPO_ROOT/.claude/project-config.defaults.json" "$SB_C1/.claude/project-config.defaults.json"
# Remove the lib from the SANDBOX COPY (not the live hooks dir).
rm -f "$SB_C1/.claude/hooks/_lib-pr-repo.sh"
AGDR_HOOK_C1="$SB_C1/.claude/hooks/require-agdr-for-arch-pr.sh"
STDERR_C1=$( cd "$DIR_C1" && \
  printf '{"tool_input":{"command":"gh pr create --repo me2resh/apexyard-premium --base main --title '"'"'feat(#1): premium thing'"'"' --body '"'"'No AgDR, cross-repo'"'"'"}}' \
  | "$AGDR_HOOK_C1" 2>&1 >/dev/null )
RC_C1=$?
rm -rf "$DIR_C1" "$SB_C1"
assert_case "C1: agdr hook, lib missing, --repo=sibling → WARN + BLOCK (degraded, not silent)" "$RC_C1" 2 "$STDERR_C1" "WARN"

# C2: validate-pr-create.sh — lib absent, --repo=sibling + upstream configured → WARN on stderr
# Same shape as C1: the guard's inline fallback runs but must emit a visible WARN.
SB_C2=$(make_validate_sandbox "fork-org/apexyard" "me2resh/apexyard" "fix/GH-464-c2")
mock_gh_install "$SB_C2"
# Issue #99 exists in sibling, not upstream/origin.
mock_gh_set_repo_existence "$SB_C2" 99 me2resh/apexyard-premium yes
mock_gh_set_repo_existence "$SB_C2" 99 me2resh/apexyard no
mock_gh_set_repo_existence "$SB_C2" 99 fork-org/apexyard no
BODY_FILE_C2="$SB_C2/body.md"
printf '%s' "$VALID_BODY" > "$BODY_FILE_C2"
CMD_C2="gh pr create --repo me2resh/apexyard-premium --base main --title 'fix(#99): sibling' --body-file $BODY_FILE_C2 --head fix/GH-464-c2"
INPUT_C2=$(jq -nc --arg c "$CMD_C2" '{tool_input:{command:$c}}')
# Remove the lib from the sandbox copy.
rm -f "$SB_C2/.claude/hooks/_lib-pr-repo.sh"
STDERR_C2=$(cd "$SB_C2" && echo "$INPUT_C2" | bash .claude/hooks/validate-pr-create.sh 2>&1 >/dev/null)
RC_C2=$?
rm -rf "$SB_C2"
assert_case "C2: validate hook, lib missing, --repo=sibling + upstream → WARN emitted (no silent degradation)" "$RC_C2" 0 "$STDERR_C2" "WARN"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:${FAILED_NAMES}" >&2
  exit 1
fi
exit 0
