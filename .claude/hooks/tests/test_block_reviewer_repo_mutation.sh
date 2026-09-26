#!/bin/bash
# Regression tests for #1233: review-class agents stay read-only while the
# active-reviewer marker is present.
set -u

SRC_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOK="$SRC_ROOT/.claude/hooks/block-reviewer-repo-mutation.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-review-mutation.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude/session" "$TMP/.claude/hooks"
touch "$TMP/.apexyard-fork"
git -C "$TMP" init -q
cp "$HOOK" "$TMP/.claude/hooks/"
cp "$SRC_ROOT/.claude/hooks/_lib-strip-heredoc.sh" "$TMP/.claude/hooks/"
printf '%s\n' 'me2resh/apexyard#1233:rex' > "$TMP/.claude/session/active-reviewer"

run_case() {
  local name="$1" command="$2" expected="$3"
  local input output rc
  input=$(jq -cn --arg command "$command" '{tool_input:{command:$command}}')
  output=$(cd "$TMP" && printf '%s' "$input" | "$TMP/.claude/hooks/block-reviewer-repo-mutation.sh" 2>&1)
  rc=$?
  if [ "$expected" = blocked ] && [ "$rc" -eq 2 ] && printf '%s' "$output" | grep -q 'BLOCKED:'; then
    echo "PASS: $name"
  elif [ "$expected" = allowed ] && [ "$rc" -eq 0 ]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (rc=$rc output=$output)" >&2
    return 1
  fi
}

run_case 'git commit is blocked' 'git commit -m "reviewed"' blocked
run_case 'git push is blocked' 'cd repo && git push origin fix/1233-review-agent-read-only' blocked
run_case 'git restore is blocked' 'git -C repo restore tracked.md' blocked
run_case 'git stash is blocked' 'git stash push -m save' blocked
run_case 'git commit before separator is blocked' 'git commit;' blocked
run_case 'git push before separator is blocked' 'git push; echo done' blocked
run_case 'newline-separated git mutation is blocked' $'echo review\ngit commit' blocked
run_case 'git tag is blocked' 'git tag release-candidate' blocked
run_case 'git update-ref is blocked' 'git update-ref refs/heads/reviewed HEAD' blocked
run_case 'git fetch is blocked' 'git fetch origin' blocked
run_case 'git checkout-index is blocked' 'git checkout-index --all' blocked
run_case 'git apply is blocked' 'git apply fix.patch' blocked
run_case 'git submodule update is blocked' 'git submodule update --init' blocked
run_case 'git worktree add remains available for orchestration' 'git worktree add ../review-copy HEAD' allowed
run_case 'git worktree add with branch remains available' 'git worktree add -b reviewer-copy ../review-copy HEAD' allowed
run_case 'git worktree lock is blocked' 'git worktree lock ../review-copy' blocked
run_case 'git notes is blocked' 'git notes add -m note HEAD' blocked
run_case 'git revert is blocked' 'git revert HEAD' blocked
run_case 'git am is blocked' 'git am review.patch' blocked
run_case 'git bisect is blocked' 'git bisect start' blocked
run_case 'git config is blocked' 'git config user.name Reviewer' blocked
run_case 'git reflog is blocked' 'git reflog expire --all' blocked
run_case 'git replace is blocked' 'git replace HEAD HEAD^' blocked
run_case 'git sparse-checkout is blocked' 'git sparse-checkout set src' blocked
run_case 'git filter-branch is blocked' 'git filter-branch -- --all' blocked
run_case 'git gc is blocked' 'git gc' blocked
run_case 'git init is blocked' 'git init' blocked
run_case 'git status remains available' 'git status --short' allowed
run_case 'git diff remains available' 'git diff --check' allowed
run_case 'git rev-parse remains available' 'git rev-parse HEAD' allowed
run_case 'git remote get-url remains available' 'git remote get-url origin' allowed
run_case 'git remote add is blocked' 'git remote add backup https://example.invalid/repo.git' blocked
run_case 'git branch show-current remains available' 'git branch --show-current' allowed
run_case 'git config get remains available' 'git config --get user.name' allowed
run_case 'git reflog show remains available' 'git reflog -1' allowed
run_case 'git notes show remains available' 'git notes show HEAD' allowed
run_case 'git worktree list remains available' 'git worktree list' allowed
run_case 'git branch create is blocked' 'git branch reviewer-copy' blocked
run_case 'git config write is blocked' 'git config user.name Reviewer' blocked
run_case 'git notes add is blocked' 'git notes add -m note HEAD' blocked
run_case 'git worktree remove is blocked' 'git worktree remove ../review-copy' blocked
run_case 'git submodule status remains available' 'git submodule status' allowed
run_case 'git sparse-checkout list remains available' 'git sparse-checkout list' allowed
run_case 'git format-patch stdout remains available' 'git format-patch --stdout HEAD~1..HEAD' allowed
run_case 'git fast-export remains available' 'git fast-export HEAD' allowed
run_case 'git rerere status remains available' 'git rerere status' allowed
run_case 'git maintenance list remains available' 'git maintenance list' allowed
run_case 'git C config get remains available' 'git -C repo config --get user.name' allowed
run_case 'git format-patch file write is blocked' 'git format-patch HEAD~1..HEAD' blocked
run_case 'git submodule update remains blocked' 'git submodule update --init' blocked
run_case 'git fast-export marks write is blocked' 'git fast-export --export-marks=marks.txt HEAD' blocked
run_case 'git archive output write is blocked' 'git archive --output=archive.tar HEAD' blocked
run_case 'git archive short output write is blocked' 'git archive -o archive.tar HEAD' blocked
run_case 'git archive short equals output is blocked' 'git archive -o=archive.tar HEAD' blocked
run_case 'git C archive output write is blocked' 'git -C repo archive -o archive.tar HEAD' blocked
run_case 'git archive attached short output is blocked' 'git archive -oarchive.tar HEAD' blocked
run_case 'git C archive attached short output is blocked' 'git -C repo archive -oarchive.tar HEAD' blocked
run_case 'quoted prose is not a mutation' "printf '%s\\n' 'git commit is forbidden'" allowed
run_case 'heredoc review prose is not a mutation' $'cat <<EOF > /tmp/review-body\nDo not run git commit during review.\nEOF' allowed

rm -f "$TMP/.claude/session/active-reviewer"
run_case 'without active review mutations are unchanged' 'git commit -m "orchestrator work"' allowed

# ---------------------------------------------------------------------------
# me2resh/apexyard#1376 — the active-reviewer marker is now keyed on
# CLAUDE_CODE_SESSION_ID (active_reviewer_marker_path, _lib-review-markers.sh)
# instead of one fixed path shared by every session and worktree. Before this
# fix, a review running in one session set the ONE shared marker file above,
# and this hook read it from EVERY session — an unrelated `git commit` in a
# totally different worktree got blocked by a review it had no part in.
#
# A DEDICATED sandbox (with _lib-review-markers.sh copied in, unlike $TMP
# above) and an explicit-session-id run helper, so these cases don't disturb
# the shared $TMP sandbox the rest of this file uses.
# ---------------------------------------------------------------------------

SESS_TMP=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-review-mutation-sess.XXXXXX")
mkdir -p "$SESS_TMP/.claude/session" "$SESS_TMP/.claude/hooks"
touch "$SESS_TMP/.apexyard-fork"
git -C "$SESS_TMP" init -q
cp "$HOOK" "$SESS_TMP/.claude/hooks/"
cp "$SRC_ROOT/.claude/hooks/_lib-strip-heredoc.sh" "$SESS_TMP/.claude/hooks/"
cp "$SRC_ROOT/.claude/hooks/_lib-review-markers.sh" "$SESS_TMP/.claude/hooks/"

# shellcheck disable=SC1091
. "$SRC_ROOT/.claude/hooks/_lib-review-markers.sh"

# run_case_sess <name> <session_id|""> <command> <expected: blocked|allowed>
run_case_sess() {
  local name="$1" sess="$2" command="$3" expected="$4"
  local input output rc
  input=$(jq -cn --arg command "$command" '{tool_input:{command:$command}}')
  output=$(
    cd "$SESS_TMP" || exit 1
    if [ -n "$sess" ]; then export CLAUDE_CODE_SESSION_ID="$sess"; else unset CLAUDE_CODE_SESSION_ID; fi
    printf '%s' "$input" | "$SESS_TMP/.claude/hooks/block-reviewer-repo-mutation.sh" 2>&1
  )
  rc=$?
  if [ "$expected" = blocked ] && [ "$rc" -eq 2 ] && printf '%s' "$output" | grep -q 'BLOCKED:'; then
    echo "PASS: $name"
  elif [ "$expected" = allowed ] && [ "$rc" -eq 0 ]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (rc=$rc output=$output)" >&2
    trap - EXIT
    rm -rf "$TMP" "$SESS_TMP"
    exit 1
  fi
}

# (1) SAME session: session "sess-A" wrote its own marker; that session's git
# mutation is blocked exactly as before, now proven with the session suffix.
ACTIVE_A=$(active_reviewer_marker_path "$SESS_TMP" "sess-A")
mkdir -p "$(dirname "$ACTIVE_A")"
printf '%s\n' 'me2resh/apexyard#1233:rex' > "$ACTIVE_A"
run_case_sess '#1376: same session as the marker owner -> git commit still blocked' \
  "sess-A" 'git commit -m "reviewed"' blocked

# (2) THE REGRESSION THIS FIX CLOSES: a DIFFERENT session's git mutation must
# NOT be blocked by sess-A's marker. Pre-#1376's single fixed path meant any
# session's `git commit` was blocked by a review running in a completely
# different worktree.
run_case_sess '#1376: a DIFFERENT concurrent session is not blocked by sess-A review -> git commit allowed' \
  "sess-B" 'git commit -m "unrelated orchestrator work"' allowed

# (3) NO session id at all (a bare/standalone invocation) must not be blocked
# by another session's marker either — the fixed-path fallback only reads
# the UNSUFFIXED path, and sess-A wrote a suffixed one.
run_case_sess '#1376: no session id, a different session marker exists -> git commit allowed' \
  "" 'git commit -m "standalone invocation"' allowed

rm -f "$ACTIVE_A"

# (4) Parity check: a marker at the LEGACY bare/shared path (no per-session
# suffix at all) still protects a genuinely session-less review — a
# git-native hook, CI, or a bare test-harness invocation, none of which set
# CLAUDE_CODE_SESSION_ID. The fallback in active_reviewer_marker_path exists
# specifically so this case keeps working unchanged.
printf '%s\n' 'me2resh/apexyard#1233:rex' > "$SESS_TMP/.claude/session/active-reviewer"
run_case_sess '#1376: no session id, legacy shared-path marker of its own -> git commit still blocked (fallback parity)' \
  "" 'git commit -m "should still be blocked"' blocked

# (5) THE REGRESSION THIS FIX CLOSES, mirrored at this hook: a marker sitting
# at that SAME legacy bare/shared path must NOT block a session that HAS its
# own distinct id (sess-C resolves its OWN suffixed path, which carries no
# content here, and never falls back to the bare path once an id exists).
# Pre-#1376 this hook read the bare path UNCONDITIONALLY — a marker there,
# from any source, blocked every session's mutations regardless of identity.
run_case_sess '#1376: legacy shared-path marker does not block a session that has its own id -> git commit allowed' \
  "sess-C" 'git commit -m "unrelated to the legacy marker"' allowed
rm -f "$SESS_TMP/.claude/session/active-reviewer"

rm -rf "$SESS_TMP"

echo 'PASS: all review mutation cases'
