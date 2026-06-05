#!/bin/bash
# Tests for block-unreviewed-merge.sh — structured-marker enforcement
# (me2resh/apexyard#48) and merge-gate logic.
#
# Each case:
#   - builds an isolated sandbox with the hook + _lib-extract-pr.sh
#   - writes the relevant marker files to .claude/session/reviews/
#   - mocks `gh pr view` (and friends) so the resolve_pr_head call inside
#     the hook returns a deterministic SHA without hitting GitHub
#   - pipes a synthetic PreToolUse JSON for `gh pr merge <N>`
#   - asserts exit code (0 = pass-through, 2 = blocked) and stderr regex
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/block-unreviewed-merge.sh"
LIB_PR="$SRC_ROOT/.claude/hooks/_lib-extract-pr.sh"
LIB_MARKERS="$SRC_ROOT/.claude/hooks/_lib-review-markers.sh"

for f in "$HOOK_SRC" "$LIB_PR" "$LIB_MARKERS"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required source missing: $f" >&2
    exit 1
  fi
done

# Load the marker lib so test helpers use the same path logic as the hook.
# shellcheck source=/dev/null
. "$LIB_MARKERS"

PASS=0
FAIL=0
FAILED_CASES=""

# Fixed test SHA — used as both PR HEAD (mocked) and marker contents.
FIXED_SHA="abcdef1234567890abcdef1234567890abcdef12"
WRONG_SHA="0000000000000000000000000000000000000000"

make_sandbox() {
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    : > onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
  )
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session/reviews" "$sb/bin"
  cp "$HOOK_SRC"    "$sb/.claude/hooks/block-unreviewed-merge.sh"
  cp "$LIB_PR"      "$sb/.claude/hooks/_lib-extract-pr.sh"
  cp "$LIB_MARKERS" "$sb/.claude/hooks/_lib-review-markers.sh"
  chmod +x "$sb/.claude/hooks/block-unreviewed-merge.sh"

  # Mock `gh` so resolve_pr_head returns FIXED_SHA. The hook calls
  # `gh pr view <N> --json headRefOid -q '.headRefOid'` (or a similar
  # shape) — return the fixed SHA on stdout, no network involved.
  # Also handles headRefName (sync-PR guard) and headRepository (repo extraction, #485).
  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
# Minimal gh shim for test_block_unreviewed_merge.
case "\$*" in
  *"pr view"*"headRefOid"*)     echo "$FIXED_SHA" ;;
  *"pr view"*"headRefName"*)    echo "feature/GH-99-test" ;;
  *"pr view"*"headRepository"*) echo "me2resh/apexyard" ;;
  *) ;;
esac
exit 0
EOF
  chmod +x "$sb/bin/gh"

  echo "$sb"
}

# Default test repo — matches the --repo flag used in run_case().
TEST_REPO="me2resh/apexyard"

# Marker writers -------------------------------------------------------
# All writers use review_marker_path (from _lib-review-markers.sh, sourced
# at top) so the test markers land at the same repo-qualified paths the
# hook will look for. The default repo matches the --repo flag in run_case().

write_rex_marker() {
  # Bare SHA on line 1 — Rex's format is unchanged.
  local sb="$1" pr="$2" sha="${3:-$FIXED_SHA}" repo="${4:-$TEST_REPO}"
  local path
  path=$(review_marker_path "$repo" "$pr" rex "$sb")
  echo "$sha" > "$path"
}

write_ceo_marker_structured() {
  # Valid v2 structured marker.
  local sb="$1" pr="$2" sha="${3:-$FIXED_SHA}" repo="${4:-$TEST_REPO}"
  local path
  path=$(review_marker_path "$repo" "$pr" ceo "$sb")
  cat > "$path" <<EOF
sha=${sha}
approved_by=user
approved_at=2026-05-03T20:00:00Z
skill_version=2
approval_summary="test approval"
EOF
}

write_ceo_marker_legacy_bare() {
  # Pre-#48 format: bare SHA, single line.
  local sb="$1" pr="$2" sha="${3:-$FIXED_SHA}" repo="${4:-$TEST_REPO}"
  local path
  path=$(review_marker_path "$repo" "$pr" ceo "$sb")
  echo "$sha" > "$path"
}

write_ceo_marker_missing_field() {
  # Has sha= and skill_version but NO approved_by.
  local sb="$1" pr="$2" repo="${3:-$TEST_REPO}"
  local path
  path=$(review_marker_path "$repo" "$pr" ceo "$sb")
  cat > "$path" <<EOF
sha=${FIXED_SHA}
skill_version=2
EOF
}

write_ceo_marker_wrong_approved_by() {
  # Has approved_by=robot instead of approved_by=user.
  local sb="$1" pr="$2" repo="${3:-$TEST_REPO}"
  local path
  path=$(review_marker_path "$repo" "$pr" ceo "$sb")
  cat > "$path" <<EOF
sha=${FIXED_SHA}
approved_by=robot
skill_version=2
EOF
}

write_ceo_marker_old_version() {
  # skill_version=1 (legacy format that should be rejected).
  local sb="$1" pr="$2" repo="${3:-$TEST_REPO}"
  local path
  path=$(review_marker_path "$repo" "$pr" ceo "$sb")
  cat > "$path" <<EOF
sha=${FIXED_SHA}
approved_by=user
skill_version=1
EOF
}

# Test runner ----------------------------------------------------------

run_case() {
  local label="$1" want_rc="$2" want_stderr_regex="$3" sb="$4" pr="$5"
  local cmd="gh pr merge $pr --repo me2resh/apexyard --squash"
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
  local got_stderr got_rc
  # APEXYARD_OPS_DISABLE_PIN=1: force walk-up resolution so the sandbox's ops root
  # is used, not the real session pin (avoids marker-home mismatch in CI/worktrees).
  got_stderr=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:300})" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  if [ -n "$want_stderr_regex" ] && ! echo "$got_stderr" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# --- Cases ------------------------------------------------------------

# 1. Both markers present & valid → allows merge (exit 0)
sb=$(make_sandbox)
write_rex_marker "$sb" 200
write_ceo_marker_structured "$sb" 200
run_case "valid rex + valid v2 ceo → allows" 0 "" "$sb" 200

# 2. Missing Rex → blocks
sb=$(make_sandbox)
write_ceo_marker_structured "$sb" 201
run_case "missing rex marker → blocks" 2 "no recorded code-reviewer" "$sb" 201

# 3. Missing CEO → blocks
sb=$(make_sandbox)
write_rex_marker "$sb" 202
run_case "missing ceo marker → blocks" 2 "no CEO approval marker" "$sb" 202

# 4. Bare-SHA legacy CEO marker → blocks "stale or unrecognised format"
sb=$(make_sandbox)
write_rex_marker "$sb" 203
write_ceo_marker_legacy_bare "$sb" 203
run_case "bare-SHA ceo marker → blocks (stale format)" 2 "stale or unrecognised format" "$sb" 203

# 5. CEO marker missing approved_by → blocks
sb=$(make_sandbox)
write_rex_marker "$sb" 204
write_ceo_marker_missing_field "$sb" 204
run_case "ceo missing approved_by → blocks" 2 "approved_by=user" "$sb" 204

# 6. CEO marker has approved_by=robot → blocks
sb=$(make_sandbox)
write_rex_marker "$sb" 205
write_ceo_marker_wrong_approved_by "$sb" 205
run_case "ceo approved_by=robot → blocks" 2 "approved_by=user" "$sb" 205

# 7. CEO marker skill_version=1 → blocks
sb=$(make_sandbox)
write_rex_marker "$sb" 206
write_ceo_marker_old_version "$sb" 206
run_case "ceo skill_version=1 → blocks" 2 "skill_version=1" "$sb" 206

# 8. CEO marker sha mismatch → blocks
sb=$(make_sandbox)
write_rex_marker "$sb" 207
write_ceo_marker_structured "$sb" 207 "$WRONG_SHA"
run_case "ceo sha mismatch → blocks" 2 "CEO approved commit" "$sb" 207

# 9. Rex sha mismatch → blocks
sb=$(make_sandbox)
write_rex_marker "$sb" 208 "$WRONG_SHA"
write_ceo_marker_structured "$sb" 208
run_case "rex sha mismatch → blocks" 2 "Code-reviewer approved commit" "$sb" 208

# 10. Non-merge command (e.g. gh pr view) → no-op exit 0
sb=$(make_sandbox)
input=$(jq -nc --arg c "gh pr view 209 --repo me2resh/apexyard" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "0" ] && [ -z "$got_stderr" ]; then
  echo "PASS [non-merge command → no-op]"; PASS=$((PASS+1))
else
  echo "FAIL [non-merge command → no-op]: rc=$got_rc stderr=$got_stderr" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}non-merge "
fi

# 11. The gh-api merge shape is also gated (#47 — same coverage check).
sb=$(make_sandbox)
write_rex_marker "$sb" 210
# No CEO marker — should still block.
input=$(jq -nc --arg c "gh api repos/me2resh/apexyard/pulls/210/merge -X PUT" \
  '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -q "no CEO approval marker"; then
  echo "PASS [gh api merge shape also gated]"; PASS=$((PASS+1))
else
  echo "FAIL [gh api merge shape also gated]: rc=$got_rc stderr=${got_stderr:0:200}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}gh-api-shape "
fi

# 12. Quoted approval_summary (with spaces) doesn't break the parser.
sb=$(make_sandbox)
write_rex_marker "$sb" 211
ceo_path=$(review_marker_path "$TEST_REPO" 211 ceo "$sb")
cat > "$ceo_path" <<EOF
sha=${FIXED_SHA}
approved_by=user
approved_at=2026-05-03T20:00:00Z
skill_version=2
approval_summary="user said: 211 approved, ship it"
EOF
run_case "structured marker with quoted multi-word summary → allows" 0 "" "$sb" 211

# 13. Workspace-clone scenario (apexyard#229 + #230). Sandbox simulates
#     an ops fork at $sb (with onboarding.yaml + apexyard.projects.yaml
#     + _lib-ops-root.sh) and a workspace clone underneath at
#     $sb/workspace/demo/ (with its own .git/). Markers live in the OPS
#     FORK's reviews dir. Hook runs with cwd = workspace clone. Should
#     pass — the OPS_ROOT walk in the hook resolves up to the ops fork.
sb=$(make_sandbox)
# Add the apexyard.projects.yaml that resolve_ops_root requires.
: > "$sb/apexyard.projects.yaml"
# Copy required libs into the sandbox's hook dir.
cp "$SRC_ROOT/.claude/hooks/_lib-ops-root.sh"      "$sb/.claude/hooks/_lib-ops-root.sh"
cp "$SRC_ROOT/.claude/hooks/_lib-review-markers.sh" "$sb/.claude/hooks/_lib-review-markers.sh"
# Build a workspace clone underneath, with its own git toplevel.
mkdir -p "$sb/workspace/demo"
( cd "$sb/workspace/demo" && git init -q )
# Markers exist at the OPS FORK's reviews dir (where the agent + skill write).
write_rex_marker "$sb" 212
write_ceo_marker_structured "$sb" 212
# Run the hook from inside workspace/demo cwd (not the ops fork).
# APEXYARD_OPS_DISABLE_PIN=1 forces walk-up resolution so the sandbox's
# ops root is used, not the real session pin (mirrors test_require_architecture_review.sh).
input=$(jq -nc --arg c "gh pr merge 212 --repo me2resh/apexyard" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb/workspace/demo" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash $sb/.claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "0" ] && [ -z "$got_stderr" ]; then
  echo "PASS [workspace-clone cwd → resolves markers from ops fork (#229+#230)]"; PASS=$((PASS+1))
else
  echo "FAIL [workspace-clone cwd → resolves markers from ops fork (#229+#230)]: rc=$got_rc stderr=${got_stderr:0:300}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}workspace-clone-resolves-up "
fi

# --- Compound command tests (#426) ------------------------------------

# Helper: run with a custom command string (not just `gh pr merge <N>`)
run_case_custom_cmd() {
  local label="$1" want_rc="$2" want_stderr_regex="$3" sb="$4" cmd="$5"
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
  local got_stderr got_rc
  got_stderr=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"
  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:300})" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  if [ -n "$want_stderr_regex" ] && ! echo "$got_stderr" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# Case: compound command with valid inline marker + merge → should PASS
sb=$(make_sandbox)
write_rex_marker "$sb" 42
cmd="cat > $sb/.claude/session/reviews/42-ceo.approved <<EOF
sha=${FIXED_SHA}
approved_by=user
approved_at=2026-05-27T12:00:00Z
skill_version=2
approval_summary=test
EOF
gh pr merge 42 --repo me2resh/apexyard --squash"
run_case_custom_cmd "compound-valid-inline-marker" 0 "" "$sb" "$cmd"

# Case: compound command with WRONG SHA in inline marker → should BLOCK
sb=$(make_sandbox)
write_rex_marker "$sb" 42
cmd="cat > $sb/.claude/session/reviews/42-ceo.approved <<EOF
sha=${WRONG_SHA}
approved_by=user
skill_version=2
EOF
gh pr merge 42 --repo me2resh/apexyard --squash"
run_case_custom_cmd "compound-wrong-sha-inline" 2 "CEO approved commit" "$sb" "$cmd"

# Case: compound command with missing approved_by in inline → should BLOCK
sb=$(make_sandbox)
write_rex_marker "$sb" 42
cmd="printf 'sha=${FIXED_SHA}\nskill_version=2\n' > $sb/.claude/session/reviews/42-ceo.approved && gh pr merge 42 --repo me2resh/apexyard --squash"
run_case_custom_cmd "compound-missing-approved-by" 2 "no CEO approval marker" "$sb" "$cmd"

# Case: compound command with skill_version=1 in inline → should BLOCK
sb=$(make_sandbox)
write_rex_marker "$sb" 42
cmd="cat > $sb/.claude/session/reviews/42-ceo.approved <<EOF
sha=${FIXED_SHA}
approved_by=user
skill_version=1
EOF
gh pr merge 42 --repo me2resh/apexyard --squash"
run_case_custom_cmd "compound-old-skill-version" 2 "no CEO approval marker" "$sb" "$cmd"

# --- Sync-PR squash guard tests (apexyard#459) -------------------------
#
# The guard in block-unreviewed-merge.sh refuses --squash on PRs whose
# head branch starts with `sync/main-to-dev-after-`. The guard fires on
# both merge shapes (gh pr merge + gh api .../merge).
#
# The gh mock in make_sandbox already handles `gh pr view ... headRefOid`
# calls. We extend it per-sandbox to also handle `headRefName` calls so
# the guard's branch-lookup gets a deterministic branch name.

make_sandbox_with_sync_branch() {
  local sb branch_name
  branch_name="${1:-sync/main-to-dev-after-v2.3.0}"
  sb=$(make_sandbox)
  # Rewrite the gh shim to handle headRefOid, headRefName, and headRepository.
  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"pr view"*"headRefOid"*)     echo "$FIXED_SHA" ;;
  *"pr view"*"headRefName"*)    echo "$branch_name" ;;
  *"pr view"*"headRepository"*) echo "me2resh/apexyard" ;;
  *) ;;
esac
exit 0
EOF
  chmod +x "$sb/bin/gh"
  echo "$sb"
}

make_sandbox_non_sync() {
  local sb
  sb=$(make_sandbox)
  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"pr view"*"headRefOid"*)     echo "$FIXED_SHA" ;;
  *"pr view"*"headRefName"*)    echo "feature/GH-99-something" ;;
  *"pr view"*"headRepository"*) echo "me2resh/apexyard" ;;
  *) ;;
esac
exit 0
EOF
  chmod +x "$sb/bin/gh"
  echo "$sb"
}

# Case S1: sync PR + --squash → BLOCKED (the core guard)
sb=$(make_sandbox_with_sync_branch "sync/main-to-dev-after-v2.3.0")
write_rex_marker "$sb" 300
write_ceo_marker_structured "$sb" 300
cmd="gh pr merge 300 --repo me2resh/apexyard --squash --delete-branch"
input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -q "cannot be squash-merged"; then
  echo "PASS [sync PR + --squash → blocked (apexyard#459)]"; PASS=$((PASS+1))
else
  echo "FAIL [sync PR + --squash → blocked]: rc=$got_rc stderr=${got_stderr:0:300}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}sync-squash-blocked "
fi

# Case S2: sync PR + --merge + valid markers → PASSES (the correct path)
sb=$(make_sandbox_with_sync_branch "sync/main-to-dev-after-v2.3.0")
write_rex_marker "$sb" 301
write_ceo_marker_structured "$sb" 301
cmd="gh pr merge 301 --repo me2resh/apexyard --merge --delete-branch"
input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "0" ] && [ -z "$got_stderr" ]; then
  echo "PASS [sync PR + --merge + valid markers → passes (apexyard#459)]"; PASS=$((PASS+1))
else
  echo "FAIL [sync PR + --merge + valid markers → passes]: rc=$got_rc stderr=${got_stderr:0:300}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}sync-merge-passes "
fi

# Case S3: non-sync PR + --squash + valid markers → PASSES (guard narrowly scoped)
sb=$(make_sandbox_non_sync)
write_rex_marker "$sb" 302
write_ceo_marker_structured "$sb" 302
cmd="gh pr merge 302 --repo me2resh/apexyard --squash --delete-branch"
input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "0" ] && [ -z "$got_stderr" ]; then
  echo "PASS [non-sync PR + --squash still passes (guard narrowly scoped, apexyard#459)]"; PASS=$((PASS+1))
else
  echo "FAIL [non-sync PR + --squash guard scope]: rc=$got_rc stderr=${got_stderr:0:300}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}non-sync-squash-unaffected "
fi

# Case S4: sync PR + `gh api ... merge_method=squash` → BLOCKED
# (the gh-api bypass shape — the gap that motivated #47; must be caught too)
sb=$(make_sandbox_with_sync_branch "sync/main-to-dev-after-v2.3.0")
write_rex_marker "$sb" 303
write_ceo_marker_structured "$sb" 303
cmd="gh api repos/me2resh/apexyard/pulls/303/merge -X PUT -f merge_method=squash"
input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -q "cannot be squash-merged"; then
  echo "PASS [sync PR + gh-api merge_method=squash → blocked (apexyard#459, #47 bypass class)]"; PASS=$((PASS+1))
else
  echo "FAIL [sync PR + gh-api merge_method=squash → blocked]: rc=$got_rc stderr=${got_stderr:0:300}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}sync-ghapi-squash-blocked "
fi

# Case S5: sync PR + `gh api ... merge_method=merge` → PASSES (correct gh-api path)
sb=$(make_sandbox_with_sync_branch "sync/main-to-dev-after-v2.3.0")
write_rex_marker "$sb" 304
write_ceo_marker_structured "$sb" 304
cmd="gh api repos/me2resh/apexyard/pulls/304/merge -X PUT -f merge_method=merge"
input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "0" ] && [ -z "$got_stderr" ]; then
  echo "PASS [sync PR + gh-api merge_method=merge → passes (apexyard#459)]"; PASS=$((PASS+1))
else
  echo "FAIL [sync PR + gh-api merge_method=merge → passes]: rc=$got_rc stderr=${got_stderr:0:300}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}sync-ghapi-merge-passes "
fi

# --- Cross-repo collision regression test (#485) ----------------------
#
# Proves that a marker for repo A's PR #N is DISTINCT from a marker for
# repo B's PR #N — they must never collide, and one must not satisfy the
# gate for the other.

# Helper: make a sandbox whose gh shim returns a specific repo for headRepository.
make_sandbox_for_repo() {
  local repo="${1:-me2resh/apexyard}"
  local sb
  sb=$(make_sandbox)
  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"pr view"*"headRefOid"*)     echo "$FIXED_SHA" ;;
  *"pr view"*"headRefName"*)    echo "feature/test" ;;
  *"pr view"*"headRepository"*) echo "$repo" ;;
  *) ;;
esac
exit 0
EOF
  chmod +x "$sb/bin/gh"
  echo "$sb"
}

# Case R1: marker for repo-A's PR #100 does NOT satisfy gate for repo-B's PR #100.
sb=$(make_sandbox_for_repo "org-b/project-b")
# Write markers for repo-A's PR #100 (different repo slug → different filename).
write_rex_marker "$sb" 100 "$FIXED_SHA" "org-a/project-a"
write_ceo_marker_structured "$sb" 100 "$FIXED_SHA" "org-a/project-a"
# Run the gate for repo-B's PR #100 — it should be BLOCKED (markers are for the wrong repo).
input=$(jq -nc --arg c "gh pr merge 100 --repo org-b/project-b --squash" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -qE "no recorded code-reviewer|no CEO approval marker"; then
  echo "PASS [cross-repo: repo-A PR#100 markers do NOT satisfy repo-B PR#100 gate (#485)]"
  PASS=$((PASS+1))
else
  echo "FAIL [cross-repo: repo-A PR#100 markers must not satisfy repo-B PR#100 gate]: rc=$got_rc stderr=${got_stderr:0:300}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}cross-repo-collision-blocked "
fi

# Case R2: marker for repo-B's PR #100 DOES satisfy gate for repo-B's PR #100.
sb=$(make_sandbox_for_repo "org-b/project-b")
write_rex_marker "$sb" 100 "$FIXED_SHA" "org-b/project-b"
write_ceo_marker_structured "$sb" 100 "$FIXED_SHA" "org-b/project-b"
input=$(jq -nc --arg c "gh pr merge 100 --repo org-b/project-b --squash" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "0" ] && [ -z "$got_stderr" ]; then
  echo "PASS [cross-repo: repo-B PR#100 markers DO satisfy repo-B PR#100 gate (#485)]"
  PASS=$((PASS+1))
else
  echo "FAIL [cross-repo: correct markers must satisfy same-repo gate]: rc=$got_rc stderr=${got_stderr:0:300}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}cross-repo-same-repo-passes "
fi

# Case R3: both repo-A and repo-B have PR #100 with markers — they coexist without collision.
sb=$(make_sandbox_for_repo "org-a/project-a")
write_rex_marker "$sb" 100 "$FIXED_SHA" "org-a/project-a"
write_ceo_marker_structured "$sb" 100 "$FIXED_SHA" "org-a/project-a"
write_rex_marker "$sb" 100 "$FIXED_SHA" "org-b/project-b"
write_ceo_marker_structured "$sb" 100 "$FIXED_SHA" "org-b/project-b"
# Verify both marker files exist with distinct names.
marker_a=$(review_marker_path "org-a/project-a" 100 rex "$sb")
marker_b=$(review_marker_path "org-b/project-b" 100 rex "$sb")
if [ "$marker_a" != "$marker_b" ] && [ -f "$marker_a" ] && [ -f "$marker_b" ]; then
  echo "PASS [cross-repo: same PR# in two repos produces distinct, coexisting marker files (#485)]"
  PASS=$((PASS+1))
else
  echo "FAIL [cross-repo: distinct markers for same PR# in two repos]: a=$marker_a b=$marker_b" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}cross-repo-distinct-files "
fi
rm -rf "$sb"

# --- warn-review-marker-write.sh tests (#494) -------------------------
#
# The advisory hook fires when a Write or Bash command targets a
# *-rex.approved or *-ceo.approved file. It must always exit 0.

WARN_HOOK_SRC="$SRC_ROOT/.claude/hooks/warn-review-marker-write.sh"
if [ ! -f "$WARN_HOOK_SRC" ]; then
  echo "FAIL: warn-review-marker-write.sh not found at $WARN_HOOK_SRC" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}warn-hook-missing "
else
  # W1: Write to a rex.approved path → advisory fires, exit 0
  input=$(jq -nc --arg fp ".claude/session/reviews/me2resh__apexyard__42-rex.approved" \
    '{tool_name:"Write", tool_input:{file_path:$fp, content:"abc"}}')
  got_stderr=$(echo "$input" | bash "$WARN_HOOK_SRC" 2>&1 >/dev/null)
  got_rc=$?
  if [ "$got_rc" = "0" ] && echo "$got_stderr" | grep -q "ADVISORY"; then
    echo "PASS [warn-hook: Write to rex.approved → advisory + exit 0 (#494)]"; PASS=$((PASS+1))
  else
    echo "FAIL [warn-hook: Write to rex.approved → advisory + exit 0]: rc=$got_rc stderr=${got_stderr:0:200}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}warn-hook-write-rex "
  fi

  # W2: Bash echo redirect to ceo.approved → advisory fires, exit 0
  input=$(jq -nc --arg c "echo 'sha=abc' > .claude/session/reviews/me2resh__apexyard__42-ceo.approved" \
    '{tool_name:"Bash", tool_input:{command:$c}}')
  got_stderr=$(echo "$input" | bash "$WARN_HOOK_SRC" 2>&1 >/dev/null)
  got_rc=$?
  if [ "$got_rc" = "0" ] && echo "$got_stderr" | grep -q "ADVISORY"; then
    echo "PASS [warn-hook: Bash echo to ceo.approved → advisory + exit 0 (#494)]"; PASS=$((PASS+1))
  else
    echo "FAIL [warn-hook: Bash echo to ceo.approved → advisory + exit 0]: rc=$got_rc stderr=${got_stderr:0:200}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}warn-hook-bash-ceo "
  fi

  # W3: Write to an unrelated path → no advisory, exit 0
  input=$(jq -nc --arg fp "src/some-other-file.ts" \
    '{tool_name:"Write", tool_input:{file_path:$fp, content:"x"}}')
  got_stderr=$(echo "$input" | bash "$WARN_HOOK_SRC" 2>&1 >/dev/null)
  got_rc=$?
  if [ "$got_rc" = "0" ] && [ -z "$got_stderr" ]; then
    echo "PASS [warn-hook: unrelated Write → no advisory, exit 0 (#494)]"; PASS=$((PASS+1))
  else
    echo "FAIL [warn-hook: unrelated Write → must be silent]: rc=$got_rc stderr=${got_stderr:0:200}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}warn-hook-unrelated-path "
  fi

  # W4: Bash command with no marker path → no advisory, exit 0
  input=$(jq -nc --arg c "gh pr view 42" \
    '{tool_name:"Bash", tool_input:{command:$c}}')
  got_stderr=$(echo "$input" | bash "$WARN_HOOK_SRC" 2>&1 >/dev/null)
  got_rc=$?
  if [ "$got_rc" = "0" ] && [ -z "$got_stderr" ]; then
    echo "PASS [warn-hook: non-marker Bash → silent, exit 0 (#494)]"; PASS=$((PASS+1))
  else
    echo "FAIL [warn-hook: non-marker Bash → must be silent]: rc=$got_rc stderr=${got_stderr:0:200}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}warn-hook-nonmarker-bash "
  fi
fi

# --- Summary ----------------------------------------------------------

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
