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

for f in "$HOOK_SRC" "$LIB_PR"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required source missing: $f" >&2
    exit 1
  fi
done

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
  cp "$HOOK_SRC" "$sb/.claude/hooks/block-unreviewed-merge.sh"
  cp "$LIB_PR"   "$sb/.claude/hooks/_lib-extract-pr.sh"
  chmod +x "$sb/.claude/hooks/block-unreviewed-merge.sh"

  # Mock `gh` so resolve_pr_head returns FIXED_SHA. The hook calls
  # `gh pr view <N> --json headRefOid -q '.headRefOid'` (or a similar
  # shape) — return the fixed SHA on stdout, no network involved.
  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
# Minimal gh shim for test_block_unreviewed_merge. Returns FIXED_SHA for
# any 'gh pr view ... headRefOid' call; pass-through everything else as
# a no-op (exit 0, no stdout). Real test invocations only need pr-view.
case "\$*" in
  *"pr view"*"headRefOid"*) echo "$FIXED_SHA" ;;
  *) ;;
esac
exit 0
EOF
  chmod +x "$sb/bin/gh"

  echo "$sb"
}

# Marker writers -------------------------------------------------------

write_rex_marker() {
  # Bare SHA on line 1 — Rex's format is unchanged.
  local sb="$1" pr="$2" sha="${3:-$FIXED_SHA}"
  echo "$sha" > "$sb/.claude/session/reviews/${pr}-rex.approved"
}

write_ceo_marker_structured() {
  # Valid v2 structured marker.
  local sb="$1" pr="$2" sha="${3:-$FIXED_SHA}"
  cat > "$sb/.claude/session/reviews/${pr}-ceo.approved" <<EOF
sha=${sha}
approved_by=user
approved_at=2026-05-03T20:00:00Z
skill_version=2
approval_summary="test approval"
EOF
}

write_ceo_marker_legacy_bare() {
  # Pre-#48 format: bare SHA, single line.
  local sb="$1" pr="$2" sha="${3:-$FIXED_SHA}"
  echo "$sha" > "$sb/.claude/session/reviews/${pr}-ceo.approved"
}

write_ceo_marker_missing_field() {
  # Has sha= and skill_version but NO approved_by.
  local sb="$1" pr="$2"
  cat > "$sb/.claude/session/reviews/${pr}-ceo.approved" <<EOF
sha=${FIXED_SHA}
skill_version=2
EOF
}

write_ceo_marker_wrong_approved_by() {
  # Has approved_by=robot instead of approved_by=user.
  local sb="$1" pr="$2"
  cat > "$sb/.claude/session/reviews/${pr}-ceo.approved" <<EOF
sha=${FIXED_SHA}
approved_by=robot
skill_version=2
EOF
}

write_ceo_marker_old_version() {
  # skill_version=1 (legacy format that should be rejected).
  local sb="$1" pr="$2"
  cat > "$sb/.claude/session/reviews/${pr}-ceo.approved" <<EOF
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
  got_stderr=$(cd "$sb" && PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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
got_stderr=$(cd "$sb" && PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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
got_stderr=$(cd "$sb" && PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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
cat > "$sb/.claude/session/reviews/211-ceo.approved" <<EOF
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
# Copy _lib-ops-root.sh into the sandbox's hook dir.
cp "$SRC_ROOT/.claude/hooks/_lib-ops-root.sh" "$sb/.claude/hooks/_lib-ops-root.sh"
# Build a workspace clone underneath, with its own git toplevel.
mkdir -p "$sb/workspace/demo"
( cd "$sb/workspace/demo" && git init -q )
# Markers exist at the OPS FORK's reviews dir (where the agent + skill write).
write_rex_marker "$sb" 212
write_ceo_marker_structured "$sb" 212
# Run the hook from inside workspace/demo cwd (not the ops fork).
input=$(jq -nc --arg c "gh pr merge 212 --repo me2resh/apexyard" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb/workspace/demo" && PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash $sb/.claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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
  got_stderr=$(cd "$sb" && PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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
  # Rewrite the gh shim to handle both headRefOid (SHA) and headRefName (branch).
  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"pr view"*"headRefOid"*) echo "$FIXED_SHA" ;;
  *"pr view"*"headRefName"*) echo "$branch_name" ;;
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
  *"pr view"*"headRefOid"*) echo "$FIXED_SHA" ;;
  *"pr view"*"headRefName"*) echo "feature/GH-99-something" ;;
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
got_stderr=$(cd "$sb" && PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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
got_stderr=$(cd "$sb" && PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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
got_stderr=$(cd "$sb" && PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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
got_stderr=$(cd "$sb" && PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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
got_stderr=$(cd "$sb" && PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "0" ] && [ -z "$got_stderr" ]; then
  echo "PASS [sync PR + gh-api merge_method=merge → passes (apexyard#459)]"; PASS=$((PASS+1))
else
  echo "FAIL [sync PR + gh-api merge_method=merge → passes]: rc=$got_rc stderr=${got_stderr:0:300}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}sync-ghapi-merge-passes "
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
