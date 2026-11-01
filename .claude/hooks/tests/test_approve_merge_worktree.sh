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
  for f in _lib-active-ticket.sh _lib-read-config.sh _lib-portfolio-paths.sh _lib-ops-root.sh _lib-resolution-cache.sh _lib-path-resolve.sh _lib-worktree-owner.sh; do
    cp "$HOOKS/$f" "$sb/.claude/hooks/$f"
  done
  cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  cp "$SKILL/remove-worktree.sh" "$sb/.claude/skills/approve-merge/remove-worktree.sh"
  chmod +x "$sb/.claude/skills/approve-merge/remove-worktree.sh"
  mkrepo "$sb/workspace/p1"
  git init -q --bare "$sb/remote.git"
  git -C "$sb/workspace/p1" remote add origin "$sb/remote.git"
  git -C "$sb/workspace/p1" push -q origin HEAD:refs/heads/main
  echo "$sb"
}

# run <cwd> <args...>: sets OUT and RC
run() {
  local cwd="$1"
  shift
  OUT=$(cd "$cwd" && "$BASH" "$SB/.claude/skills/approve-merge/remove-worktree.sh" "$@" 2>&1)
  RC=$?
}

SB=$(make_sb)
P1="$SB/workspace/p1"
git -C "$P1" worktree add -q "$SB/wt-x" -b feature/x
printf 'cache\n' > "$SB/wt-x/.gitignore"
git -C "$SB/wt-x" add .gitignore
git -C "$SB/wt-x" commit -q -m ignore
git -C "$SB/wt-x" push -q origin HEAD:refs/heads/feature/x
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
  "$BASH" "$SB/.claude/skills/approve-merge/remove-worktree.sh" list "$P1" feature/x 2>&1)
case "$OUT" in
  ok$'\t'"$SB/wt-x"*) ok "list_ignores_the_callers_git_environment" ;;
  *) bad "list_ignores_the_callers_git_environment" "$OUT" ;;
esac
# Variables outside the four that pick the repository are scrubbed too, from
# git's own list.
OUT=$(cd "$SB" && GIT_OBJECT_DIRECTORY="$SB/no-such-objects" GIT_CONFIG_PARAMETERS="'core.bare'='true'" \
  "$BASH" "$SB/.claude/skills/approve-merge/remove-worktree.sh" list "$P1" feature/x 2>&1)
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
if [ "$RC" != 0 ] && [ -d "$SB/wt-x" ] && printf '%s' "$OUT" | grep -q "uncommitted changes"; then ok "dirty_worktree_stops_the_step"; else bad "dirty_worktree_stops_the_step" "rc=$RC $OUT"; fi

# --- a clean worktree is removed without --force ----------------------------
rm -f "$SB/wt-x/new-file.txt"
rm -rf "$SB/wt-x/cache"

# --- owner checks use the public API with deterministic process fixtures ---
mkdir "$SB/bin"
cat > "$SB/bin/ps" <<'SCRIPT'
#!/bin/sh
if [ "${2:-}" = lstart= ]; then printf 'Sat Oct 31 10:00:00 2026\n'; exit 0; fi
exec /bin/ps "$@"
SCRIPT
cat > "$SB/bin/sysctl" <<'SCRIPT'
#!/bin/sh
printf '{ sec = 123, usec = 456 }\n'
SCRIPT
chmod +x "$SB/bin/ps" "$SB/bin/sysctl"
CLEANUP_BASE_PATH=$PATH
export PATH="$SB/bin:$PATH"
# shellcheck source=/dev/null
. "$HOOKS/_lib-worktree-owner.sh"
OWNER_RECORD="$(git -C "$SB/wt-x" rev-parse --absolute-git-dir)/apexyard-owner"
BOOT=$(_wto_host_boot_id)
owner_record() {
  local mode=$1 boot="$BOOT"
  [ "$mode" != dead ] || boot=older-boot
  jq -cn --arg mode "$mode" --arg boot "$boot" --argjson pid "$$" '
    {version:1,generation:7,status:"active",lease_heartbeat_at:1,lease_expires_at:2,
     owner:{session_id:"cleanup-session",harness:"claude-code",pid:$pid,
       pid_start:"Sat Oct 31 10:00:00 2026",boot_id:$boot}} |
    if $mode == "unknown" then
      .owner = {session_id:"other-session",harness:null,pid:null,pid_start:null,boot_id:null}
    elif $mode == "released" then .released_by = .owner | .owner = null | .status = "released"
    else . end' > "$OWNER_RECORD"
}
expect_refused() {
  local label=$1 reason=$2
  shift 2
  run "$SB" list "$P1" feature/x "$@"
  if printf '%s' "$OUT" | grep -Fq "refused ($reason"; then ok "$label"; else bad "$label" "$OUT"; fi
}
expect_ok() {
  local label=$1
  shift
  run "$SB" list "$P1" feature/x "$@"
  case "$OUT" in ok$'\t'"$SB/wt-x"*) ok "$label" ;; *) bad "$label" "$OUT" ;; esac
}
owner_record alive
expect_refused alive_owner_refuses owner\ alive
printf 'dirty\n' > "$SB/wt-x/owner.json"
expect_refused owner_refusal_precedes_dirty owner\ alive
rm -f "$SB/wt-x/owner.json"
owner_record unknown
expect_refused session_only_owner_refuses 'owner unknown:'
: > "$SB/wt-x/removal-guard"
run "$SB" remove "$P1" "$SB/wt-x" feature/x
if [ "$RC" != 0 ] && [ -d "$SB/wt-x" ] && printf '%s' "$OUT" | grep -q 'owner unknown:'; then
  ok remove_rechecks_unknown_owner
else bad remove_rechecks_unknown_owner "rc=$RC $OUT"; fi
rm -f "$SB/wt-x/removal-guard"
for state in dead released; do
  owner_record "$state"
  expect_ok "${state}_owner_continues"
done
rm -f "$OWNER_RECORD"
expect_ok no_owner_continues
printf '{broken\n' > "$OWNER_RECORD"
expect_refused malformed_owner_refuses 'owner unknown:'
owner_record unknown
if worktree_owner_force_release "$SB/wt-x" 7 &&
  jq -e '.forced == true and .generation == 8 and .status == "released" and .owner == null' "$OWNER_RECORD" >/dev/null; then
  ok generation_matched_force_release
else bad generation_matched_force_release 'record was not force released'; fi
expect_ok forced_release_allows_new_offer
owner_record unknown
cp "$OWNER_RECORD" "$SB/owner-before"
if ! worktree_owner_force_release "$SB/wt-x" 6 && cmp -s "$SB/owner-before" "$OWNER_RECORD"; then
  ok stale_force_release_preserves_bytes
else bad stale_force_release_preserves_bytes 'stale generation changed the record'; fi
rm -f "$OWNER_RECORD"

# --- preservation includes every untracked file, including owner.json -------
printf 'work\n' > "$SB/wt-x/owner.json"
expect_refused untracked_owner_json_is_dirty 'uncommitted changes'
rm -f "$SB/wt-x/owner.json"
git -C "$SB/wt-x" commit -q --allow-empty -m unpushed
UNPUSHED_HEAD=$(git -C "$SB/wt-x" rev-parse HEAD)
expect_refused unpushed_head_refuses unpushed
git -C "$P1" worktree add -q "$SB/unpushed-removal" -b feature/unpushed "$UNPUSHED_HEAD"
run "$SB" remove "$P1" "$SB/unpushed-removal" feature/unpushed
if [ "$RC" != 0 ] && [ -d "$SB/unpushed-removal" ] && printf '%s' "$OUT" | grep -Fq 'remove-worktree: refused, unpushed commits:'; then
  ok remove_rechecks_unpushed_head
else bad remove_rechecks_unpushed_head "rc=$RC $OUT"; fi
expect_ok merged_head_equal_preserves --merged-head "$UNPUSHED_HEAD"
git -C "$P1" worktree add -q "$SB/merged-descendant" -b feature/descendant "$UNPUSHED_HEAD"
git -C "$SB/merged-descendant" commit -q --allow-empty -m descendant
MERGED_DESCENDANT=$(git -C "$SB/merged-descendant" rev-parse HEAD)
expect_ok merged_head_descendant_preserves --merged-head "$MERGED_DESCENDANT"
NON_ANCESTOR=$(git -C "$P1" rev-parse HEAD)
expect_refused merged_head_nonancestor_refuses unpushed --merged-head "$NON_ANCESTOR"
expect_refused unavailable_merged_head_refuses unpushed --merged-head 0000000000000000000000000000000000000000
run "$SB" remove "$P1" "$SB/unpushed-removal" feature/unpushed --merged-head "$MERGED_DESCENDANT"
if [ "$RC" = 0 ] && [ ! -e "$SB/unpushed-removal" ]; then
  ok merged_head_allows_removal_after_recheck
else bad merged_head_allows_removal_after_recheck "rc=$RC $OUT"; fi
printf 'work\n' > "$SB/wt-x/dirty"
expect_refused merged_head_does_not_allow_dirty 'uncommitted changes' --merged-head "$UNPUSHED_HEAD"
rm -f "$SB/wt-x/dirty"
git -C "$SB/wt-x" push -q origin HEAD:refs/heads/preserved-elsewhere
expect_ok any_remote_ref_preserves

# Failed Git inspection must not look like a clean or preserved checkout.
export CLEANUP_REAL_GIT
CLEANUP_REAL_GIT=$(command -v git)
cat > "$SB/bin/git" <<'SCRIPT'
#!/bin/sh
for argument in "$@"; do
  if [ "$argument" = "${CLEANUP_GIT_FAIL:-}" ]; then exit 1; fi
  if [ "$argument" = rev-list ] && [ "${CLEANUP_BAD_COUNT:-}" = 1 ]; then printf 'invalid\n'; exit 0; fi
done
exec "$CLEANUP_REAL_GIT" "$@"
SCRIPT
chmod +x "$SB/bin/git"
CLEANUP_GIT_FAIL=status expect_refused failed_status_refuses 'preservation unknown:checkout unknown'
CLEANUP_GIT_FAIL=rev-list expect_refused failed_commit_inspection_refuses 'preservation unknown:commits unknown'
CLEANUP_BAD_COUNT=1 expect_refused invalid_commit_count_refuses 'preservation unknown:commits unknown'

# Omit jq from a minimal command path while retaining the real resolver.
mkdir "$SB/no-jq"
for utility in git dirname sed awk cat sort head tr cut tail basename readlink realpath stat date mktemp wc sleep grep uname; do
  utility_path=$(command -v "$utility") || continue
  ln -s "$utility_path" "$SB/no-jq/$utility"
done
PATH="$SB/no-jq" expect_refused missing_jq_refuses 'owner check unavailable'

# --- unavailable owner checks fail closed after all original checks ---------
mv "$SB/.claude/hooks/_lib-worktree-owner.sh" "$SB/owner-library"
expect_refused missing_library_refuses 'owner check unavailable'
run "$SB" list "$P1" feature/descendant
if printf '%s' "$OUT" | grep -q 'refused (owner check unavailable)'; then
  ok missing_library_refuses_another_candidate
else bad missing_library_refuses_another_candidate "$OUT"; fi
: > "$SB/wt-x/removal-guard"
run "$SB" remove "$P1" "$SB/wt-x" feature/x
if [ "$RC" != 0 ] && [ -d "$SB/wt-x" ] && printf '%s' "$OUT" | grep -q 'owner check unavailable'; then
  ok missing_library_refuses_removal
else bad missing_library_refuses_removal "rc=$RC $OUT"; fi
rm -f "$SB/wt-x/removal-guard"
for state in main locked own missing; do
  case "$state" in
    main) run "$SB" list "$P1" "$(git -C "$P1" branch --show-current)"; reason='main worktree' ;;
    locked) run "$SB" list "$P1" feature/lock; reason=locked ;;
    own) run "$SB/wt-x" list "$P1" feature/x; reason="the session's own tree" ;;
    missing)
      git -C "$P1" worktree add -q "$SB/missing" -b feature/missing
      rm -rf "$SB/missing"
      run "$SB" list "$P1" feature/missing; reason='path is missing' ;;
  esac
  if printf '%s' "$OUT" | grep -Fq "refused ($reason)"; then
    ok "${state}_check_precedes_owner"
  else bad "${state}_check_precedes_owner" "$OUT"; fi
done
mv "$SB/owner-library" "$SB/.claude/hooks/_lib-worktree-owner.sh"

run "$SB" remove "$P1" "$SB/wt-x" feature/x
if [ "$RC" = 0 ] && [ ! -e "$SB/wt-x" ] && [ -z "$(git -C "$P1" worktree list --porcelain | grep "$SB/wt-x")" ]; then ok "clean_worktree_is_removed"; else bad "clean_worktree_is_removed" "rc=$RC $OUT"; fi

# --- an unregistered source tree is refused ---------------------------------
mkrepo "$SB/workspace/rogue"
run "$SB" list "$SB/workspace/rogue" main
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "not a valid working tree"; then ok "refuses_an_unregistered_source_tree"; else bad "refuses_an_unregistered_source_tree" "rc=$RC $OUT"; fi
export PATH="$CLEANUP_BASE_PATH"
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
OUT=$(cd "$OPS2" && "$BASH" "$OPS2/.claude/skills/approve-merge/remove-worktree.sh" list "$SPLIT/ws/p1" feature/outer 2>&1)
if printf '%s' "$OUT" | grep -q 'refused (equals or contains the ops root)'; then ok "refuses_a_worktree_that_contains_the_ops_root"; else bad "refuses_a_worktree_that_contains_the_ops_root" "$OUT"; fi
OUT=$(cd "$OPS2" && "$BASH" "$OPS2/.claude/skills/approve-merge/remove-worktree.sh" remove "$SPLIT/ws/p1" "$SPLIT/outer" feature/outer 2>&1)
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
OFFER="$SRC_ROOT/docs/skills/approve-merge-worktree-offer.md"
if grep -q 'Never offer.*alive' "$OFFER" && grep -q 'worktree_owner_force_release' "$OFFER" &&
  grep -q 'generation' "$OFFER" && grep -q 'explicit yes' "$OFFER" && grep -q 'AskUserQuestion' "$OFFER"; then
  ok unknown_release_requires_explicit_yes_and_never_alive
else bad unknown_release_requires_explicit_yes_and_never_alive 'release instructions missing'; fi
if grep -q -- '--merged-head "\$HEAD_SHA"' "$SKILL/SKILL.md" &&
  grep -q -- '--merged-head "\$HEAD_SHA"' "$OFFER"; then
  ok skill_passes_verified_merged_head
else bad skill_passes_verified_merged_head 'merged head argument missing'; fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
