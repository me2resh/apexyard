#!/bin/bash
# Hook-level regression test for me2resh/apexyard#1066 (and its follow-up
# security-review fix, #1075).
#
# Two distinct false-positive/false-negative shapes were confirmed in one
# session (see the ticket's "Investigation Notes"):
#
#   1. block-main-push.sh's commit-check only tested whether the string
#      "git commit" appeared ANYWHERE in the raw command, then checked the
#      CURRENT branch. A Bash call that merely wrote review prose containing
#      a quoted `git commit -m "wip"` inside a heredoc (no real commit at
#      all) was blocked whenever the session/cwd happened to sit on a
#      protected branch — even though nothing was being committed.
#
#   2. The push-check shares _lib-extract-push-ref.sh with
#      validate-branch-name.sh, so it inherited the same "first match wins"
#      bug: a heredoc mentioning `git push` in prose could make the hook
#      resolve the wrong destination branch.
#
# #2 (the push-ref "which ref" question) is fixed by heredoc-stripping via
# _lib-strip-heredoc.sh, used ONLY inside extract_push_ref/is_tag_push.
#
# #1 (the commit-check) is DELIBERATELY narrower than the first version of
# this fix. A security review of that first version (PR #1075) found that
# routing the PRESENCE checks (`grep -qE 'git push'`/`'git commit'`)
# through heredoc-stripped text let a malformed heredoc make the stripper
# eat the real command, so the gate silently never fired — a bypass, not a
# false positive. The commit-check has no "which ref" refinement step to
# safely lean on (it only checks current branch), so its presence check now
# runs against the RAW command unconditionally, same as `dev`'s baseline
# behaviour. This means case (a) below now DOES block — that is the
# accepted, documented trade-off, not a regression. See
# docs/agdr/AgDR-0113-heredoc-stripper-additive-only.md.
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/block-main-push.sh"
LIB_SRC="$SRC_ROOT/.claude/hooks/_lib-extract-push-ref.sh"
LIB_STRIP_HEREDOC_SRC="$SRC_ROOT/.claude/hooks/_lib-strip-heredoc.sh"
LIB_CONFIG_SRC="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
LIB_OPS_ROOT_SRC="$SRC_ROOT/.claude/hooks/_lib-ops-root.sh"
LIB_PROTECTED_SRC="$SRC_ROOT/.claude/hooks/_lib-protected-branches.sh"

for f in "$HOOK_SRC" "$LIB_SRC" "$LIB_STRIP_HEREDOC_SRC" "$LIB_PROTECTED_SRC"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required source missing: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

make_git_repo() {
  local dir="$1" branch="$2"
  mkdir -p "$dir"
  (
    cd "$dir" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    : > README
    git add README
    git commit -q -m "init"
    git checkout -q -B "$branch"
  )
}

make_sandbox() {
  local primary_branch="${1:-dev}"
  local sb
  sb=$(mktemp -d)
  make_git_repo "$sb" "$primary_branch"
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOK_SRC" "$sb/.claude/hooks/block-main-push.sh"
  cp "$LIB_SRC"  "$sb/.claude/hooks/_lib-extract-push-ref.sh"
  cp "$LIB_PROTECTED_SRC" "$sb/.claude/hooks/_lib-protected-branches.sh"
  if [ -f "$LIB_STRIP_HEREDOC_SRC" ]; then
    cp "$LIB_STRIP_HEREDOC_SRC" "$sb/.claude/hooks/_lib-strip-heredoc.sh"
  fi
  if [ -f "$LIB_CONFIG_SRC" ]; then
    cp "$LIB_CONFIG_SRC" "$sb/.claude/hooks/_lib-read-config.sh"
  fi
  if [ -f "$LIB_OPS_ROOT_SRC" ]; then
    cp "$LIB_OPS_ROOT_SRC" "$sb/.claude/hooks/_lib-ops-root.sh"
  fi
  if [ -f "$SRC_ROOT/.claude/project-config.defaults.json" ]; then
    cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  fi
  chmod +x "$sb/.claude/hooks/block-main-push.sh"
  echo "$sb"
}

run_case() {
  local label="$1" sb="$2" cmd="$3" want_rc="$4"
  local input got_rc got_stderr
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  got_stderr=$(cd "$sb" && echo "$input" | bash .claude/hooks/block-main-push.sh 2>&1 >/dev/null)
  got_rc=$?
  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc" >&2
    echo "    cmd:    $cmd" >&2
    echo "    stderr: ${got_stderr:0:300}" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# ---------------------------------------------------------------------------
# (a) #1075 (security-review correction to #1066): a heredoc merely
#     mentioning "git commit" in prose, cwd on a protected branch, with NO
#     real commit anywhere in the command -> now BLOCKS. This is the
#     deliberate, documented narrowing: the commit-check's presence test
#     must run against RAW text (never heredoc-stripped text), because
#     unlike the push-check it has no independent "which ref" fallback to
#     safely lean on. Matches `dev`'s pre-#1066 conservative behaviour.
# ---------------------------------------------------------------------------
SB=$(make_sandbox "dev")
run_case "#1075: heredoc-only prose mentions 'git commit', cwd=dev -> blocks (raw presence check, deliberate)" \
  "$SB" "$(cat <<'CMD'
cat > /tmp/rev.txt <<EOF
The reviewer noted that a quoted `git commit -m "wip"` inside a heredoc
should not be treated as a real commit.
EOF
echo done
CMD
)" 2
rm -rf "$SB"

# ---------------------------------------------------------------------------
# (b) #1066: heredoc mentions "git commit" in prose, but a REAL commit
#     follows on a protected branch -> the REAL commit must still block.
#     Proves the fix doesn't just make the hook permissive.
# ---------------------------------------------------------------------------
SB=$(make_sandbox "dev")
run_case "#1066: heredoc mentions commit, real commit follows on dev -> still blocks" \
  "$SB" "$(cat <<'CMD'
cat > /tmp/rev.txt <<EOF
Reviewer note: a quoted `git commit -m "wip"` inside a heredoc should not
count as a real commit.
EOF
git commit -m 'actually committing now'
CMD
)" 2
rm -rf "$SB"

# ---------------------------------------------------------------------------
# (c) #1066: heredoc mentions "git push" in prose (the ticket's exact
#     repro), and a REAL push to a protected branch follows -> still blocks.
# ---------------------------------------------------------------------------
SB=$(make_sandbox "feature/GH-1-safe")
run_case "#1066: heredoc mentions push, real push to dev follows -> still blocks" \
  "$SB" "$(cat <<'CMD'
cat > /tmp/m.txt <<EOF
The previous commit claimed terminal `git push` still runs the checks.
EOF
git commit -F /tmp/m.txt
git push origin dev
CMD
)" 2
rm -rf "$SB"

# ---------------------------------------------------------------------------
# (d) #1066: heredoc mentions "git push" in prose, real commit+push target a
#     conforming feature branch -> passes (the ticket's exact repro, at the
#     block-main-push.sh layer). Sandbox is checked out on the SAME feature
#     branch so the commit-check section also passes, isolating the push-ref
#     extraction as what's under test.
# ---------------------------------------------------------------------------
SB=$(make_sandbox "fix/GH-1031-untrack-project-config-json")
run_case "#1066: heredoc mentions push, real commit+push to matching feature branch -> passes" \
  "$SB" "$(cat <<'CMD'
cat > /tmp/m.txt <<EOF
The previous commit claimed terminal `git push` still runs the checks because
bin/run-pre-push-checks.sh hardcodes them.
EOF
git commit -F /tmp/m.txt
git push upstream fix/GH-1031-untrack-project-config-json
CMD
)" 0
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Regressions: real (non-heredoc) commit/push behaviour from #549/#727 must
# be unaffected.
# ---------------------------------------------------------------------------
SB=$(make_sandbox "dev")
run_case "regression: plain commit on dev still blocks" "$SB" "git commit -m 'bad'" 2
rm -rf "$SB"

SB=$(make_sandbox "dev")
run_case "regression: push to feature branch passes (cwd=dev, explicit ref)" \
  "$SB" "git push origin feature/GH-549-fix" 0
rm -rf "$SB"

SB=$(make_sandbox "dev")
run_case "regression: tag push still passes (cwd=dev)" \
  "$SB" "git push origin --tags" 0
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases: $FAILED_CASES" >&2
  exit 1
fi
exit 0
