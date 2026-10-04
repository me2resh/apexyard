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
LIB_BEHIND="$SRC_ROOT/.claude/hooks/_lib-merge-behind.sh"

for f in "$HOOK_SRC" "$LIB_PR" "$LIB_MARKERS" "$LIB_BEHIND"; do
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
  # Sandbox blocks creating a path named ".git". Use an explicit gitdir.
  mkdir -p "$sb/gitdir/objects" "$sb/gitdir/refs/heads"
  printf 'ref: refs/heads/main\n' > "$sb/gitdir/HEAD"
  printf '%s\n' \
    '[core]' \
    '	repositoryformatversion = 0' \
    '	filemode = true' \
    '	bare = false' \
    '	logallrefupdates = true' > "$sb/gitdir/config"
  (
    cd "$sb" || exit 1
    export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb"
    git config user.email "test@example.com"
    git config user.name "test"
    : > onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
  ) || return 1
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session/reviews" "$sb/bin"
  cp "$HOOK_SRC"    "$sb/.claude/hooks/block-unreviewed-merge.sh"
  cp "$LIB_PR"      "$sb/.claude/hooks/_lib-extract-pr.sh"
  cp "$LIB_MARKERS" "$sb/.claude/hooks/_lib-review-markers.sh"
  cp "$LIB_BEHIND"  "$sb/.claude/hooks/_lib-merge-behind.sh"
  chmod +x "$sb/.claude/hooks/block-unreviewed-merge.sh"
  # The hook sources the shared config reader (me2resh/apexyard#957, the
  # configurable human_approver_title key) — mirror the same sandbox setup
  # test_warn_stale_review_markers.sh already uses: copy the reader + the
  # shipped defaults so config lookups resolve the same way they do in a
  # real fork. Optional: harmless no-op for every case that doesn't touch
  # review_markers.human_approver_title (they get the default "CEO").
  if [ -f "$SRC_ROOT/.claude/hooks/_lib-read-config.sh" ]; then
    cp "$SRC_ROOT/.claude/hooks/_lib-read-config.sh" "$sb/.claude/hooks/_lib-read-config.sh"
  fi
  if [ -f "$SRC_ROOT/.claude/project-config.defaults.json" ]; then
    cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  fi

  # Mock `gh` so resolve_pr_head returns FIXED_SHA. The hook calls
  # `gh pr view <N> --json headRefOid -q '.headRefOid'` (or a similar
  # shape) — return the fixed SHA on stdout, no network involved.
  # Also handles headRefName (sync-PR guard) and headRepository (repo extraction, #485).
  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
# Minimal gh shim for test_block_unreviewed_merge.
case "\$*" in
  *"pr view"*"headRefOid"*)        echo "$FIXED_SHA" ;;
  *"pr view"*"headRefName"*)       echo "feature/GH-99-test" ;;
  *"pr view"*"headRepository"*)    echo "me2resh/apexyard" ;;
  *"pr view"*"--json number"*)      echo "1546" ;;
  *"pr view"*"mergeStateStatus"*)  echo "\${MOCK_MERGE_STATE:-CLEAN}" ;;
  *"pr view"*"baseRefName"*)       echo "\${MOCK_BASE_BRANCH:-dev}" ;;
  # #1386: is_pr_behind_base reads behind_by from the compare API, not
  # mergeStateStatus. \$MOCK_BEHIND_BY lets a case say "the PR IS behind"
  # independent of whatever \$MOCK_MERGE_STATE says — the exact split #1386
  # reported (a behind PR whose mergeStateStatus reads CLEAN or BLOCKED).
  *"api "*"compare/"*)             echo "\${MOCK_BEHIND_BY:-0}" ;;
  *) ;;
esac
exit 0
EOF
  chmod +x "$sb/bin/gh"

  echo "$sb"
}


# sb_git <sandbox> <git-args...> — git against a make_sandbox checkout (no ".git" path).
sb_git() {
  local sb="$1"
  shift
  GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" git "$@"
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
  local label="$1" want_rc="$2" want_stderr_regex="$3" sb="$4" pr="$5" repo="${6:-me2resh/apexyard}"
  local cmd="gh pr merge $pr --repo $repo --squash"
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
  local got_stderr got_rc
  # APEXYARD_OPS_DISABLE_PIN=1: force walk-up resolution so the sandbox's ops root
  # is used, not the real session pin (avoids marker-home mismatch in CI/worktrees).
  # Export GIT_DIR/GIT_WORK_TREE so the hook and the gh mock both see the
  # sandbox repo (no ".git" path — Cursor sandbox blocks that name).
  got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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

# 3b. Configurable human_approver_title (me2resh/apexyard#957) — a custom
# title configured via .claude/project-config.json flows through to the
# BLOCKED message's prose, while the marker filename/path printed alongside
# it is untouched (still "-ceo.approved"). This does NOT change the default
# behaviour asserted by case 3 above — that case's sandbox has no override
# file, so it still reads the shipped default ("CEO") and its literal
# "no CEO approval marker" assertion is unaffected by this feature existing.
sb=$(make_sandbox)
write_rex_marker "$sb" 957
cat > "$sb/.claude/project-config.json" <<'EOF'
{"review_markers": {"human_approver_title": "Maintainer"}}
EOF
run_case "custom human_approver_title flows through to BLOCKED message (#957)" 2 "no Maintainer approval marker" "$sb" 957

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
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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
got_stderr=$(cd "$sb/workspace/demo" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash $sb/.claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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
  got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && printf '%s' "$input" | APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash .claude/hooks/block-unreviewed-merge.sh 2>&1 >/dev/null)
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

# B1: the branch PR is fully approved. An argv merge targets another PR, so
# using the branch PR's approvals would authorize the wrong merge.
for argv_target in "'5'" "os.environ['PR']"; do
  sb=$(make_sandbox)
  write_rex_marker "$sb" 1546
  write_ceo_marker_structured "$sb" 1546
  run_case_custom_cmd "argv merge target $argv_target does not use branch PR" 2 \
    "cannot resolve" "$sb" \
    "python3 -c \"import subprocess, os; subprocess.run(['gh','pr','merge',$argv_target])\""
done

# #1552: gap shapes and wrong-PR wrappers must block even when the branch PR
# is fully approved. Grouped: padded/path+flags, glab, api-comma, split-tail,
# backticks+join, nested wrappers (sh -c / xargs / perl qw).
sb=$(make_sandbox)
write_rex_marker "$sb" 1546
write_ceo_marker_structured "$sb" 1546
run_case_custom_cmd "1552 padded/path gh argv blocks despite branch approval" 2 \
  "cannot resolve" "$sb" \
  "python3 -c \"import subprocess; subprocess.run(['/usr/bin/gh','-R','o/r','pr','merge','5'])\""
sb=$(make_sandbox)
write_rex_marker "$sb" 1546
write_ceo_marker_structured "$sb" 1546
run_case_custom_cmd "1552 glab argv blocks despite branch approval" 2 \
  "cannot resolve" "$sb" \
  "python3 -c \"import subprocess; subprocess.run(['glab','mr','merge','5'])\""
sb=$(make_sandbox)
write_rex_marker "$sb" 1546
write_ceo_marker_structured "$sb" 1546
run_case_custom_cmd "1552 api argv with comma in element blocks" 2 \
  "cannot resolve" "$sb" \
  "python3 -c \"import subprocess; subprocess.run(['gh','api','-f','m=a,b','repos/o/r/pulls/5/merge'])\""
sb=$(make_sandbox)
write_rex_marker "$sb" 1546
write_ceo_marker_structured "$sb" 1546
api_bt_cmd=$(cat <<'CMD'
python3 -c "import subprocess; subprocess.run(['gh','api','-X','PUT','-f','commit_message=fix `x`','repos/o/r/pulls/5/merge'])"
CMD
)
run_case_custom_cmd "1552 api argv backtick in element blocks" 2 \
  "cannot resolve" "$sb" "$api_bt_cmd"
sb=$(make_sandbox)
write_rex_marker "$sb" 1546
write_ceo_marker_structured "$sb" 1546
run_case_custom_cmd "1552 split-tail element blocks" 2 \
  "cannot resolve" "$sb" \
  "node -e \"require('child_process').execFileSync('gh', 'pr merge 5'.split(' '))\""
sb=$(make_sandbox)
write_rex_marker "$sb" 1546
write_ceo_marker_structured "$sb" 1546
run_case_custom_cmd "1552 joined list argv blocks" 2 \
  "cannot resolve" "$sb" \
  "python3 -c \"import subprocess; subprocess.run(['gh','pr'] + ['merge','5'])\""
sb=$(make_sandbox)
write_rex_marker "$sb" 1546
write_ceo_marker_structured "$sb" 1546
run_case_custom_cmd "1552 JS backtick argv blocks" 2 \
  "cannot resolve" "$sb" \
  'node -e "require('"'"'child_process'"'"').spawnSync('"'"'gh'"'"',[`pr`,`merge`,`5`])"'
sb=$(make_sandbox)
write_rex_marker "$sb" 1546
write_ceo_marker_structured "$sb" 1546
run_case_custom_cmd "1552 sh -c argv wrapper blocks (wrong-PR)" 2 \
  "cannot resolve" "$sb" \
  "python3 -c \"import subprocess; subprocess.run(['sh','-c','gh pr merge 5'])\""
sb=$(make_sandbox)
write_rex_marker "$sb" 1546
write_ceo_marker_structured "$sb" 1546
run_case_custom_cmd "1552 xargs merge blocks (wrong-PR)" 2 \
  "cannot resolve" "$sb" \
  "echo 5 | xargs gh pr merge"
# Round-2: separators inside the quoted -c script must stay opaque.
_m1552_gate=$(printf '%s %s %s' gh pr merge)
sb=$(make_sandbox)
write_rex_marker "$sb" 1546
write_ceo_marker_structured "$sb" 1546
run_case_custom_cmd "1552 xargs sh -c quoted semicolon blocks" 2 \
  "cannot resolve" "$sb" \
  "xargs -I{} sh -c 'cd x; ${_m1552_gate} {}'"
sb=$(make_sandbox)
write_rex_marker "$sb" 1546
write_ceo_marker_structured "$sb" 1546
run_case_custom_cmd "1552 xargs sh -c quoted newline blocks" 2 \
  "cannot resolve" "$sb" \
  "$(printf "xargs -I{} sh -c 'cd x\n%s {}'" "$_m1552_gate")"
# Round-3 quote desyncs must block even with valid markers for branch PR 1546.
_q1552_comment=$(printf "true # don't\necho 5 | xargs -I{} sh -c 'x; %s {}'" "$_m1552_gate")
_q1552_heredoc=$(printf "cat <<EOT\ndon't\nEOT\necho 5 | xargs -I{} sh -c 'x; %s {}'" "$_m1552_gate")
_q1552_ansi=$(printf "echo 5 | xargs -I{} sh -c \$'a\\'b; %s {}'" "$_m1552_gate")
_q1552_unclosed=$(printf "echo 'unfinished; echo 5 | xargs -I{} sh -c 'x; %s {}'" "$_m1552_gate")
for _q1552_name in comment heredoc ansi unclosed; do
  sb=$(make_sandbox)
  write_rex_marker "$sb" 1546
  write_ceo_marker_structured "$sb" 1546
  case "$_q1552_name" in
    comment) _q1552_cmd=$_q1552_comment ;;
    heredoc) _q1552_cmd=$_q1552_heredoc ;;
    ansi) _q1552_cmd=$_q1552_ansi ;;
    unclosed) _q1552_cmd=$_q1552_unclosed ;;
  esac
  run_case_custom_cmd "1552 round-3 $_q1552_name blocks" 2 \
    "cannot resolve" "$sb" "$_q1552_cmd"
done
sb=$(make_sandbox)
write_rex_marker "$sb" 1546
write_ceo_marker_structured "$sb" 1546
run_case_custom_cmd "1552 perl qw merge blocks (wrong-PR)" 2 \
  "cannot resolve" "$sb" \
  "perl -e 'system qw(gh pr merge 5)'"
sb=$(make_sandbox)
write_rex_marker "$sb" 1546
write_ceo_marker_structured "$sb" 1546
run_case_custom_cmd "1552 perl qw glab mr blocks (wrong-PR)" 2 \
  "cannot resolve" "$sb" \
  "perl -e 'system qw(glab mr merge 5)'"

# #1525: quoted data passes. Executable heredocs and a real merge still block.
data_cmd=$(cat <<'CMD'
cat > /tmp/brief.md <<'EOF'
run: gh pr merge 315 --repo $TEST_REPO --squash
EOF
CMD
)
sb=$(make_sandbox)
run_case_custom_cmd "#1525 data heredoc passes" 0 "" "$sb" "$data_cmd"
for shell in bash sh zsh; do
  sb=$(make_sandbox)
  run_case_custom_cmd "#1525 $shell heredoc blocks" 2 "unexpanded" "$sb" \
    "$(printf "%s <<'EOF'\ngh pr merge \$PR --repo \$R\nEOF" "$shell")"
done
sb=$(make_sandbox)
run_case_custom_cmd "#1525 python subprocess heredoc blocks" 2 "BLOCKED" "$sb" \
  $'python3 - <<\'EOF\'\nimport subprocess\nsubprocess.run(["gh","pr","merge", PR, "--repo", R])\nEOF'
sb=$(make_sandbox)
run_case_custom_cmd "#1525 python edit with sample merge stays blocked" 2 "unexpanded" "$sb" \
  $'python3 - <<\'EOF\'\nline = "gh pr merge 315 --repo $TEST_REPO --squash"\nEOF'
sb=$(make_sandbox)
run_case_custom_cmd "#1525 eval heredoc blocks" 2 "unexpanded" "$sb" \
  $'eval "$(cat <<\'EOF\'\ngh pr merge $PR --repo $R\nEOF\n)"'
sb=$(make_sandbox)
run_case_custom_cmd "#1525 source stdin heredoc blocks" 2 "unexpanded" "$sb" \
  $'source /dev/stdin <<\'EOF\'\ngh pr merge $PR --repo $R\nEOF'
sb=$(make_sandbox)
run_case_custom_cmd "#1525 cat piped to bash blocks" 2 "unexpanded" "$sb" \
  $'cat <<\'EOF\' | bash\ngh pr merge $PR --repo $R\nEOF'
sb=$(make_sandbox)
run_case_custom_cmd "#1525 unquoted substitution blocks" 2 "unexpanded" "$sb" \
  $'cat <<EOF\n$(gh pr merge $X)\nEOF'
sb=$(make_sandbox)
run_case_custom_cmd "#1525 real variable merge beside data blocks" 2 "unexpanded" "$sb" \
  "$data_cmd"$'\ngh pr merge $PR'

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
# The guard in block-unreviewed-merge.sh refuses --squash/--rebase on PRs
# whose head branch is a release-sync or /update sync branch. The guard fires
# on both merge shapes (gh pr merge + gh api .../merge).
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
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -Eq "cannot (be squash-merged|use squash or rebase)"; then
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
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -Eq "cannot (be squash-merged|use squash or rebase)"; then
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
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "0" ] && [ -z "$got_stderr" ]; then
  echo "PASS [sync PR + gh-api merge_method=merge → passes (apexyard#459)]"; PASS=$((PASS+1))
else
  echo "FAIL [sync PR + gh-api merge_method=merge → passes]: rc=$got_rc stderr=${got_stderr:0:300}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}sync-ghapi-merge-passes "
fi

# Case S6: /update sync branch + --squash → BLOCKED (#1301)
sb=$(make_sandbox_with_sync_branch "chore/#1301-sync-upstream-apexyard")
write_rex_marker "$sb" 305
write_ceo_marker_structured "$sb" 305
cmd="gh pr merge 305 --repo me2resh/apexyard --squash --delete-branch"
input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -q "cannot use squash or rebase"; then
  echo "PASS [/update sync PR + --squash → blocked (apexyard#1301)]"; PASS=$((PASS+1))
else
  echo "FAIL [/update sync PR + --squash → blocked]: rc=$got_rc stderr=${got_stderr:0:300}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}update-sync-squash-blocked "
fi

# Case S7: /update sync PR + tracker_pr_merge positional squash → BLOCKED
# The approve-merge skill calls the tracker-agnostic wrapper with the strategy
# as its fourth positional argument, so flag-only detection must not be enough.
sb=$(make_sandbox_with_sync_branch "chore/#1301-sync-upstream-apexyard")
write_rex_marker "$sb" 306
write_ceo_marker_structured "$sb" 306
cmd="tracker_pr_merge me2resh/apexyard 306 squash true '' ''"
input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -q "cannot use squash or rebase"; then
  echo "PASS [/update sync PR + tracker_pr_merge positional squash → blocked (apexyard#1301)]"; PASS=$((PASS+1))
else
  echo "FAIL [/update sync PR + tracker_pr_merge positional squash → blocked]: rc=$got_rc stderr=${got_stderr:0:300}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}update-sync-tracker-squash-blocked "
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
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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

# --- tracker_pr_merge wrapper shape tests (#759 gate-coverage regression) ---
#
# Hakim's review of #759 found that the gate hooks match the OUTER Bash
# command text, not a call made by a sourced shell function — so
# `/approve-merge`'s new `tracker_pr_merge <repo> <pr> <strategy> <del>`
# wrapper sailed through completely ungated (is_merge_command never matched
# it). These cases prove BOTH halves of the fix: the wrapper form is now
# gate-recognised (is_merge_command/extractors), AND the sanctioned
# /approve-merge flow — which writes both markers BEFORE calling the wrapper
# — is unaffected by that new recognition.

run_case_wrapper() {
  local label="$1" want_rc="$2" want_stderr_regex="$3" sb="$4" pr="$5" repo="${6:-me2resh/apexyard}"
  # The exact shape /approve-merge's SKILL.md step 7 emits: source the lib,
  # then call tracker_pr_merge inside a command substitution.
  local cmd
  cmd=$(printf '. "%s/.claude/hooks/_lib-tracker.sh"\nMERGE_RESULT=$(tracker_pr_merge "%s" "%s" "squash" true)' "$sb" "$repo" "$pr")
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
  local got_stderr got_rc
  got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
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

# W-a/b: the wrapper form MATCHES is_merge_command and the extractors pull the
# right pr/repo — proven indirectly: a wrapper call with NO markers at all
# must be BLOCKED with the same "no recorded code-reviewer" message the gh
# shape produces (if is_merge_command didn't match, or the extractor pulled
# the wrong pr/repo, this would silently exit 0 instead).
sb=$(make_sandbox)
run_case_wrapper "wrapper: no markers → blocked (proves is_merge_command matches + pr/repo extracted)" 2 "no recorded code-reviewer" "$sb" 300

# W-c: the sanctioned /approve-merge flow — CEO marker written in step 5,
# BEFORE the step-7 wrapper call — still passes once both markers exist.
sb=$(make_sandbox)
write_rex_marker "$sb" 301
write_ceo_marker_structured "$sb" 301
run_case_wrapper "wrapper: valid rex + valid v2 ceo → allows (legit /approve-merge flow unaffected)" 0 "" "$sb" 301

# W-d: wrapper call with Rex approved but NO CEO marker → blocked. This is
# the "out-of-skill tracker_pr_merge call" Hakim's fix asked to verify stays
# blocked — a bare wrapper invocation with no CEO sign-off must not merge.
sb=$(make_sandbox)
write_rex_marker "$sb" 302
run_case_wrapper "wrapper: rex only, no ceo marker → blocked (out-of-skill call stays gated)" 2 "no CEO approval marker" "$sb" 302

# W-e: cross-repo scoping still holds for the wrapper form — markers for a
# DIFFERENT repo's same-numbered PR must not satisfy this repo's gate.
sb=$(make_sandbox_for_repo "org-b/project-b")
write_rex_marker "$sb" 100 "$FIXED_SHA" "org-a/project-a"
write_ceo_marker_structured "$sb" 100 "$FIXED_SHA" "org-a/project-a"
run_case_wrapper "wrapper: cross-repo markers do not satisfy the gate (#485 parity)" 2 "no recorded code-reviewer|no CEO approval marker" "$sb" 100 "org-b/project-b"

# --- warn-review-marker-write.sh tests (#494; BLOCKING in #843, returned
# --- to ADVISORY in #1026 per AgDR-0111) -------------------------------
#
# The hook fires when a Write or Bash command targets a *-rex.approved,
# *-ceo.approved, *-security.approved, or *-architecture.approved file.
# ALL roles are advisory: the hook warns and always exits 0 (#1026,
# AgDR-0111). A matching .claude/session/active-reviewer marker suppresses
# the warning for the sanctioned reviewer; it does not unblock anything,
# because nothing is blocked. Full case coverage
# (matching marker, kind/pr/repo mismatch, legacy bare filenames, security +
# architecture roles) lives in the dedicated test_warn_review_marker_write.sh;
# this file only keeps the original #494 smoke assertions in sync with the
# new default behaviour.

WARN_HOOK_SRC="$SRC_ROOT/.claude/hooks/warn-review-marker-write.sh"
if [ ! -f "$WARN_HOOK_SRC" ]; then
  echo "FAIL: warn-review-marker-write.sh not found at $WARN_HOOK_SRC" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}warn-hook-missing "
else
  # W1: Write to a rex.approved path, no active-reviewer marker → WARNS, exit 0.
  # Was BLOCKED/exit 2 from #843; returned to advisory in #1026 per AgDR-0111
  # (the marker hook is a BACKSTOP — this file's own hook is the control).
  input=$(jq -nc --arg fp ".claude/session/reviews/me2resh__apexyard__42-rex.approved" \
    '{tool_name:"Write", tool_input:{file_path:$fp, content:"abc"}}')
  got_stderr=$(echo "$input" | bash "$WARN_HOOK_SRC" 2>&1 >/dev/null)
  got_rc=$?
  if [ "$got_rc" = "0" ] && echo "$got_stderr" | grep -q "WARNING"; then
    echo "PASS [warn-hook: Write to rex.approved with no active-reviewer marker → WARNS, exit 0 (#1026)]"; PASS=$((PASS+1))
  else
    echo "FAIL [warn-hook: Write to rex.approved → WARNS, exit 0]: rc=$got_rc stderr=${got_stderr:0:200}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}warn-hook-write-rex "
  fi

  # W2: Bash echo redirect to ceo.approved → advisory fires, exit 0
  input=$(jq -nc --arg c "echo 'sha=abc' > .claude/session/reviews/me2resh__apexyard__42-ceo.approved" \
    '{tool_name:"Bash", tool_input:{command:$c}}')
  got_stderr=$(echo "$input" | bash "$WARN_HOOK_SRC" 2>&1 >/dev/null)
  got_rc=$?
  if [ "$got_rc" = "0" ] && echo "$got_stderr" | grep -q "VIOLATION"; then
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

# --- Fail-closed on jq-unavailable/unparseable input (#965) ------------
#
# make_sandbox_broken_jq installs a `jq` stub in $sb/bin that ALWAYS fails
# (exit 1, no stdout) — same code path as jq being entirely missing from
# PATH, since either way `jq -r '.tool_input.command // empty'` yields
# nothing. $sb/bin is prepended to PATH by run_case_custom_cmd, so this
# stub shadows the real jq for the duration of the hook's invocation only.
make_sandbox_broken_jq() {
  local sb
  sb=$(make_sandbox)
  cat > "$sb/bin/jq" <<'EOF'
#!/bin/bash
# Simulates a broken/unavailable jq: always fails, no output. See #965.
exit 1
EOF
  chmod +x "$sb/bin/jq"
  echo "$sb"
}

# 14. jq broken + a real `gh pr merge` with NO approval markers at all →
#     must BLOCK (exit 2). Pre-#965 this fell through the old
#     `[ -z "$COMMAND" ] && exit 0` no-op and merged completely ungated.
sb=$(make_sandbox_broken_jq)
run_case_custom_cmd "#965: jq broken, gh pr merge with no markers -> BLOCKS (fail closed)" 2 \
  "cannot evaluate this command" "$sb" \
  "gh pr merge 300 --repo me2resh/apexyard --squash"

# 15. jq broken + a CLEARLY non-merge Bash command → must stay a no-op
#     (exit 0, no stderr). Proves the fail-closed fix does NOT block every
#     Bash command in the session just because jq is broken — only the
#     merge-shaped ones (the boundary the #965 fix is built around).
sb=$(make_sandbox_broken_jq)
cmd="npm test"
input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "0" ] && [ -z "$got_stderr" ]; then
  echo "PASS [#965: jq broken, clearly non-merge command -> stays a no-op]"; PASS=$((PASS+1))
else
  echo "FAIL [#965: jq broken, clearly non-merge command -> stays a no-op]: rc=$got_rc stderr=${got_stderr:0:300}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}jq-broken-nonmerge-noop "
fi

# 16. jq broken + the gh-api merge shape (no `gh pr merge` substring at
#     all) → must still BLOCK. Proves the raw-text fallback detector
#     (is_merge_command reused against $INPUT) recognises every shape the
#     normal parsed-command path recognises, not just the literal
#     `gh pr merge` string.
sb=$(make_sandbox_broken_jq)
run_case_custom_cmd "#965: jq broken, gh-api merge shape -> BLOCKS (fail closed)" 2 \
  "cannot evaluate this command" "$sb" \
  "gh api repos/me2resh/apexyard/pulls/301/merge -X PUT"

# --- Fail-closed on JSON-escaped separators in the raw-payload fallback
#     (#973, Hakim's residual finding on the #965/#969 fix) ------------
#
# The #965 fallback (case 14 above) scans $INPUT — the RAW, still-JSON-
# encoded payload text — directly, because jq (which would normally
# decode it) is unavailable. That works for a normal space-separated
# command because `gh`, `pr`, `merge` and the spaces between them survive
# JSON string-encoding unchanged. But a command whose SEPARATORS are
# themselves JSON-escaped (a literal tab encodes as the two-character
# sequence `\t`) does NOT survive unchanged — those two characters are
# not whitespace to `is_merge_command`'s `\s+` regex, so pre-#973 this
# evaded the fallback detector entirely and the merge sailed through
# ungated. `run_case_custom_cmd` builds the test payload with the REAL
# system jq (`jq -nc --arg c "$cmd" ...`, called before the sandboxed
# broken-jq stub is on PATH), so a literal tab placed in $cmd here is
# correctly JSON-escaped to `\t` in the payload — exactly the shape the
# broken-jq fallback then has to recognise without jq's help.
sb=$(make_sandbox_broken_jq)
tab_cmd=$'gh\tpr\tmerge 305 --repo me2resh/apexyard --squash'
run_case_custom_cmd "#973: jq broken, JSON-escaped-tab merge command -> BLOCKS (fail closed)" 2 \
  "cannot evaluate this command" "$sb" \
  "$tab_cmd"

# 18. jq broken + a clearly non-merge command whose words ALSO happen to
#     be tab-separated (so it exercises the same JSON-escape-normalize
#     code path) → must still stay a no-op. Proves the #973 fix doesn't
#     turn every tab-containing payload into a false-positive block —
#     only ones that are merge-shaped once the escapes are decoded.
sb=$(make_sandbox_broken_jq)
tab_nonmerge_cmd=$'echo\tnot\ta\tmerge\tcommand\tat\tall'
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c \
  "echo '$(jq -nc --arg c "$tab_nonmerge_cmd" '{tool_name:"Bash", tool_input:{command:$c}}')' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "0" ] && [ -z "$got_stderr" ]; then
  echo "PASS [#973: jq broken, JSON-escaped-tab NON-merge command -> stays a no-op]"; PASS=$((PASS+1))
else
  echo "FAIL [#973: jq broken, JSON-escaped-tab NON-merge command -> stays a no-op]: rc=$got_rc stderr=${got_stderr:0:300}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}jq-broken-tab-nonmerge-noop "
fi

# --- #1091: forge HEAD unresolvable -> the gate must FAIL CLOSED -------
#
# The gate's integrity property is that marker SHAs are compared against the
# FORGE-reported PR HEAD — state an agent cannot author. Before #1091 the hook
# fell back to `git rev-parse HEAD` (a local, agent-controlled value) when the
# gh call failed, with only a warning. That degraded the one adversarially
# sound boundary into a local read.
#
# DISCRIMINATING BY CONSTRUCTION: the local HEAD and the markers are made to
# AGREE. Under the old fallback the comparison therefore SUCCEEDS and the merge
# is ALLOWED (rc=0). Under fail-closed it is BLOCKED (rc=2). A test using a
# mismatching local HEAD would block both before and after, proving nothing.

make_sandbox_gh_fails() {
  local sb
  sb=$(make_sandbox)
  # gh cannot resolve the HEAD: transient network, expired token, rate limit,
  # and gh-not-installed all surface identically as a failed/empty result.
  # headRefName + headRepository still answer, so exactly ONE thing fails.
  cat > "$sb/bin/gh" <<'GHEOF'
#!/bin/bash
case "$*" in
  *"pr view"*"headRefOid"*)     exit 1 ;;
  *"pr view"*"headRefName"*)    echo "feature/GH-99-test" ;;
  *"pr view"*"headRepository"*) echo "me2resh/apexyard" ;;
  *) ;;
esac
exit 0
GHEOF
  chmod +x "$sb/bin/gh"
  echo "$sb"
}

sb=$(make_sandbox_gh_fails)
# The sandbox's local HEAD — the value the OLD fallback would have used.
local_head=$(sb_git "$sb" rev-parse HEAD 2>/dev/null)
# Markers written to MATCH that local HEAD: the setup most favourable to a
# bypass, where every comparison passes under the old code.
write_rex_marker "$sb" 99 "$local_head"
write_ceo_marker_structured "$sb" 99 "$local_head"
input=$(jq -nc --arg c "gh pr merge 99 --repo me2resh/apexyard --squash" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c \
  "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -qi "resolve"; then
  echo "PASS [#1091: forge HEAD unresolvable + markers matching LOCAL head -> BLOCKED]"; PASS=$((PASS+1))
else
  echo "FAIL [#1091: forge HEAD unresolvable + markers matching LOCAL head -> BLOCKED]: rc=$got_rc stderr=${got_stderr:0:300}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}1091-fail-closed "
fi

# Control: gh healthy -> behaviour unchanged, markers at the forge HEAD pass.
sb=$(make_sandbox)
write_rex_marker "$sb" 99
write_ceo_marker_structured "$sb" 99
input=$(jq -nc --arg c "gh pr merge 99 --repo me2resh/apexyard --squash" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c \
  "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "0" ]; then
  echo "PASS [#1091 control: gh healthy, markers at forge HEAD -> still ALLOWED]"; PASS=$((PASS+1))
else
  echo "FAIL [#1091 control: gh healthy, markers at forge HEAD -> still ALLOWED]: rc=$got_rc stderr=${got_stderr:0:300}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}1091-control-healthy "
fi

# me2resh/apexyard#1405 second-round review, Hakim H2: a missing required
# library (_lib-extract-pr.sh or _lib-review-markers.sh) must BLOCK the
# merge in DEFAULT bash, not just under POSIXLY_CORRECT. Before the
# per-hook `_require_lib` guard, a missing library made `is_merge_command`
# undefined; the negated `if ! is_merge_command "$COMMAND"; then exit 0;
# fi` check then read the resulting "command not found" (127) as "not a
# merge command" and exited 0 — a clean, deliberate-looking allow that the
# dispatcher's fail-closed wrapper (AgDR-0169) cannot see, because nothing
# about that exit code says a gate failed to load.
for lib in _lib-extract-pr.sh _lib-review-markers.sh; do
  for mode in default posix; do
    sb=$(make_sandbox)
    write_rex_marker "$sb" 300
    write_ceo_marker_structured "$sb" 300
    rm -f "$sb/.claude/hooks/$lib"
    input=$(jq -nc --arg c "gh pr merge 300 --repo me2resh/apexyard --squash" '{tool_name:"Bash", tool_input:{command:$c}}')
    if [ "$mode" = "posix" ]; then
      got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c \
        "echo '$input' | POSIXLY_CORRECT=1 bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
    else
      got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c \
        "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
    fi
    got_rc=$?
    rm -rf "$sb"
    label="missing-$lib-blocks-in-$mode-bash"
    if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -qi "BLOCKED"; then
      echo "PASS [$label]"; PASS=$((PASS+1))
    else
      echo "FAIL [$label]: want rc=2 + BLOCKED, got rc=$got_rc stderr=${got_stderr:0:300}" >&2
      FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    fi
  done
done

# me2resh/apexyard#1403 comment (deferred item, addressed here): a missing
# _lib-read-config.sh must not crash the whole script with a raw bash
# "No such file or directory" error under POSIX mode. The library's read
# of `review_markers.human_approver_title` (line ~180) is genuinely
# OPTIONAL — this hook falls back to the "CEO" display title when the
# library is absent — so that read gets a readability check BEFORE the
# `.` call, not a `_require_lib`-style hard block. A SEPARATE, pre-existing
# read further down (`review_markers.require_posted_review`, #1051) is
# deliberately fail-closed when config_get_or is undefined: it must not
# assume that check is off just because it cannot read the setting. So the
# net, correct behaviour is: the gate still BLOCKS overall (via that
# pre-existing check), but with the SAME clean BLOCKED message in both
# default and POSIX-mode bash — never a raw, un-actionable bash crash that
# only POSIX mode used to produce.
for mode in default posix; do
  sb=$(make_sandbox)
  write_rex_marker "$sb" 301
  write_ceo_marker_structured "$sb" 301
  rm -f "$sb/.claude/hooks/_lib-read-config.sh"
  input=$(jq -nc --arg c "gh pr merge 301 --repo me2resh/apexyard --squash" '{tool_name:"Bash", tool_input:{command:$c}}')
  if [ "$mode" = "posix" ]; then
    got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c \
      "echo '$input' | POSIXLY_CORRECT=1 bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
  else
    got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c \
      "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
  fi
  got_rc=$?
  rm -rf "$sb"
  label="missing-optional-_lib-read-config.sh-clean-block-in-$mode-bash"
  if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -qi "BLOCKED"; then
    echo "PASS [$label]"; PASS=$((PASS+1))
  else
    echo "FAIL [$label]: want rc=2 + BLOCKED, got rc=$got_rc stderr=${got_stderr:0:300}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
  fi
done

# AgDR-0169 correction: _lib-merge-behind.sh is OPTIONAL, not a _require_lib
# dependency, unlike _lib-extract-pr.sh and _lib-review-markers.sh above.
# Its only job is to append an advisory note to a block that already fires
# for another reason. A missing/unreadable copy must never turn a healthy,
# fully-approved merge into a block — that would make an advisory-only
# library load-bearing for the whole gate, the exact failure mode the
# _require_lib guard above exists to prevent for the two REQUIRED libraries.
sb=$(make_sandbox)
write_rex_marker "$sb" 302
write_ceo_marker_structured "$sb" 302
rm -f "$sb/.claude/hooks/_lib-merge-behind.sh"
input=$(jq -nc --arg c "gh pr merge 302 --repo me2resh/apexyard --squash" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c \
  "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
label="missing-optional-_lib-merge-behind.sh-does-not-block-a-healthy-merge"
if [ "$got_rc" = "0" ]; then
  echo "PASS [$label]"; PASS=$((PASS+1))
else
  echo "FAIL [$label]: want rc=0 (still allowed), got rc=$got_rc stderr=${got_stderr:0:300}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
fi

# Mirror case: _lib-merge-behind.sh missing AND the merge is blocked for an
# unrelated reason (missing Rex marker) -> still blocks, but the behind-base
# note must not appear (is_pr_behind_base is undefined, so the note function
# returns early instead of crashing or printing "command not found" noise).
sb=$(make_sandbox)
rm -f "$sb/.claude/hooks/_lib-merge-behind.sh"
input=$(jq -nc --arg c "gh pr merge 303 --repo me2resh/apexyard --squash" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 MOCK_BEHIND_BY=5 PATH="$sb/bin:$PATH" bash -c \
  "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
label="missing-optional-_lib-merge-behind.sh-blocks-cleanly-no-note"
if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -q "no recorded code-reviewer" \
   && ! echo "$got_stderr" | grep -qi "also behind its base branch" \
   && ! echo "$got_stderr" | grep -qi "command not found"; then
  echo "PASS [$label]"; PASS=$((PASS+1))
else
  echo "FAIL [$label]: want rc=2, no behind-base note, no 'command not found', got rc=$got_rc stderr=${got_stderr:0:400}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
fi

# --- me2resh/apexyard#1386: optional behind-base note on an EXISTING block ---
#
# block-unreviewed-merge.sh adds NO new blocking condition for a behind-base
# branch. It only appends a note to a block that already fires for another
# reason (here: missing Rex marker). These cases pin that:
#   - the note appears when the compare API reports the PR behind (behind_by > 0)
#   - the note does NOT appear when the PR is not behind
#   - the note appears even when mergeStateStatus reports CLEAN — the exact
#     gap #1386 reported: GitHub only reports mergeStateStatus=BEHIND when
#     the base ruleset has strict_required_status_checks_policy=true, so a
#     PR that is genuinely behind an unprotected base reports CLEAN, BLOCKED,
#     or UNKNOWN instead. A check that read mergeStateStatus alone would
#     never fire here — see _lib-merge-behind.sh.

# Case: missing rex marker + compare API reports behind_by>0 -> still blocks
# (rc=2), and the note names the behind-base branch as a likely reason.
sb=$(make_sandbox)
input=$(jq -nc --arg c "gh pr merge 1386 --repo me2resh/apexyard --squash" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 MOCK_BEHIND_BY=5 PATH="$sb/bin:$PATH" bash -c \
  "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -q "no recorded code-reviewer" \
   && echo "$got_stderr" | grep -qi "also behind its base branch"; then
  echo "PASS [#1386: missing rex marker + behind_by>0 -> blocks AND names behind-base as a reason]"; PASS=$((PASS+1))
else
  echo "FAIL [#1386: missing rex marker + behind_by>0 -> blocks AND names behind-base as a reason]: rc=$got_rc stderr=${got_stderr:0:400}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}1386-behind-note "
fi

# Case: missing rex marker + compare API reports behind_by=0 -> still blocks
# (rc=2), but the behind-base note must NOT appear (no false positive on a
# PR that is NOT behind its base — the block has a different, unrelated
# cause).
sb=$(make_sandbox)
input=$(jq -nc --arg c "gh pr merge 1387 --repo me2resh/apexyard --squash" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 MOCK_BEHIND_BY=0 PATH="$sb/bin:$PATH" bash -c \
  "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -q "no recorded code-reviewer" \
   && ! echo "$got_stderr" | grep -qi "also behind its base branch"; then
  echo "PASS [#1386: missing rex marker + behind_by=0 -> blocks, no spurious behind-base note]"; PASS=$((PASS+1))
else
  echo "FAIL [#1386: missing rex marker + behind_by=0 -> blocks, no spurious behind-base note]: rc=$got_rc stderr=${got_stderr:0:400}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}1386-no-spurious-note "
fi

# Case (B1 regression pin): a PR that IS behind but whose mergeStateStatus
# reads CLEAN — the exact combination #1386 observed on this repo (dev's
# ruleset has strict_required_status_checks_policy=false, so a behind PR
# never reports BEHIND). The note must still appear, because it is driven
# by the compare API, not by mergeStateStatus.
sb=$(make_sandbox)
input=$(jq -nc --arg c "gh pr merge 1388 --repo me2resh/apexyard --squash" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 MOCK_MERGE_STATE=CLEAN MOCK_BEHIND_BY=8 PATH="$sb/bin:$PATH" bash -c \
  "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -qi "also behind its base branch"; then
  echo "PASS [#1386 B1: mergeStateStatus=CLEAN but behind_by>0 -> note still fires]"; PASS=$((PASS+1))
else
  echo "FAIL [#1386 B1: mergeStateStatus=CLEAN but behind_by>0 -> note still fires]: rc=$got_rc stderr=${got_stderr:0:400}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}1386-behind-despite-clean "
fi

# Case: the note addresses the human approver, not the agent — it must not
# read as an instruction the agent itself could carry out (Hakim MEDIUM,
# #1406). "Ask the ... to" and "Do not update it yourself" must both appear.
sb=$(make_sandbox)
input=$(jq -nc --arg c "gh pr merge 1389 --repo me2resh/apexyard --squash" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 MOCK_BEHIND_BY=3 PATH="$sb/bin:$PATH" bash -c \
  "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -qi "ask the .* to update" \
   && echo "$got_stderr" | grep -qi "do not update it yourself"; then
  echo "PASS [Hakim MEDIUM #1406: behind-base note addresses the user, not the agent]"; PASS=$((PASS+1))
else
  echo "FAIL [Hakim MEDIUM #1406: behind-base note addresses the user, not the agent]: rc=$got_rc stderr=${got_stderr:0:400}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}1406-note-addresses-user "
fi

# Case (A1 advisory): the same note also fires on the OTHER block that can
# precede a behind-base merge attempt — a stale Rex marker (SHA mismatch),
# not only a missing one. Rex's A1 suggestion: align the note with both
# blocks the operator can actually hit.
sb=$(make_sandbox)
write_rex_marker "$sb" 1390 "$WRONG_SHA" "$TEST_REPO"
input=$(jq -nc --arg c "gh pr merge 1390 --repo me2resh/apexyard --squash" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb" && APEXYARD_OPS_DISABLE_PIN=1 MOCK_BEHIND_BY=4 PATH="$sb/bin:$PATH" bash -c \
  "echo '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -q "HEAD is now" \
   && echo "$got_stderr" | grep -qi "also behind its base branch"; then
  echo "PASS [A1: stale-Rex-marker block also gets the behind-base note]"; PASS=$((PASS+1))
else
  echo "FAIL [A1: stale-Rex-marker block also gets the behind-base note]: rc=$got_rc stderr=${got_stderr:0:400}" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}A1-stale-sha-note "
fi

# ===========================================================================
# Carry the Rex approval across a clean base merge (me2resh/apexyard#1437,
# round-2 review)
#
# Each sandbox IS a real git repo (make_sandbox runs `git init`), so these
# cases build genuine merge-commit history and point the mocked `gh` at the
# real SHAs built in that history — the carry-over decision is exercised
# against real git objects AND a forge commit-API response derived from
# them, not a stubbed shape. run_case `cd`s into $sb before invoking the
# hook, so the mock's local `git` calls (no `-C`, relying on cwd) read the
# SAME repo the hook is running against.
#
# Fail-before: on dev, rex_approval_carries_over is undefined (and, before
# the round-2 revision, existed but verified parent[0] only against local
# git — never parent[1] against a forge-resolved base tip). Every CO case
# below that expects exit 0 (CO1, CO5) would FAIL under either prior
# version; CO2/CO3/CO4 pin down that the surrounding behaviour is
# unchanged.
# ===========================================================================

write_gh_mock_head() {
  # Overwrite the sandbox's gh mock so headRefOid, baseRefName, and the
  # forge commit-lookup / branches-tip calls rex_approval_carries_over
  # makes all reflect real SHAs built in the sandbox's own git history.
  local sb="$1" head_sha="$2" base_branch="${3:-dev}"
  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"pr view"*"headRefOid"*)        echo "$head_sha" ;;
  *"pr view"*"headRefName"*)       echo "feature/GH-99-test" ;;
  *"pr view"*"headRepository"*)    echo "acme-org/example" ;;
  *"pr view"*"mergeStateStatus"*)  echo "\${MOCK_MERGE_STATE:-CLEAN}" ;;
  *"pr view"*"baseRefName"*)       echo "$base_branch" ;;
  *"api "*"compare/"*)             echo "\${MOCK_BEHIND_BY:-0}" ;;
  *"/branches/"*)
    ref=\$(printf '%s' "\$*" | sed -E 's#.*branches/([^ ]+).*#\1#')
    ref=\$(printf '%s' "\$ref" | sed 's/%2[Ff]/\//g')
    sha=\$(git rev-parse "refs/heads/\$ref" 2>/dev/null)
    [ -z "\$sha" ] && exit 1
    echo "\$sha"
    ;;
  *"commits/"*)
    target=\$(printf '%s' "\$*" | sed -E 's#.*commits/([^ ]+).*#\1#')
    if ! git cat-file -e "\${target}^{commit}" 2>/dev/null; then
      exit 1
    fi
    parents=\$(git show -s --format='%P' "\$target")
    tree=\$(git rev-parse "\${target}^{tree}")
    p0=\$(printf '%s' "\$parents" | awk '{print \$1}')
    p1=\$(printf '%s' "\$parents" | awk '{print \$2}')
    if [ -n "\$p1" ]; then
      pj="[{\"sha\":\"\$p0\"},{\"sha\":\"\$p1\"}]"
    elif [ -n "\$p0" ]; then
      pj="[{\"sha\":\"\$p0\"}]"
    else
      pj="[]"
    fi
    printf '{"sha":"%s","parents":%s,"commit":{"tree":{"sha":"%s"}}}\n' "\$target" "\$pj" "\$tree"
    ;;
  *) ;;
esac
exit 0
EOF
  chmod +x "$sb/bin/gh"
}

# CO1: clean base merge — Rex + CEO markers name the merge's first parent,
# HEAD is the merge commit, remerge-diff is empty -> merge ALLOWED (exit 0).
sb=$(make_sandbox)
BASE_BRANCH=$(sb_git "$sb" symbolic-ref --short HEAD)
(
  cd "$sb" || exit 1
  export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb"
  git checkout -q -b pr-branch
  echo pr > pr.txt; git add pr.txt; git commit -q -m "pr work"
)
OLD_SHA=$(sb_git "$sb" rev-parse HEAD)
(
  cd "$sb" || exit 1
  export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb"
  git checkout -q "$BASE_BRANCH"
  echo more > base2.txt; git add base2.txt; git commit -q -m "base moves on"
  git checkout -q pr-branch
  git merge -q --no-ff "$BASE_BRANCH" -m "merge base into pr-branch"
)
NEW_SHA=$(sb_git "$sb" rev-parse HEAD)
write_gh_mock_head "$sb" "$NEW_SHA" "$BASE_BRANCH"
write_rex_marker "$sb" 300 "$OLD_SHA"
write_ceo_marker_structured "$sb" 300 "$OLD_SHA"
run_case "CO1: clean base merge carries Rex+CEO approval forward -> allows" 0 "" "$sb" 300

# CO2: HEAD moved for an ordinary reason (new commit, not a base merge) —
# carry-over must NOT apply. Same as the pre-#1437 stale-marker block.
sb=$(make_sandbox)
BASE_BRANCH=$(sb_git "$sb" symbolic-ref --short HEAD)
(
  cd "$sb" || exit 1
  export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb"
  git checkout -q -b pr-branch
  echo pr > pr.txt; git add pr.txt; git commit -q -m "pr work"
)
OLD_SHA=$(sb_git "$sb" rev-parse HEAD)
(
  cd "$sb" || exit 1
  export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb"
  echo more-pr > pr2.txt; git add pr2.txt; git commit -q -m "more pr work, not a merge"
)
NEW_SHA=$(sb_git "$sb" rev-parse HEAD)
write_gh_mock_head "$sb" "$NEW_SHA" "$BASE_BRANCH"
write_rex_marker "$sb" 301 "$OLD_SHA"
write_ceo_marker_structured "$sb" 301 "$OLD_SHA"
run_case "CO2: ordinary new commit (not a merge) -> no carry-over, still blocks" 2 "New commits were pushed" "$sb" 301

# CO3: HEAD is a two-parent merge, but the FIRST parent is not the
# Rex-approved commit (e.g. base was merged the other way around) ->
# no carry-over, still blocks.
sb=$(make_sandbox)
BASE_BRANCH=$(sb_git "$sb" symbolic-ref --short HEAD)
UNRELATED_SHA=$(sb_git "$sb" rev-parse HEAD)
(
  cd "$sb" || exit 1
  export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb"
  git checkout -q -b pr-branch
  echo pr > pr.txt; git add pr.txt; git commit -q -m "pr work"
  git checkout -q "$BASE_BRANCH"
  echo more > base2.txt; git add base2.txt; git commit -q -m "base moves on"
  git checkout -q pr-branch
  git merge -q --no-ff "$BASE_BRANCH" -m "merge base into pr-branch"
)
NEW_SHA=$(sb_git "$sb" rev-parse HEAD)
write_gh_mock_head "$sb" "$NEW_SHA" "$BASE_BRANCH"
write_rex_marker "$sb" 302 "$UNRELATED_SHA"
write_ceo_marker_structured "$sb" 302 "$UNRELATED_SHA"
run_case "CO3: two-parent merge but parent[0] != Rex SHA -> no carry-over, still blocks" 2 "New commits were pushed" "$sb" 302

# CO4: a hand-resolved conflict merge (the local merge-tree recomputation
# does not match the forge-reported tree) -> no carry-over, still blocks —
# this is exactly the case #1437 says must fail closed.
sb=$(make_sandbox)
BASE_BRANCH=$(sb_git "$sb" symbolic-ref --short HEAD)
(
  cd "$sb" || exit 1
  export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb"
  echo base > shared.txt; git add shared.txt; git commit -q -m "shared base"
  git checkout -q -b pr-branch
  echo "pr change" > shared.txt; git add shared.txt; git commit -q -m "pr edits shared.txt"
)
OLD_SHA=$(sb_git "$sb" rev-parse HEAD)
(
  cd "$sb" || exit 1
  export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb"
  git checkout -q "$BASE_BRANCH"
  echo "base change" > shared.txt; git add shared.txt; git commit -q -m "base also edits shared.txt"
  git checkout -q pr-branch
  git merge -q --no-ff "$BASE_BRANCH" -m "merge base into pr-branch" 2>/dev/null || true
  echo "hand-resolved" > shared.txt
  git add shared.txt
  git commit -q -m "merge base into pr-branch (hand-resolved)"
)
NEW_SHA=$(sb_git "$sb" rev-parse HEAD)
write_gh_mock_head "$sb" "$NEW_SHA" "$BASE_BRANCH"
write_rex_marker "$sb" 303 "$OLD_SHA"
write_ceo_marker_structured "$sb" 303 "$OLD_SHA"
run_case "CO4: hand-resolved conflict (merge-tree mismatch) -> no carry-over, still blocks" 2 "New commits were pushed" "$sb" 303

# CO5: the CEO marker independently carries over too (not only Rex) — both
# markers name the merge's first parent, both should be accepted.
sb=$(make_sandbox)
BASE_BRANCH=$(sb_git "$sb" symbolic-ref --short HEAD)
(
  cd "$sb" || exit 1
  export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb"
  git checkout -q -b pr-branch
  echo pr > pr.txt; git add pr.txt; git commit -q -m "pr work"
)
OLD_SHA=$(sb_git "$sb" rev-parse HEAD)
(
  cd "$sb" || exit 1
  export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb"
  git checkout -q "$BASE_BRANCH"
  echo more > base2.txt; git add base2.txt; git commit -q -m "base moves on"
  git checkout -q pr-branch
  git merge -q --no-ff "$BASE_BRANCH" -m "merge base into pr-branch"
)
NEW_SHA=$(sb_git "$sb" rev-parse HEAD)
write_gh_mock_head "$sb" "$NEW_SHA" "$BASE_BRANCH"
# Rex marker already matches HEAD (as if Rex re-reviewed) — only the CEO
# marker is stale and must carry over on its own.
write_rex_marker "$sb" 304 "$NEW_SHA"
write_ceo_marker_structured "$sb" 304 "$OLD_SHA"
run_case "CO5: CEO marker alone carries over across the same clean base merge -> allows" 0 "" "$sb" 304

# CO6 (#1456): second parent is NOT on the base branch — carry-over must
# refuse. Fail-before: on a parent[0]-only check (#1443 round-1) this would
# have allowed the merge; round-2 ancestor check already blocks it; this
# pins the gate-level behaviour the issue asks for.
sb=$(make_sandbox)
BASE_BRANCH=$(sb_git "$sb" symbolic-ref --short HEAD)
BASE_ROOT=$(sb_git "$sb" rev-parse HEAD)
(
  cd "$sb" || exit 1
  export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb"
  git checkout -q -b pr-branch
  echo pr > pr.txt; git add pr.txt; git commit -q -m "pr work"
)
OLD_SHA=$(sb_git "$sb" rev-parse HEAD)
(
  cd "$sb" || exit 1
  export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb"
  git checkout -q -b side-branch "$BASE_ROOT"
  echo side > side.txt; git add side.txt; git commit -q -m "side, never on base"
  git checkout -q pr-branch
  git merge -q --no-ff side-branch -m "merge side into pr-branch"
)
NEW_SHA=$(sb_git "$sb" rev-parse HEAD)
write_gh_mock_head "$sb" "$NEW_SHA" "$BASE_BRANCH"
write_rex_marker "$sb" 305 "$OLD_SHA" "acme-org/example"
write_ceo_marker_structured "$sb" 305 "$OLD_SHA" "acme-org/example"
run_case "CO6: #1456 second parent not on base -> no carry-over, blocks" 2 "New commits were pushed" "$sb" 305 "acme-org/example"

# CO7 (#1456): a grafts entry makes the side parent look like an ancestor of
# the base tip. Isolated GIT_DIR must ignore grafts -> still blocks.
# Fail-before: on #1443 code (merge-base in the real GIT_DIR) this would allow.
sb=$(make_sandbox)
BASE_BRANCH=$(sb_git "$sb" symbolic-ref --short HEAD)
BASE_ROOT=$(sb_git "$sb" rev-parse HEAD)
(
  cd "$sb" || exit 1
  export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb"
  git checkout -q -b pr-branch
  echo pr > pr.txt; git add pr.txt; git commit -q -m "pr work"
)
OLD_SHA=$(sb_git "$sb" rev-parse HEAD)
(
  cd "$sb" || exit 1
  export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb"
  git checkout -q "$BASE_BRANCH"
  echo more > base2.txt; git add base2.txt; git commit -q -m "base moves on"
  git checkout -q -b side-branch "$BASE_ROOT"
  echo side > side.txt; git add side.txt; git commit -q -m "side, never on base"
  SIDE_SHA=$(git rev-parse HEAD)
  git checkout -q pr-branch
  git merge -q --no-ff side-branch -m "merge side into pr-branch"
  MAIN_TIP=$(git rev-parse "$BASE_BRANCH")
  gd="$sb/gitdir"
  mkdir -p "$gd/info"
  echo "$MAIN_TIP $BASE_ROOT $SIDE_SHA" > "$gd/info/grafts"
)
NEW_SHA=$(sb_git "$sb" rev-parse HEAD)
write_gh_mock_head "$sb" "$NEW_SHA" "$BASE_BRANCH"
write_rex_marker "$sb" 306 "$OLD_SHA" "acme-org/example"
write_ceo_marker_structured "$sb" 306 "$OLD_SHA" "acme-org/example"
run_case "CO7: #1456 grafts cannot force carry-over -> blocks" 2 "New commits were pushed" "$sb" 306 "acme-org/example"

# CO8 (#1456): a local merge driver makes merge-tree reproduce a hand-resolved
# tree. Isolated GIT_DIR has no driver -> still blocks.
# Fail-before: on #1443 code (merge-tree against real .git/config) this can allow.
sb=$(make_sandbox)
BASE_BRANCH=$(sb_git "$sb" symbolic-ref --short HEAD)
(
  cd "$sb" || exit 1
  export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb"
  echo base > shared.txt
  echo "shared.txt merge=poison" > .gitattributes
  git add shared.txt .gitattributes
  git commit -q -m "shared base with poison attr"
  git checkout -q -b pr-branch
  echo "pr change" > shared.txt; git add shared.txt; git commit -q -m "pr edits shared"
)
OLD_SHA=$(sb_git "$sb" rev-parse HEAD)
(
  cd "$sb" || exit 1
  export GIT_DIR="$sb/gitdir" GIT_WORK_TREE="$sb"
  git checkout -q "$BASE_BRANCH"
  echo "base change" > shared.txt; git add shared.txt; git commit -q -m "base edits shared"
  mkdir -p .git-drivers
  cat > .git-drivers/poison.sh <<'POISON'
#!/bin/bash
printf 'hand-resolved\n' > "$2"
exit 0
POISON
  chmod +x .git-drivers/poison.sh
  git config merge.poison.driver "\"$(pwd)/.git-drivers/poison.sh\" %O %A %B"
  git checkout -q pr-branch
  git merge -q --no-ff "$BASE_BRANCH" -m "merge base (driver)" 2>/dev/null || true
  if [ -n "$(git ls-files -u 2>/dev/null)" ]; then
    echo "hand-resolved" > shared.txt
    git add shared.txt
    git commit -q -m "merge base (hand-resolved)"
  fi
)
NEW_SHA=$(sb_git "$sb" rev-parse HEAD)
write_gh_mock_head "$sb" "$NEW_SHA" "$BASE_BRANCH"
write_rex_marker "$sb" 307 "$OLD_SHA" "acme-org/example"
write_ceo_marker_structured "$sb" 307 "$OLD_SHA" "acme-org/example"
run_case "CO8: #1456 local merge driver cannot force carry-over -> blocks" 2 "New commits were pushed" "$sb" 307 "acme-org/example"

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
