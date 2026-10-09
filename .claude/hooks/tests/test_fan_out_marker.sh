#!/bin/bash
# /fan-out writer worktrees (AgDR-0222): prepare-worktree.sh creates each
# worktree from the task's own source tree and writes a ticket marker into
# the git dir of the new worktree.
#
#   prepare_worktree_creates_from_clone_and_writes_marker
#   prepare_worktree_creates_from_ops_fork_for_an_ops_task
#   prepared_worktree_passes_gate
#   a_writer_under_claude_worktrees_is_gated_by_its_marker
#   prepare_worktree_refuses_a_tree_with_no_ticket
#   marker_write_failure_removes_tree

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOKS="$SRC_ROOT/.claude/hooks"

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

# make_sb: an ops fork that holds the hooks and the skill helper, with a
# registered clone p1 that has a ticket marker.
make_sb() {
  local sb f
  sb=$(mktemp -d)
  sb=$(cd -P "$sb" && pwd)
  mkrepo "$sb"
  : > "$sb/.apexyard-fork"
  : > "$sb/onboarding.yaml"
  printf 'projects:\n  - name: p1\n    repo: org/p1\n' > "$sb/apexyard.projects.yaml"
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/skills/fan-out" "$sb/.claude/worktrees" "$sb/workspace"
  for f in require-active-ticket.sh _lib-awk-fallback.sh _lib-detect-bash-write.sh _lib-read-config.sh _lib-path-resolve.sh \
           _lib-active-ticket.sh _lib-mask-quoted.sh _lib-ticket-path-exemptions.sh _lib-portfolio-paths.sh _lib-ops-root.sh _lib-resolution-cache.sh; do
    cp "$HOOKS/$f" "$sb/.claude/hooks/$f"
  done
  cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  cp "$SRC_ROOT/.claude/skills/fan-out/prepare-worktree.sh" "$sb/.claude/skills/fan-out/prepare-worktree.sh"
  chmod +x "$sb/.claude/skills/fan-out/prepare-worktree.sh" "$sb/.claude/hooks/"*.sh
  mkrepo "$sb/workspace/p1"
  printf 'repo=org/p1\nnumber=42\ntitle=Fan out ticket\nurl=https://example.test/42\n' > "$sb/workspace/p1/.git/apexyard-ticket"
  printf 'repo=org/ops\nnumber=7\ntitle=Ops ticket\nurl=https://example.test/7\n' > "$sb/.git/apexyard-ticket"
  echo "$sb"
}

prepare() {
  local sb="$1"
  shift
  (cd "$sb" && "$sb/.claude/skills/fan-out/prepare-worktree.sh" "$@")
}

# --- creates from the clone and writes the marker -------------------------
SB=$(make_sb)
WT="$SB/.claude/worktrees/feature-GH-42-fan-out"
out=$(prepare "$SB" "$SB/workspace/p1" "$WT" "feature/GH-42-fan-out" 2>&1)
rc=$?
common=$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
wtg=$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)
if [ "$rc" = 0 ] && [ "$common" = "$SB/workspace/p1/.git" ]; then ok "prepare_worktree_creates_from_clone"; else bad "prepare_worktree_creates_from_clone" "rc=$rc common=$common out=$out"; fi
if [ -f "$wtg/apexyard-ticket" ] && grep -q '^repo=org/p1$' "$wtg/apexyard-ticket" && grep -q '^number=42$' "$wtg/apexyard-ticket" && grep -q '^suggested_branch=feature/GH-42-fan-out$' "$wtg/apexyard-ticket"; then
  ok "prepare_worktree_writes_marker_with_the_source_ticket"
else
  bad "prepare_worktree_writes_marker_with_the_source_ticket" "$(cat "$wtg/apexyard-ticket" 2>/dev/null)"
fi
if [ ! -f "$SB/.git/worktrees/$(basename "$WT")/apexyard-ticket" ] && [ -z "$(git -C "$SB" worktree list --porcelain | grep "$WT")" ]; then ok "prepare_worktree_does_not_touch_the_ops_fork"; else bad "prepare_worktree_does_not_touch_the_ops_fork" "ops fork lists the worktree"; fi

# --- the new worktree passes the ticket gate -----------------------------
# These worktrees sit outside .claude/worktrees/, the default fan-out place.
# The next block covers that place. A plain worktree with no marker is the
# negative control.
GWT="$SB/wt-gate"
prepare "$SB" "$SB/workspace/p1" "$GWT" "feature/GH-42-gate" >/dev/null 2>&1
git -C "$SB/workspace/p1" worktree add -q "$SB/wt-plain" -b feature/plain
payload=$(jq -nc --arg p "$GWT/src/a.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
ERR=$(cd "$SB" && printf '%s' "$payload" | bash "$SB/.claude/hooks/require-active-ticket.sh" 2>&1 >/dev/null)
rc=$?
if [ "$rc" = 0 ]; then ok "prepared_worktree_passes_gate"; else bad "prepared_worktree_passes_gate" "rc=$rc ${ERR:0:300}"; fi
payload=$(jq -nc --arg p "$SB/wt-plain/src/a.ts" '{tool_name:"Edit", tool_input:{file_path:$p}}')
ERR=$(cd "$SB" && printf '%s' "$payload" | bash "$SB/.claude/hooks/require-active-ticket.sh" 2>&1 >/dev/null)
rc=$?
if [ "$rc" = 2 ]; then ok "a_worktree_with_no_marker_is_blocked"; else bad "a_worktree_with_no_marker_is_blocked" "rc=$rc"; fi
rm -rf "$SB"

# --- a writer under .claude/worktrees/ is gated by its own marker ----------
# Source under .claude/worktrees/ needs a ticket like any other source. The
# ops fork's own marker is removed, so only the writer's marker can pass it.
SB=$(make_sb)
rm -f "$SB/.git/apexyard-ticket"
gate_wt() {
  local payload
  payload=$(jq -nc --arg p "$1" '{tool_name:"Edit", tool_input:{file_path:$p}}')
  ERR=$(cd "$SB" && printf '%s' "$payload" | bash "$SB/.claude/hooks/require-active-ticket.sh" 2>&1 >/dev/null)
  RC=$?
}
WT="$SB/.claude/worktrees/feature-GH-60-writer"
prepare "$SB" "$SB/workspace/p1" "$WT" "feature/GH-60-writer" >/dev/null 2>&1
rm -rf "$SB/.claude/session"
gate_wt "$WT/src/a.ts"
if [ "$RC" = 0 ]; then ok "a_writer_under_claude_worktrees_passes_with_its_marker"; else bad "a_writer_under_claude_worktrees_passes_with_its_marker" "rc=$RC ${ERR:0:300}"; fi
git -C "$SB/workspace/p1" worktree add -q "$SB/.claude/worktrees/plain" -b feature/plain
gate_wt "$SB/.claude/worktrees/plain/src/a.ts"
if [ "$RC" = 2 ]; then ok "a_plain_worktree_under_claude_worktrees_is_blocked"; else bad "a_plain_worktree_under_claude_worktrees_is_blocked" "rc=$RC"; fi
git -C "$SB/workspace/p1" worktree add -q "$SB/.claude/worktrees/legacy" -b feature/legacy
mkdir -p "$SB/.claude/session/tickets/p1"
printf 'repo=org/p1\nnumber=61\n' > "$SB/.claude/session/tickets/p1/feature__legacy"
gate_wt "$SB/.claude/worktrees/legacy/src/a.ts"
if [ "$RC" = 2 ]; then ok "an_old_per_branch_marker_alone_does_not_pass_under_claude_worktrees"; else bad "an_old_per_branch_marker_alone_does_not_pass_under_claude_worktrees" "rc=$RC"; fi
rm -rf "$SB"

# --- the caller's git environment does not redirect the worktree ----------
SB=$(make_sb)
mkrepo "$SB/elsewhere-repo"
WT="$SB/.claude/worktrees/feature-GH-48-env"
out=$(cd "$SB" && GIT_DIR="$SB/elsewhere-repo/.git" GIT_WORK_TREE="$SB/elsewhere-repo" \
  "$SB/.claude/skills/fan-out/prepare-worktree.sh" "$SB/workspace/p1" "$WT" "feature/GH-48-env" 2>&1)
rc=$?
common=$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ "$rc" = 0 ] && [ "$common" = "$SB/workspace/p1/.git" ] && [ -z "$(git -C "$SB/elsewhere-repo" worktree list --porcelain | grep "$WT")" ]; then
  ok "prepare_worktree_ignores_the_callers_git_environment"
else
  bad "prepare_worktree_ignores_the_callers_git_environment" "rc=$rc common=$common out=$out"
fi
# Variables outside the four that pick the repository are scrubbed too, from
# git's own list. An object store that does not exist would make the branch
# creation fail.
WT2="$SB/.claude/worktrees/feature-GH-49-env"
out=$(cd "$SB" && GIT_OBJECT_DIRECTORY="$SB/no-such-objects" GIT_CONFIG_PARAMETERS="'core.bare'='true'" \
  "$SB/.claude/skills/fan-out/prepare-worktree.sh" "$SB/workspace/p1" "$WT2" "feature/GH-49-env" 2>&1)
rc=$?
if [ "$rc" = 0 ] && [ -f "$WT2/.git" ] && [ ! -e "$SB/no-such-objects" ]; then
  ok "prepare_worktree_scrubs_gits_local_env_vars"
else
  bad "prepare_worktree_scrubs_gits_local_env_vars" "rc=$rc out=$out"
fi
rm -rf "$SB"

# --- an ops task is created from the ops fork -----------------------------
SB=$(make_sb)
WT="$SB/.claude/worktrees/chore-GH-7-ops"
out=$(prepare "$SB" "$SB" "$WT" "chore/GH-7-ops" 2>&1)
rc=$?
common=$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
wtg=$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)
if [ "$rc" = 0 ] && [ "$common" = "$SB/.git" ] && grep -q '^number=7$' "$wtg/apexyard-ticket"; then ok "prepare_worktree_creates_from_ops_fork_for_an_ops_task"; else bad "prepare_worktree_creates_from_ops_fork_for_an_ops_task" "rc=$rc common=$common out=$out"; fi
rm -rf "$SB"

# --- explicit ticket fields give the task its own ticket ------------------
SB=$(make_sb)
WT="$SB/.claude/worktrees/feature-GH-50-own"
out=$(prepare "$SB" "$SB/workspace/p1" "$WT" "feature/GH-50-own" org/p1 50 "Own ticket" "https://example.test/50" 2>&1)
rc=$?
wtg=$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)
if [ "$rc" = 0 ] && grep -q '^number=50$' "$wtg/apexyard-ticket" && grep -q '^title=Own ticket$' "$wtg/apexyard-ticket"; then ok "prepare_worktree_uses_explicit_ticket_fields"; else bad "prepare_worktree_uses_explicit_ticket_fields" "rc=$rc out=$out"; fi
rm -rf "$SB"

# --- a source tree with no ticket is refused and nothing is created -------
SB=$(make_sb)
rm -f "$SB/workspace/p1/.git/apexyard-ticket"
WT="$SB/.claude/worktrees/feature-GH-43-none"
out=$(prepare "$SB" "$SB/workspace/p1" "$WT" "feature/GH-43-none" 2>&1)
rc=$?
if [ "$rc" != 0 ] && [ ! -e "$WT" ] && [ -z "$(git -C "$SB/workspace/p1" branch --list 'feature/GH-43-none')" ] && printf '%s' "$out" | grep -q "no active ticket"; then ok "prepare_worktree_refuses_a_tree_with_no_ticket"; else bad "prepare_worktree_refuses_a_tree_with_no_ticket" "rc=$rc out=$out"; fi
rm -rf "$SB"

# --- a source tree that is not registered gets the old-layout marker only --
# The new worktree fails validation, so its git dir marker is not written. The
# old /fan-out flow covered it with the session-level marker, and so does this.
SB=$(make_sb)
mkrepo "$SB/workspace/rogue"
WT="$SB/.claude/worktrees/feature-GH-44-rogue"
out=$(prepare "$SB" "$SB/workspace/rogue" "$WT" "feature/GH-44-rogue" org/rogue 44 "Rogue" "u" 2>&1)
rc=$?
wtg=$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)
if [ "$rc" = 0 ] && [ -d "$WT" ] && [ ! -e "$wtg/apexyard-ticket" ] \
   && grep -q '^number=44$' "$SB/.claude/session/current-ticket" 2>/dev/null \
   && printf '%s' "$out" | grep -q "only the old-layout marker is written"; then
  ok "prepare_worktree_writes_only_the_old_marker_for_an_unregistered_clone"
else
  bad "prepare_worktree_writes_only_the_old_marker_for_an_unregistered_clone" "rc=$rc out=$out"
fi
rm -rf "$SB"

# --- an existing session-level old marker is kept --------------------------
SB=$(make_sb)
mkrepo "$SB/workspace/rogue"
mkdir -p "$SB/.claude/session"
printf 'repo=org/ops\nnumber=7\n' > "$SB/.claude/session/current-ticket"
WT="$SB/.claude/worktrees/feature-GH-46-rogue"
out=$(prepare "$SB" "$SB/workspace/rogue" "$WT" "feature/GH-46-rogue" org/rogue 46 "Rogue" "u" 2>&1)
rc=$?
if [ "$rc" = 0 ] && grep -q '^number=7$' "$SB/.claude/session/current-ticket" && printf '%s' "$out" | grep -q "kept the existing"; then
  ok "prepare_worktree_keeps_an_existing_session_marker"
else
  bad "prepare_worktree_keeps_an_existing_session_marker" "rc=$rc out=$out"
fi
rm -rf "$SB"

# --- the old-layout per-worktree marker is written for a registered repo ----
SB=$(make_sb)
WT="$SB/.claude/worktrees/feature-GH-47-dual"
out=$(prepare "$SB" "$SB/workspace/p1" "$WT" "feature/GH-47-dual" 2>&1)
rc=$?
if [ "$rc" = 0 ] && grep -q '^number=42$' "$SB/.claude/session/tickets/p1/feature__GH-47-dual" 2>/dev/null; then
  ok "prepare_worktree_writes_the_old_per_worktree_marker"
else
  bad "prepare_worktree_writes_the_old_per_worktree_marker" "rc=$rc out=$out"
fi
rm -rf "$SB"

# --- a failed marker write removes the tree and the branch ----------------
SB=$(make_sb)
WT="$SB/.claude/worktrees/feature-GH-45-fail"
SHIM="$SB/shim"
mkdir -p "$SHIM"
printf '#!/bin/bash\nexit 1\n' > "$SHIM/mktemp"
chmod +x "$SHIM/mktemp"
out=$(cd "$SB" && PATH="$SHIM:$PATH" "$SB/.claude/skills/fan-out/prepare-worktree.sh" "$SB/workspace/p1" "$WT" "feature/GH-45-fail" 2>&1)
rc=$?
if [ "$rc" != 0 ] && [ ! -e "$WT" ] && [ -z "$(git -C "$SB/workspace/p1" worktree list --porcelain | grep "$WT")" ] \
   && [ -z "$(git -C "$SB/workspace/p1" branch --list 'feature/GH-45-fail')" ]; then
  ok "marker_write_failure_removes_tree"
else
  bad "marker_write_failure_removes_tree" "rc=$rc exists=$([ -e "$WT" ] && echo yes || echo no) out=$out"
fi
rm -rf "$SB"

# --- no --force anywhere in the skill or the helper -----------------------
if grep -nE -- '--force|worktree remove -f' "$SRC_ROOT/.claude/skills/fan-out/prepare-worktree.sh" | grep -vE '^[0-9]+:[[:space:]]*#|never uses --force|no .--force' | grep -q .; then
  bad "no_force_in_helper" "the helper uses --force"
else
  ok "no_force_in_helper"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
