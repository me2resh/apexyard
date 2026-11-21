#!/bin/bash
# Issue #2070 step 1: clean up at merge. remove-worktree.sh lists and removes
# the review copies of a merged PR (detached linked worktrees at a PR commit),
# with their build output, and logs every removal. The original list and
# remove modes keep every refusal. Nothing runs `git worktree remove --force`.

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOKS="$SRC_ROOT/.claude/hooks"
SKILL="$SRC_ROOT/.claude/skills/approve-merge"
OFFER="$SRC_ROOT/docs/skills/approve-merge-worktree-offer.md"

export APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

PASS=0
FAIL=0
ok() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL + 1)); }

mkrepo() {
  git init -q "$1"
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name t
  git -C "$1" commit -q --allow-empty -m init
}

SB=$(mktemp -d)
SB=$(cd -P "$SB" && pwd)
trap 'rm -rf "$SB"' EXIT
mkrepo "$SB"
: > "$SB/.apexyard-fork"
: > "$SB/onboarding.yaml"
printf 'projects:\n  - name: p1\n    repo: org/p1\n' > "$SB/apexyard.projects.yaml"
mkdir -p "$SB/.claude/hooks" "$SB/.claude/skills/approve-merge" "$SB/workspace"
for f in _lib-active-ticket.sh _lib-read-config.sh _lib-portfolio-paths.sh _lib-ops-root.sh _lib-resolution-cache.sh _lib-path-resolve.sh _lib-worktree-owner.sh _lib-exclusive-directory.sh; do
  cp "$HOOKS/$f" "$SB/.claude/hooks/$f"
done
cp "$SRC_ROOT/.claude/project-config.defaults.json" "$SB/.claude/project-config.defaults.json"
cp "$SKILL/remove-worktree.sh" "$SB/.claude/skills/approve-merge/remove-worktree.sh"
HELPER="$SB/.claude/skills/approve-merge/remove-worktree.sh"
LOG="$SB/.claude/session/cleanup.log"

P1="$SB/workspace/p1"
mkrepo "$P1"
git init -q --bare "$SB/remote.git"
git -C "$P1" remote add origin "$SB/remote.git"
git -C "$P1" push -q origin HEAD:refs/heads/main
BASE=$(git -C "$P1" rev-parse HEAD)

# The PR branch has two commits. The first one adds a .gitignore for build/.
git -C "$P1" worktree add -q "$SB/wt-pr" -b feature/pr
printf 'build/\n' > "$SB/wt-pr/.gitignore"
git -C "$SB/wt-pr" add .gitignore
git -C "$SB/wt-pr" commit -q -m first
C1=$(git -C "$SB/wt-pr" rev-parse HEAD)
git -C "$SB/wt-pr" commit -q --allow-empty -m second
C2=$(git -C "$SB/wt-pr" rev-parse HEAD)
git -C "$SB/wt-pr" push -q origin HEAD:refs/heads/feature/pr
# A squash merge and branch deletion leave the PR commits off every remote ref.
git -C "$P1" push -q origin --delete feature/pr
git -C "$P1" fetch -q --prune origin

# Review copies: the final head, an earlier round, and an unrelated base copy.
git -C "$P1" worktree add -q --detach "$SB/copy-final" "$C2"
git -C "$P1" worktree add -q --detach "$SB/copy-old" "$C1"
git -C "$P1" worktree add -q --detach "$SB/copy-base" "$BASE"
mkdir -p "$SB/copy-final/build"
printf 'bin\n' > "$SB/copy-final/build/app.bin"

# run <cwd> <args...>: sets OUT and RC
run() {
  local cwd="$1"
  shift
  OUT=$(cd "$cwd" && "$BASH" "$HELPER" "$@" 2>&1)
  RC=$?
}

# --- argument rules -----------------------------------------------------------
run "$SB" list-copies "$P1"
if [ "$RC" = 2 ]; then ok list_copies_requires_merged_head; else bad list_copies_requires_merged_head "rc=$RC $OUT"; fi
run "$SB" list-copies "$P1" --merged-head nothex
if [ "$RC" = 2 ]; then ok list_copies_rejects_a_bad_sha; else bad list_copies_rejects_a_bad_sha "rc=$RC $OUT"; fi
run "$SB" list-copies "$P1" --pr-commit "$C1"
if [ "$RC" = 2 ]; then ok pr_commit_alone_is_not_enough; else bad pr_commit_alone_is_not_enough "rc=$RC $OUT"; fi
run "$SB" remove-copy "$P1" "$SB/copy-final"
if [ "$RC" = 2 ] && [ -d "$SB/copy-final" ]; then ok remove_copy_requires_merged_head; else bad remove_copy_requires_merged_head "rc=$RC $OUT"; fi
run "$SB" remove-copy "$P1" "$SB/copy-final" --merged-head "$C2" --merged-head "$C2"
if [ "$RC" = 2 ] && [ -d "$SB/copy-final" ]; then ok merged_head_given_once; else bad merged_head_given_once "rc=$RC $OUT"; fi
run "$SB" sweep "$P1" x
if [ "$RC" = 2 ]; then ok unknown_mode_is_rejected; else bad unknown_mode_is_rejected "rc=$RC $OUT"; fi

# --- list-copies: only detached worktrees at a commit of the merged PR -------
run "$SB" list-copies "$P1" --merged-head "$C2"
case "$OUT" in
  ok$'\t'"$SB/copy-final"$'\n'"  build/"*) ok list_copies_shows_the_copy_and_its_build_output ;;
  *) bad list_copies_shows_the_copy_and_its_build_output "$OUT" ;;
esac
if ! printf '%s' "$OUT" | grep -q 'copy-old\|copy-base\|wt-pr'; then ok list_copies_skips_other_commits_and_branches; else bad list_copies_skips_other_commits_and_branches "$OUT"; fi
run "$SB" list-copies "$P1" --merged-head "$C2" --pr-commit "$C1"
if printf '%s' "$OUT" | grep -q "^ok"$'\t'"$SB/copy-old\$" && ! printf '%s' "$OUT" | grep -q copy-base; then
  ok list_copies_includes_an_earlier_pr_commit
else bad list_copies_includes_an_earlier_pr_commit "$OUT"; fi
UPPER=$(printf '%s' "$C2" | tr 'a-f' 'A-F')
run "$SB" list-copies "$P1" --merged-head "$UPPER"
case "$OUT" in ok$'\t'"$SB/copy-final"*) ok list_copies_accepts_an_uppercase_sha ;; *) bad list_copies_accepts_an_uppercase_sha "$OUT" ;; esac
run "$SB" list-copies "$P1" --merged-head "$BASE"
if printf '%s' "$OUT" | grep -q "copy-base"; then
  ok base_copy_matches_only_when_named
else bad base_copy_matches_only_when_named "$OUT"; fi

# --- remove-copy refusals ------------------------------------------------------
run "$SB" remove-copy "$P1" "$SB/wt-pr" --merged-head "$C2"
if [ "$RC" != 0 ] && [ -d "$SB/wt-pr" ] && printf '%s' "$OUT" | grep -q 'holds a branch'; then
  ok remove_copy_refuses_a_branch_worktree
else bad remove_copy_refuses_a_branch_worktree "rc=$RC $OUT"; fi
run "$SB" remove-copy "$P1" "$SB/copy-base" --merged-head "$C2"
if [ "$RC" != 0 ] && [ -d "$SB/copy-base" ] && printf '%s' "$OUT" | grep -q 'not a commit of the merged PR'; then
  ok remove_copy_refuses_another_commit
else bad remove_copy_refuses_another_commit "rc=$RC $OUT"; fi
mkdir -p "$SB/not-a-worktree"
run "$SB" remove-copy "$P1" "$SB/not-a-worktree" --merged-head "$C2"
if [ "$RC" != 0 ] && [ -d "$SB/not-a-worktree" ] && printf '%s' "$OUT" | grep -q 'is not a linked worktree'; then
  ok remove_copy_refuses_an_unlisted_path
else bad remove_copy_refuses_an_unlisted_path "rc=$RC $OUT"; fi
printf 'work\n' > "$SB/copy-final/notes.txt"
run "$SB" list-copies "$P1" --merged-head "$C2"
if printf '%s' "$OUT" | grep -Fq "refused (uncommitted changes)"; then ok list_copies_refuses_a_dirty_copy; else bad list_copies_refuses_a_dirty_copy "$OUT"; fi
run "$SB" remove-copy "$P1" "$SB/copy-final" --merged-head "$C2"
if [ "$RC" != 0 ] && [ -f "$SB/copy-final/notes.txt" ] && printf '%s' "$OUT" | grep -q 'uncommitted changes'; then
  ok remove_copy_skips_a_dirty_copy
else bad remove_copy_skips_a_dirty_copy "rc=$RC $OUT"; fi
rm -f "$SB/copy-final/notes.txt"
git -C "$P1" worktree lock "$SB/copy-old"
run "$SB" remove-copy "$P1" "$SB/copy-old" --merged-head "$C2" --pr-commit "$C1"
if [ "$RC" != 0 ] && [ -d "$SB/copy-old" ] && printf '%s' "$OUT" | grep -q 'locked'; then
  ok remove_copy_refuses_a_locked_copy
else bad remove_copy_refuses_a_locked_copy "rc=$RC $OUT"; fi
git -C "$P1" worktree unlock "$SB/copy-old"
run "$SB/copy-final" remove-copy "$P1" "$SB/copy-final" --merged-head "$C2"
if [ "$RC" != 0 ] && [ -d "$SB/copy-final" ] && printf '%s' "$OUT" | grep -q "the session's own tree"; then
  ok remove_copy_refuses_the_sessions_own_tree
else bad remove_copy_refuses_the_sessions_own_tree "rc=$RC $OUT"; fi
# A commit off the merged history that no remote holds stays refused.
git -C "$P1" worktree add -q --detach "$SB/copy-stray" "$C2"
git -C "$SB/copy-stray" commit -q --allow-empty -m stray
STRAY=$(git -C "$SB/copy-stray" rev-parse HEAD)
run "$SB" list-copies "$P1" --merged-head "$C2" --pr-commit "$STRAY"
if printf '%s' "$OUT" | grep -Fq "refused (unpushed commits)"$'\t'"$SB/copy-stray"; then
  ok stray_commit_is_refused_as_unpushed
else bad stray_commit_is_refused_as_unpushed "$OUT"; fi

# --- the removal log must be writable before anything is removed --------------
mkdir -p "$SB/.claude"
rm -rf "$SB/.claude/session"
: > "$SB/.claude/session"
run "$SB" remove-copy "$P1" "$SB/copy-final" --merged-head "$C2"
if [ "$RC" != 0 ] && [ -d "$SB/copy-final" ] && printf '%s' "$OUT" | grep -q 'cannot write the removal log'; then
  ok unwritable_log_refuses_removal
else bad unwritable_log_refuses_removal "rc=$RC $OUT"; fi
run "$SB" remove "$P1" "$SB/wt-pr" feature/pr --merged-head "$C2"
if [ "$RC" != 0 ] && [ -d "$SB/wt-pr" ] && printf '%s' "$OUT" | grep -q 'cannot write the removal log'; then
  ok unwritable_log_refuses_worktree_removal
else bad unwritable_log_refuses_worktree_removal "rc=$RC $OUT"; fi
rm -f "$SB/.claude/session"

# --- a clean copy goes with its build output, and the log records it ---------
run "$SB" remove-copy "$P1" "$SB/copy-final" --merged-head "$C2"
if [ "$RC" = 0 ] && [ ! -e "$SB/copy-final" ] && [ "$OUT" = "removed $SB/copy-final" ]; then
  ok clean_copy_and_build_output_are_removed
else bad clean_copy_and_build_output_are_removed "rc=$RC $OUT"; fi
if [ -f "$LOG" ] && awk -F '\t' -v p="$SB/copy-final" -v h="$C2" '$2 == "review-copy" && $3 == p && $5 == h && $6 == h { found = 1 } END { exit !found }' "$LOG"; then
  ok copy_removal_is_logged
else bad copy_removal_is_logged "$(cat "$LOG" 2>/dev/null)"; fi
if head -n 1 "$LOG" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'$'\t'; then
  ok log_line_starts_with_a_utc_time
else bad log_line_starts_with_a_utc_time "$(head -n 1 "$LOG")"; fi
run "$SB" remove-copy "$P1" "$SB/copy-old" --merged-head "$C2" --pr-commit "$C1"
if [ "$RC" = 0 ] && [ ! -e "$SB/copy-old" ]; then ok earlier_round_copy_is_removed; else bad earlier_round_copy_is_removed "rc=$RC $OUT"; fi

# --- the branch worktree removal is logged too ---------------------------------
run "$SB" remove "$P1" "$SB/wt-pr" feature/pr --merged-head "$C2"
if [ "$RC" = 0 ] && [ ! -e "$SB/wt-pr" ] &&
  awk -F '\t' -v p="$SB/wt-pr" '$2 == "worktree" && $3 == p && $5 == "feature/pr" { found = 1 } END { exit !found }' "$LOG"; then
  ok worktree_removal_is_logged
else bad worktree_removal_is_logged "rc=$RC $OUT $(cat "$LOG" 2>/dev/null)"; fi
if [ "$(wc -l < "$LOG" | tr -d ' ')" = 3 ]; then ok log_has_one_line_per_removal; else bad log_has_one_line_per_removal "$(cat "$LOG")"; fi
# Refusals add no log line.
if [ -d "$SB/copy-base" ] && [ -d "$SB/copy-stray" ]; then ok refused_copies_stay_on_disk; else bad refused_copies_stay_on_disk "a refused copy is gone"; fi

# --- static checks: the skill and doc propose, ask, and never force ------------
if grep -nE 'worktree remove' "$SKILL/remove-worktree.sh" "$SKILL/SKILL.md" "$OFFER" | grep -E -- '--force|-f ' | grep -vE 'no .?--force|[Nn]ever' | grep -q .; then
  bad no_force_anywhere "found a forced removal"
else ok no_force_anywhere; fi
if grep -q 'list-copies' "$SKILL/SKILL.md" && grep -q 'list-copies' "$OFFER" &&
  grep -q 'remove-copy' "$OFFER" && grep -q 'cleanup.log' "$OFFER" && grep -q 'AskUserQuestion' "$OFFER"; then
  ok doc_proposes_copies_and_names_the_log
else bad doc_proposes_copies_and_names_the_log 'list-copies, remove-copy or the log is not in the doc'; fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
