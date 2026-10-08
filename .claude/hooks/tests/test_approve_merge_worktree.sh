#!/bin/bash
# /approve-merge worktree removal (AgDR-0222): remove-worktree.sh takes its
# candidates only from `git worktree list --porcelain`, refuses unsafe trees,
# lists ignored files for the confirmation prompt, and never uses --force.

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOKS="$SRC_ROOT/.claude/hooks"
SKILL="$SRC_ROOT/.claude/skills/approve-merge"

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

make_sb() {
  local sb f
  sb=$(mktemp -d)
  sb=$(cd -P "$sb" && pwd)
  mkrepo "$sb"
  : > "$sb/.apexyard-fork"
  : > "$sb/onboarding.yaml"
  printf 'projects:\n  - name: p1\n    repo: org/p1\n' > "$sb/apexyard.projects.yaml"
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/skills/approve-merge" "$sb/workspace"
  for f in _lib-active-ticket.sh _lib-read-config.sh _lib-portfolio-paths.sh _lib-ops-root.sh _lib-resolution-cache.sh _lib-path-resolve.sh; do
    cp "$HOOKS/$f" "$sb/.claude/hooks/$f"
  done
  cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  cp "$SKILL/remove-worktree.sh" "$sb/.claude/skills/approve-merge/remove-worktree.sh"
  chmod +x "$sb/.claude/skills/approve-merge/remove-worktree.sh"
  mkrepo "$sb/workspace/p1"
  echo "$sb"
}

# run <cwd> <args...>: sets OUT and RC
run() {
  local cwd="$1"
  shift
  OUT=$(cd "$cwd" && "$SB/.claude/skills/approve-merge/remove-worktree.sh" "$@" 2>&1)
  RC=$?
}

SB=$(make_sb)
P1="$SB/workspace/p1"
git -C "$P1" worktree add -q "$SB/wt-x" -b feature/x
printf 'cache\n' > "$SB/wt-x/.gitignore"
git -C "$SB/wt-x" add .gitignore
git -C "$SB/wt-x" commit -q -m ignore
mkdir -p "$SB/wt-x/cache"
printf 'big\n' > "$SB/wt-x/cache/blob.bin"

# --- list: candidates come from porcelain, matched on the branch ----------
run "$SB" list "$P1" feature/x
case "$OUT" in
  ok$'\t'"$SB/wt-x"*"cache/blob.bin"*) ok "list_shows_the_worktree_and_its_ignored_files" ;;
  *) bad "list_shows_the_worktree_and_its_ignored_files" "$OUT" ;;
esac
# A git environment from the caller must not redirect the listing.
mkrepo "$SB/elsewhere-repo"
OUT=$(cd "$SB" && GIT_DIR="$SB/elsewhere-repo/.git" GIT_WORK_TREE="$SB/elsewhere-repo" \
  "$SB/.claude/skills/approve-merge/remove-worktree.sh" list "$P1" feature/x 2>&1)
case "$OUT" in
  ok$'\t'"$SB/wt-x"*) ok "list_ignores_the_callers_git_environment" ;;
  *) bad "list_ignores_the_callers_git_environment" "$OUT" ;;
esac
# Variables outside the four that pick the repository are scrubbed too, from
# git's own list.
OUT=$(cd "$SB" && GIT_OBJECT_DIRECTORY="$SB/no-such-objects" GIT_CONFIG_PARAMETERS="'core.bare'='true'" \
  "$SB/.claude/skills/approve-merge/remove-worktree.sh" list "$P1" feature/x 2>&1)
case "$OUT" in
  ok$'\t'"$SB/wt-x"*"cache/blob.bin"*) ok "list_scrubs_gits_local_env_vars" ;;
  *) bad "list_scrubs_gits_local_env_vars" "$OUT" ;;
esac
# A worktree path with a newline in it stays one candidate.
NLWT="$SB/wt-nl"$'\n'"x"
git -C "$P1" worktree add -q "$NLWT" -b feature/nl
run "$SB" list "$P1" feature/nl
case "$OUT" in
  ok$'\t'"$NLWT"*) ok "list_keeps_a_path_with_a_newline_whole" ;;
  *) bad "list_keeps_a_path_with_a_newline_whole" "$OUT" ;;
esac
git -C "$P1" worktree remove "$NLWT"
run "$SB" list "$P1" feature/unknown
case "$OUT" in none:*) ok "list_has_no_candidate_for_an_unknown_branch" ;; *) bad "list_has_no_candidate_for_an_unknown_branch" "$OUT" ;; esac
mkdir -p "$SB/not-a-worktree"
run "$SB" remove "$P1" "$SB/not-a-worktree" feature/x
if [ "$RC" != 0 ] && [ -d "$SB/not-a-worktree" ]; then ok "remove_refuses_a_path_that_porcelain_does_not_list"; else bad "remove_refuses_a_path_that_porcelain_does_not_list" "rc=$RC $OUT"; fi

# --- refusals ---------------------------------------------------------------
run "$SB" list "$P1" main
if printf '%s' "$OUT" | grep -q 'refused (main worktree)'; then ok "refuses_the_main_worktree"; else
  # The default branch name of the fixture may differ.
  br=$(git -C "$P1" branch --show-current)
  run "$SB" list "$P1" "$br"
  if printf '%s' "$OUT" | grep -q 'refused (main worktree)'; then ok "refuses_the_main_worktree"; else bad "refuses_the_main_worktree" "$OUT"; fi
fi
git -C "$P1" worktree add -q "$SB/wt-lock" -b feature/lock
git -C "$P1" worktree lock "$SB/wt-lock"
run "$SB" list "$P1" feature/lock
if printf '%s' "$OUT" | grep -q 'refused (locked)'; then ok "refuses_a_locked_worktree"; else bad "refuses_a_locked_worktree" "$OUT"; fi
run "$SB" remove "$P1" "$SB/wt-lock" feature/lock
if [ "$RC" != 0 ] && [ -d "$SB/wt-lock" ]; then ok "remove_refuses_a_locked_worktree"; else bad "remove_refuses_a_locked_worktree" "rc=$RC"; fi
run "$SB/wt-x" list "$P1" feature/x
if printf '%s' "$OUT" | grep -q "refused (the session's own tree)"; then ok "refuses_the_sessions_own_tree"; else bad "refuses_the_sessions_own_tree" "$OUT"; fi
run "$SB/wt-x" remove "$P1" "$SB/wt-x" feature/x
if [ "$RC" != 0 ] && [ -d "$SB/wt-x" ]; then ok "remove_refuses_the_sessions_own_tree"; else bad "remove_refuses_the_sessions_own_tree" "rc=$RC"; fi

# a worktree of the ops fork that holds the ops root path itself
git -C "$SB" worktree add -q "$SB/workspace/p1-wt-inside" -b feature/inside 2>/dev/null
# the ops root must never be removed: a worktree whose path contains it cannot exist
# for a real fork, so the check is exercised with the ops fork's own main worktree
run "$SB" list "$SB" "$(git -C "$SB" branch --show-current)"
if printf '%s' "$OUT" | grep -q 'refused (main worktree)'; then ok "refuses_the_ops_fork_main_worktree"; else bad "refuses_the_ops_fork_main_worktree" "$OUT"; fi

# --- the ignored-file list is cut at 20 and says how many more exist -------
for n in $(seq 1 25); do : > "$SB/wt-x/cache/f$n.bin"; done
run "$SB" list "$P1" feature/x
if printf '%s' "$OUT" | grep -q '\.\.\. and 6 more ignored files'; then ok "ignored_file_list_is_cut_and_counted"; else bad "ignored_file_list_is_cut_and_counted" "$OUT"; fi
rm -f "$SB"/wt-x/cache/f*.bin

# --- without a session tree, every candidate is refused --------------------
NONGIT=$(mktemp -d)
run "$NONGIT" list "$P1" feature/x
if printf '%s' "$OUT" | grep -q "refused (cannot tell the session's own tree or the ops root)"; then ok "refuses_every_candidate_when_the_session_tree_is_unknown"; else bad "refuses_every_candidate_when_the_session_tree_is_unknown" "$OUT"; fi
run "$NONGIT" remove "$P1" "$SB/wt-x" feature/x
if [ "$RC" != 0 ] && [ -d "$SB/wt-x" ]; then ok "remove_refuses_when_the_session_tree_is_unknown"; else bad "remove_refuses_when_the_session_tree_is_unknown" "rc=$RC"; fi
rmdir "$NONGIT"

# --- remove re-checks that the worktree still holds the merged branch -------
git -C "$P1" worktree add -q "$SB/wt-other" -b feature/other
run "$SB" remove "$P1" "$SB/wt-other" feature/x
if [ "$RC" != 0 ] && [ -d "$SB/wt-other" ] && printf '%s' "$OUT" | grep -q 'does not hold the merged branch'; then
  ok "remove_refuses_a_worktree_on_another_branch"
else
  bad "remove_refuses_a_worktree_on_another_branch" "rc=$RC $OUT"
fi
git -C "$SB/wt-other" checkout -q --detach
run "$SB" remove "$P1" "$SB/wt-other" feature/other
if [ "$RC" != 0 ] && [ -d "$SB/wt-other" ]; then ok "remove_refuses_a_detached_worktree"; else bad "remove_refuses_a_detached_worktree" "rc=$RC $OUT"; fi
run "$SB" remove "$P1" "$SB/wt-other"
if [ "$RC" = 2 ] && [ -d "$SB/wt-other" ]; then ok "remove_requires_the_merged_branch"; else bad "remove_requires_the_merged_branch" "rc=$RC $OUT"; fi

# --- a dirty worktree stops the step ----------------------------------------
printf 'work\n' > "$SB/wt-x/new-file.txt"
run "$SB" remove "$P1" "$SB/wt-x" feature/x
if [ "$RC" != 0 ] && [ -d "$SB/wt-x" ] && printf '%s' "$OUT" | grep -q "Review it"; then ok "dirty_worktree_stops_the_step"; else bad "dirty_worktree_stops_the_step" "rc=$RC $OUT"; fi

# --- a clean worktree is removed without --force ----------------------------
rm -f "$SB/wt-x/new-file.txt"
rm -rf "$SB/wt-x/cache"
run "$SB" remove "$P1" "$SB/wt-x" feature/x
if [ "$RC" = 0 ] && [ ! -e "$SB/wt-x" ] && [ -z "$(git -C "$P1" worktree list --porcelain | grep "$SB/wt-x")" ]; then ok "clean_worktree_is_removed"; else bad "clean_worktree_is_removed" "rc=$RC $OUT"; fi

# --- an unregistered source tree is refused ---------------------------------
mkrepo "$SB/workspace/rogue"
run "$SB" list "$SB/workspace/rogue" main
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "not a valid working tree"; then ok "refuses_an_unregistered_source_tree"; else bad "refuses_an_unregistered_source_tree" "rc=$RC $OUT"; fi
rm -rf "$SB"

# --- a worktree that contains the ops root is refused -------------------------
# Split-portfolio layout: the project clone lives in a sibling workspace, and
# the ops fork sits inside a linked worktree of that clone.
SPLIT=$(mktemp -d)
SPLIT=$(cd -P "$SPLIT" && pwd)
mkrepo "$SPLIT/ws/p1"
git -C "$SPLIT/ws/p1" worktree add -q "$SPLIT/outer" -b feature/outer
OPS2="$SPLIT/outer/ops"
mkrepo "$OPS2"
: > "$OPS2/.apexyard-fork"
: > "$OPS2/onboarding.yaml"
printf 'projects:\n  - name: p1\n    repo: org/p1\n' > "$OPS2/apexyard.projects.yaml"
mkdir -p "$OPS2/.claude/hooks" "$OPS2/.claude/skills/approve-merge"
for f in _lib-active-ticket.sh _lib-read-config.sh _lib-portfolio-paths.sh _lib-ops-root.sh _lib-resolution-cache.sh _lib-path-resolve.sh; do
  cp "$HOOKS/$f" "$OPS2/.claude/hooks/$f"
done
cp "$SRC_ROOT/.claude/project-config.defaults.json" "$OPS2/.claude/project-config.defaults.json"
printf '{"portfolio":{"workspace_dir":"%s/ws"}}\n' "$SPLIT" > "$OPS2/.claude/project-config.json"
cp "$SKILL/remove-worktree.sh" "$OPS2/.claude/skills/approve-merge/remove-worktree.sh"
chmod +x "$OPS2/.claude/skills/approve-merge/remove-worktree.sh"
OUT=$(cd "$OPS2" && "$OPS2/.claude/skills/approve-merge/remove-worktree.sh" list "$SPLIT/ws/p1" feature/outer 2>&1)
if printf '%s' "$OUT" | grep -q 'refused (equals or contains the ops root)'; then ok "refuses_a_worktree_that_contains_the_ops_root"; else bad "refuses_a_worktree_that_contains_the_ops_root" "$OUT"; fi
OUT=$(cd "$OPS2" && "$OPS2/.claude/skills/approve-merge/remove-worktree.sh" remove "$SPLIT/ws/p1" "$SPLIT/outer" feature/outer 2>&1)
if [ -d "$SPLIT/outer" ] && printf '%s' "$OUT" | grep -q 'refused'; then ok "remove_refuses_a_worktree_that_contains_the_ops_root"; else bad "remove_refuses_a_worktree_that_contains_the_ops_root" "$OUT"; fi
rm -rf "$SPLIT"

# --- static checks on the skill and the helper -------------------------------
if grep -nE -- '--force|worktree remove -f| -f ' "$SKILL/remove-worktree.sh" "$SKILL/SKILL.md" | grep -vE 'never|no --force|no `--force`|Never' | grep -E 'worktree remove' | grep -q .; then
  bad "no_force_in_skill_or_helper" "found a forced removal"
else
  ok "no_force_in_skill_or_helper"
fi
# Every git call in the helper that touches worktrees uses -C.
bad_calls=$(grep -nE 'git (worktree|rev-parse --git-common)' "$SKILL/remove-worktree.sh" | grep -v 'git -C' | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE 'echo|usage|printf')
if [ -z "$bad_calls" ]; then ok "every_worktree_git_call_uses_C"; else bad "every_worktree_git_call_uses_C" "$bad_calls"; fi
if grep -q 'git -C "\$COMMON" worktree' "$SKILL/remove-worktree.sh"; then ok "git_calls_use_the_validated_common_dir"; else bad "git_calls_use_the_validated_common_dir" "no -C COMMON call"; fi
if grep -q 'remove-worktree.sh' "$SKILL/SKILL.md" && grep -q 'AskUserQuestion' "$SKILL/SKILL.md"; then ok "skill_asks_before_removing"; else bad "skill_asks_before_removing" "the skill does not name the helper and the prompt"; fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
