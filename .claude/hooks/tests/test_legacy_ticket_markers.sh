#!/bin/bash
# Old-layout ticket markers during the move (AgDR-0222, Backward
# compatibility). When no validated tree holds a new marker, the gate runs the
# old resolution unchanged: tickets/<project>/<branch> for a linked worktree
# inside the workspace dir, then tickets/<project>, then current-ticket. A new
# marker in a validated tree wins. A SessionStart notice lists the old files.
#
#   1  tickets/p1 passes an edit in p1's main clone
#   2  tickets/p1 passes whatever repo it names, as before
#   3  a linked worktree outside the workspace dir has no project, so only
#      current-ticket counts there, as before
#   4  the per-branch form counts for a linked worktree inside the workspace
#      dir, and not for the main clone
#   5  current-ticket passes an ops edit and a p1 edit when tickets/p1 is absent
#   6  current-ticket naming a registered project passes an ops edit
#   7  a new marker wins over a legacy file with another ticket
#   8  a link at the legacy file or at .claude/session is followed, as before
#   10 SessionStart prints the notice when an old file exists, else nothing
#   11 a legacy pass is covered by that notice
#   12 an ops .git that links to p1's .git stops the new marker in p1 from
#      being trusted, and the old resolution decides

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

make_sb() {
  local sb f
  sb=$(mktemp -d)
  sb=$(cd -P "$sb" && pwd)
  mkrepo "$sb"
  : > "$sb/.apexyard-fork"
  : > "$sb/onboarding.yaml"
  cat > "$sb/apexyard.projects.yaml" <<'YAML'
projects:
  - name: p1
    repo: org/p1
  - name: p2
    repo: org/p2
  - name: p3
    repos:
      - org/p3a
      - org/p3b
    primary: org/p3a
  - name: p4
    repos: [org/p4a, "org/p4b"]
YAML
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session/tickets" "$sb/workspace"
  for f in require-active-ticket.sh warn-legacy-ticket-markers.sh dispatch-session-start.sh _lib-detect-bash-write.sh _lib-read-config.sh \
           _lib-path-resolve.sh _lib-active-ticket.sh _lib-mask-quoted.sh _lib-ticket-path-exemptions.sh _lib-portfolio-paths.sh \
           _lib-ops-root.sh _lib-resolution-cache.sh; do
    cp "$HOOKS/$f" "$sb/.claude/hooks/$f"
  done
  cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  chmod +x "$sb/.claude/hooks/"*.sh
  mkrepo "$sb/workspace/p1"
  git -C "$sb/workspace/p1" worktree add -q "$sb/wt1" -b wt1
  echo "$sb"
}

edit_json() { jq -nc --arg p "$1" '{tool_name:"Edit", tool_input:{file_path:$p}}'; }
hook() {
  local sb="$1" path="$2"
  ERR=$(cd "$sb" && printf '%s' "$(edit_json "$path")" | bash "$sb/.claude/hooks/require-active-ticket.sh" 2>&1 >/dev/null)
  RC=$?
}
expect() {
  local name="$1" want="$2" rx="${3:-}"
  if [ "$RC" != "$want" ]; then bad "$name" "want rc=$want got $RC (${ERR:0:300})"; return; fi
  if [ -n "$rx" ] && ! printf '%s' "$ERR" | grep -Eq "$rx"; then bad "$name" "stderr did not match /$rx/: ${ERR:0:300}"; return; fi
  ok "$name"
}
legacy() { printf 'repo=%s\nnumber=%s\n' "$2" "$3" > "$1"; }

# 1
SB=$(make_sb)
legacy "$SB/.claude/session/tickets/p1" org/p1 7
hook "$SB" "$SB/workspace/p1/src/a.ts"
expect "1 legacy tickets/p1 passes in p1's main clone" 0
rm -rf "$SB"

# 2
SB=$(make_sb)
legacy "$SB/.claude/session/tickets/p1" org/p2 7
hook "$SB" "$SB/workspace/p1/src/a.ts"
expect "2 legacy tickets/p1 naming p2 still passes, as before" 0
rm -rf "$SB"

# 3
SB=$(make_sb)
legacy "$SB/.claude/session/tickets/p1" org/p1 7
hook "$SB" "$SB/wt1/src/a.ts"
expect "3a a worktree outside the workspace dir is not covered by tickets/p1" 2 BLOCKED
legacy "$SB/.claude/session/current-ticket" org/p1 8
hook "$SB" "$SB/wt1/src/a.ts"
expect "3b current-ticket covers a worktree outside the workspace dir" 0
rm -rf "$SB"

# 4
SB=$(make_sb)
mkdir -p "$SB/.claude/session/tickets/p1"
git -C "$SB/workspace/p1" worktree add -q "$SB/workspace/p1/.wt/inner" -b inner
legacy "$SB/.claude/session/tickets/p1/inner" org/p1 7
hook "$SB" "$SB/workspace/p1/src/a.ts"
expect "4a the per-branch form does not cover the main clone" 2 BLOCKED
hook "$SB" "$SB/workspace/p1/.wt/inner/src/a.ts"
expect "4b the per-branch form covers a linked worktree inside the workspace dir" 0
rm -rf "$SB"

# 5
SB=$(make_sb)
legacy "$SB/.claude/session/current-ticket" org/elsewhere 8
hook "$SB" "$SB/src/a.ts"
expect "5a current-ticket passes an ops edit" 0
hook "$SB" "$SB/workspace/p1/src/a.ts"
expect "5b current-ticket passes a p1 edit when tickets/p1 is absent" 0
rm -rf "$SB"

# 6
for r in org/p1 org/p3a ORG/P3B org/p4a; do
  SB=$(make_sb)
  legacy "$SB/.claude/session/current-ticket" "$r" 8
  hook "$SB" "$SB/src/a.ts"
  expect "6 current-ticket naming $r passes an ops edit, as before" 0
  rm -rf "$SB"
done

# 7 (in-process)
SB=$(make_sb)
legacy "$SB/.claude/session/tickets/p1" org/p1 7
printf 'repo=org/p1\nnumber=99\n' > "$SB/workspace/p1/.git/apexyard-ticket"
out=$(env -i HOME="$HOME" PATH="$PATH" APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1 \
  bash -c "cd '$SB' && . '$SB/.claude/hooks/_lib-active-ticket.sh' && active_ticket_init && active_ticket_lookup '$SB/workspace/p1/a.ts'; echo \"\$REPLY \$AT_SOURCE\"" 2>&1)
if [ "$out" = "$SB/workspace/p1/.git/apexyard-ticket tree" ]; then ok "7 a new marker wins over a legacy file"; else bad "7" "$out"; fi
rm -f "$SB/workspace/p1/.git/apexyard-ticket"
out=$(env -i HOME="$HOME" PATH="$PATH" APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1 \
  bash -c "cd '$SB' && . '$SB/.claude/hooks/_lib-active-ticket.sh' && active_ticket_init && active_ticket_lookup '$SB/workspace/p1/a.ts'; echo \"\$REPLY \$AT_SOURCE\"" 2>&1)
if [ "$out" = "$SB/.claude/session/tickets/p1 legacy" ]; then ok "7b without a new marker the legacy file decides"; else bad "7b" "$out"; fi
rm -rf "$SB"

# 8
SB=$(make_sb)
legacy "$SB/real-ticket" org/p1 7
ln -s "$SB/real-ticket" "$SB/.claude/session/tickets/p1"
hook "$SB" "$SB/workspace/p1/src/a.ts"
expect "8a a legacy file that is a symlink is followed, as before" 0
rm -f "$SB/.claude/session/tickets/p1"
mkdir -p "$SB/elsewhere/tickets"
legacy "$SB/elsewhere/tickets/p1" org/p1 7
rm -rf "$SB/.claude/session"
ln -s "$SB/elsewhere" "$SB/.claude/session"
hook "$SB" "$SB/workspace/p1/src/a.ts"
expect "8b a symlink at .claude/session is followed, as before" 0
rm -rf "$SB"

# 10 and 11
SB=$(make_sb)
out=$(cd "$SB" && bash "$SB/.claude/hooks/warn-legacy-ticket-markers.sh" </dev/null 2>&1)
if [ -z "$out" ]; then ok "10a SessionStart prints nothing when no old file exists"; else bad "10a" "$out"; fi
legacy "$SB/.claude/session/tickets/p1" org/p1 7
out=$(cd "$SB" && bash "$SB/.claude/hooks/warn-legacy-ticket-markers.sh" </dev/null 2>/dev/null)
case "$out" in
  *"ticket markers are moving to each working tree's git dir"*"still read and written"*"tickets/p1"*"AgDR-0222"*) ok "10b SessionStart prints the notice and the old file" ;;
  *) bad "10b" "$out" ;;
esac
hook "$SB" "$SB/workspace/p1/src/a.ts"
if [ "$RC" = 0 ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ]; then ok "11 a legacy pass is covered by one session notice"; else bad "11" "rc=$RC out=$out"; fi

# 11c. a new marker for the same tree shadows the old file, so the notice
# leaves it out. An old file for another tree is still listed.
printf 'repo=org/p1\nnumber=70\n' > "$SB/workspace/p1/.git/apexyard-ticket"
out=$(cd "$SB" && bash "$SB/.claude/hooks/warn-legacy-ticket-markers.sh" </dev/null 2>/dev/null)
if [ -z "$out" ]; then ok "11c a shadowed old file gives no notice"; else bad "11c" "$out"; fi
legacy "$SB/.claude/session/current-ticket" org/elsewhere 71
out=$(cd "$SB" && bash "$SB/.claude/hooks/warn-legacy-ticket-markers.sh" </dev/null 2>/dev/null)
case "$out" in
  *current-ticket*) case "$out" in *tickets/p1*) bad "11d" "$out" ;; *) ok "11d only the unshadowed old file is listed" ;; esac ;;
  *) bad "11d" "$out" ;;
esac
printf 'repo=org/elsewhere\nnumber=72\n' > "$SB/.git/apexyard-ticket"
git -C "$SB/workspace/p1" worktree add -q "$SB/workspace/p1/.wt/n" -b feature/n
rm -f "$SB/.claude/session/tickets/p1"
mkdir -p "$SB/.claude/session/tickets/p1"
legacy "$SB/.claude/session/tickets/p1/feature__n" org/p1 73
out=$(cd "$SB" && bash "$SB/.claude/hooks/warn-legacy-ticket-markers.sh" </dev/null 2>/dev/null)
case "$out" in *feature__n*) ok "11e an old per-branch file with no new marker in its worktree is listed" ;; *) bad "11e" "$out" ;; esac
printf 'repo=org/p1\nnumber=74\n' > "$(git -C "$SB/workspace/p1/.wt/n" rev-parse --absolute-git-dir)/apexyard-ticket"
out=$(cd "$SB" && bash "$SB/.claude/hooks/warn-legacy-ticket-markers.sh" </dev/null 2>/dev/null)
if [ -z "$out" ]; then ok "11f a new marker in that worktree shadows the per-branch file"; else bad "11f" "$out"; fi
rm -f "$SB/workspace/p1/.git/apexyard-ticket" "$SB/.git/apexyard-ticket" "$SB/.claude/session/current-ticket"
rm -rf "$SB/.claude/session/tickets/p1"
legacy "$SB/.claude/session/tickets/p1" org/p1 7

# 11b. the dispatcher prints the notice on stdout, end to end
dout=$(cd "$SB" && printf '{"hook_event_name":"SessionStart"}' | bash "$SB/.claude/hooks/dispatch-session-start.sh" 2>/dev/null)
case "$dout" in
  *"ticket markers are moving to each working tree's git dir"*"tickets/p1"*) ok "11b dispatch-session-start.sh prints the notice on stdout" ;;
  *) bad "11b" "stdout=[$dout]" ;;
esac
rm -rf "$SB"

# 12
SB=$(make_sb)
printf 'repo=org/p1\nnumber=99\n' > "$SB/workspace/p1/.git/apexyard-ticket"
mv "$SB/.git" "$SB/ops-dotgit"
ln -s "$SB/workspace/p1/.git" "$SB/.git"
hook "$SB" "$SB/workspace/p1/src/a.ts"
expect "12a an ops .git linked to p1's .git stops the new marker in p1 from counting" 2 "symlink in marker path"
legacy "$SB/.claude/session/tickets/p1" org/p1 7
hook "$SB" "$SB/workspace/p1/src/a.ts"
expect "12b the old resolution still decides there" 0
rm -f "$SB/.git"
mv "$SB/ops-dotgit" "$SB/.git"
rm -rf "$SB"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
