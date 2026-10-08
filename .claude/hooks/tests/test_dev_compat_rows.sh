#!/bin/bash
# Backward compatibility rows B1 to B9 of the ticket marker move (AgDR-0222).
#
# Each row is a real-session shape that the first version of the move broke.
# Every row runs against the current hooks and has a fixed expected verdict:
# the verdict that the old-layout hooks gave for the same shape. B8 and B9
# also check that the new /start-ticket writes the old-layout marker at the
# path and in the format that the old hooks read, so a rollback keeps the
# ticket.
#
#   B1 a clone at a registry workspace: path outside the workspace dir
#   B2 a linked worktree keeps its old per-branch marker
#   B3 an unregistered repo outside the ops fork
#   B4 a current-ticket that names a managed project, for an ops edit
#   B5 a nested repo, a submodule, a malformed .git file and a symlinked root
#   B6 a Bash write whose target cannot be extracted
#   B7 a fork without the portfolio library
#   B8 a marker written by the new /start-ticket, read by the old hooks
#   B9 a ticket that survives an update and a rollback of the hooks
#
# A repo owned by another user (part of B5) needs root to set up, so it is
# covered in-process by test_active_ticket_resolver.sh instead.

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
NEW_HOOKS="$SRC_ROOT/.claude/hooks"
NEW_DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"

export APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE CLAUDE_WORKTREE_BRANCH

PASS=0
FAIL=0
ok() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL + 1)); }

T=$(mktemp -d)
T=$(cd -P "$T" && pwd)
trap 'rm -rf "$T"' EXIT

mkrepo() {
  git init -q "$1"
  git -C "$1" commit -q --allow-empty -m init
}

# make_sb <name>: an ops fork with the current hooks, a registered clone
# workspace/p1 and a registered clone p5 at an absolute workspace: path
# outside the workspace dir. <name> names the sandbox dir. Prints the ops
# root.
make_sb() {
  local name="$1" ops hooks="$NEW_HOOKS" defaults="$NEW_DEFAULTS" f
  ops="$T/$name/ops"
  mkrepo "$ops"
  : > "$ops/.apexyard-fork"
  : > "$ops/onboarding.yaml"
  mkdir -p "$ops/.claude/hooks" "$ops/.claude/session" "$ops/workspace" "$T/$name/ext"
  for f in "$hooks"/*.sh; do cp "$f" "$ops/.claude/hooks/"; done
  chmod +x "$ops/.claude/hooks/"*.sh
  cp "$defaults" "$ops/.claude/project-config.defaults.json"
  printf 'projects:\n  - name: p1\n    repo: org/p1\n  - name: p5\n    repo: org/p5\n    workspace: %s\n' "$T/$name/ext/p5" > "$ops/apexyard.projects.yaml"
  mkrepo "$ops/workspace/p1"
  mkrepo "$T/$name/ext/p5"
  printf '%s' "$ops"
}

# gate <ops> <cwd> <payload>: runs the ticket gate of the sandbox, sets RC
# A real session has a session id, and its SessionStart hook pins the ops
# root, so a hook finds the ops root from any target. Each call models that
# with its own pin file in a temporary pin dir. The resolution cache stays
# off, as the session isolation helper sets it.
gate() {
  local ops="$1" cwd="$2" payload="$3"
  mkdir -p "$T/pins"
  printf '%s\n' "$ops" > "$T/pins/ops-root-compat-rows"
  ERR=$(cd "$cwd" && printf '%s' "$payload" \
    | CLAUDE_CODE_SESSION_ID=compat-rows APEXYARD_OPS_DISABLE_PIN='' APEXYARD_OPS_PIN_DIR="$T/pins" \
      bash "$ops/.claude/hooks/require-active-ticket.sh" 2>&1 >/dev/null)
  RC=$?
}
edit() { jq -nc --arg p "$1" '{tool_name:"Edit", tool_input:{file_path:$p}}'; }
bashc() { jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }
marker() { mkdir -p "${1%/*}"; printf 'repo=%s\nnumber=%s\ntitle=t\n' "$2" "$3" > "$1"; }
expect() {
  local name="$1" want="$2"
  if [ "$RC" = "$want" ]; then ok "$name"; else bad "$name" "want rc=$want got $RC (${ERR:0:${ROWS_ERR_LEN:-200}})"; fi
}

# old_format <file> <repo> <number>: the old-layout marker exists, is a
# regular file and has the keys the old /start-ticket wrote, in that order.
old_format() {
  local f="$1" keys
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  keys=$(sed -n 's/=.*//p' "$f" | tr '\n' ' ')
  [ "$keys" = "repo number title url suggested_branch started_at " ] || return 1
  grep -qx "repo=$2" "$f" && grep -qx "number=$3" "$f"
}
check_old() {
  if old_format "$2" "$3" "$4"; then ok "$1"; else bad "$1" "$2: $(cat "$2" 2>&1 | tr '\n' ' ')"; fi
}

# new_start_ticket <ops> <tree> <repo> <number>: what the new /start-ticket
# does, with the current library.
new_start_ticket() {
  local ops="$1" tree="$2" repo="$3" num="$4"
  printf 'repo=%s\nnumber=%s\ntitle=t\nurl=u\nsuggested_branch=b\n' "$repo" "$num" > "$ops/.claude/session/start-ticket-rows.pending"
  (cd "$ops" && bash -c '. "$1" && active_ticket_write_from_file "$2" "$3"' \
    _ "$NEW_HOOKS/_lib-active-ticket.sh" "$tree" "$ops/.claude/session/start-ticket-rows.pending") >/dev/null 2>&1
}

# B1
OPS=$(make_sb b1)
EXT="$T/b1/ext/p5"
marker "$OPS/.claude/session/current-ticket" org/p5 1
gate "$OPS" "$OPS" "$(edit "$EXT/src/a.ts")"
expect "B1 a workspace: clone outside the workspace dir uses current-ticket" 0
rm -f "$OPS/.claude/session/current-ticket"
marker "$OPS/.claude/session/tickets/p5" org/p5 1
gate "$OPS" "$OPS" "$(edit "$EXT/src/a.ts")"
expect "B1 tickets/p5 alone does not cover that clone" 2

# B2
OPS=$(make_sb b2)
git -C "$OPS/workspace/p1" worktree add -q "$OPS/workspace/p1/.wt/w2" -b feature/w2
marker "$OPS/.claude/session/tickets/p1/feature__w2" org/p1 2
gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/.wt/w2/src/a.ts")"
expect "B2 a linked worktree keeps its per-branch marker" 0
gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/src/a.ts")"
expect "B2 the per-branch marker does not cover the main clone" 2

# B3
OPS=$(make_sb b3)
OTHER="$T/b3/home/work/other"
mkrepo "$OTHER"
git -C "$OTHER" remote add origin https://example.test/org/other.git
marker "$OPS/.claude/session/current-ticket" org/other 3
gate "$OPS" "$OPS" "$(edit "$OTHER/src/a.ts")"
expect "B3 an unregistered repo outside the fork uses current-ticket" 0
rm -f "$OPS/.claude/session/current-ticket"
gate "$OPS" "$OPS" "$(edit "$OTHER/src/a.ts")"
expect "B3 without current-ticket it is blocked" 2

# B4
OPS=$(make_sb b4)
marker "$OPS/.claude/session/current-ticket" org/p1 4
gate "$OPS" "$OPS" "$(edit "$OPS/src/a.ts")"
expect "B4 a current-ticket naming a managed project passes an ops edit" 0

# B5
OPS=$(make_sb b5)
marker "$OPS/.claude/session/current-ticket" org/ops 5
mkrepo "$OPS/vendor/nested"
gate "$OPS" "$OPS" "$(edit "$OPS/vendor/nested/a.ts")"
expect "B5 a nested repo in the fork uses current-ticket" 0
mkdir -p "$OPS/broken"
printf 'not a gitdir line\n' > "$OPS/broken/.git"
gate "$OPS" "$OPS" "$(edit "$OPS/broken/a.ts")"
expect "B5 a malformed .git file uses current-ticket" 0
mkrepo "$T/b5/subsrc"
git -C "$OPS" -c protocol.file.allow=always submodule add -q "$T/b5/subsrc" sub >/dev/null 2>&1
if [ -e "$OPS/sub/.git" ]; then
  gate "$OPS" "$OPS" "$(edit "$OPS/sub/a.ts")"
  expect "B5 a submodule uses current-ticket" 0
else
  echo "INFO: git submodule add failed here, so the submodule case did not run"
fi
mkrepo "$T/b5/real-p1"
rm -rf "$OPS/workspace/p1"
ln -s "$T/b5/real-p1" "$OPS/workspace/p1"
gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/src/a.ts")"
expect "B5 a symlinked clone root uses current-ticket" 0

# B6
OPS=$(make_sb b6)
marker "$OPS/.claude/session/current-ticket" org/p1 6
gate "$OPS" "$OPS/workspace/p1" "$(bashc 'sed -i "s/x/y/" "$VAR"')"
expect "B6 an unextractable Bash target in a clone uses current-ticket" 0
rm -f "$OPS/.claude/session/current-ticket"
gate "$OPS" "$OPS/workspace/p1" "$(bashc 'sed -i "s/x/y/" "$VAR"')"
expect "B6 without current-ticket it is blocked" 2

# B7
OPS=$(make_sb b7)
rm -f "$OPS/.claude/hooks/_lib-portfolio-paths.sh"
marker "$OPS/.claude/session/tickets/p1" org/p1 7
gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/src/a.ts")"
expect "B7 without the portfolio library tickets/p1 still counts" 0

# B8
OPS=$(make_sb b8)
new_start_ticket "$OPS" "$OPS/workspace/p1" org/p1 8
gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/src/a.ts")"
expect "B8 the new /start-ticket covers a main clone" 0
check_old "B8 the old-layout marker for a main clone is tickets/p1" "$OPS/.claude/session/tickets/p1" org/p1 8
git -C "$OPS/workspace/p1" worktree add -q "$OPS/workspace/p1/.wt/w8" -b feature/w8
# The old layout keeps per-branch markers in a tickets/p1 directory, so the
# single-agent tickets/p1 file goes first, as the old /start-ticket told users.
rm -f "$OPS/.claude/session/tickets/p1"
new_start_ticket "$OPS" "$OPS/workspace/p1/.wt/w8" org/p1 81
gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/.wt/w8/src/a.ts")"
expect "B8 the new /start-ticket covers a linked worktree" 0
check_old "B8 the old-layout marker for a linked worktree is tickets/p1/<branch>" "$OPS/.claude/session/tickets/p1/feature__w8" org/p1 81
new_start_ticket "$OPS" "$OPS" org/ops 82
gate "$OPS" "$OPS" "$(edit "$OPS/src/a.ts")"
expect "B8 the new /start-ticket covers an ops edit" 0
check_old "B8 the old-layout marker for an ops edit is current-ticket" "$OPS/.claude/session/current-ticket" org/ops 82

# P1: a project ticket aimed at a clone path that does not exist. The
# writer must not walk up and put it into the ops fork's git dir.
OPS=$(make_sb p1)
new_start_ticket "$OPS" "$OPS/workspace/p5" org/p5 91
gate "$OPS" "$OPS" "$(edit "$OPS/bin/tool.sh")"
expect "P1 a project ticket for a missing clone does not cover an ops edit" 2

# P2: a ticket for one project started from another project's clone.
OPS=$(make_sb p2)
new_start_ticket "$OPS" "$OPS/workspace/p1" org/p5 92
gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/src/a.ts")"
expect "P2 another project's ticket does not cover the clone it was started from" 2
# The same, planted by hand or by an older writer, is not trusted either.
printf 'repo=org/p5\nnumber=93\n' > "$OPS/workspace/p1/.git/apexyard-ticket"
gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/src/a.ts")"
expect "P2 a planted marker for another project is not trusted" 2

# B9: one sandbox, a ticket carried across an update and a rollback.
OPS=$(make_sb new b9)
marker "$OPS/.claude/session/tickets/p1" org/p1 9
gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/src/a.ts")"
expect "B9 a ticket started under the old layout passes after the update" 0
rm -f "$OPS/.claude/session/tickets/p1"
new_start_ticket "$OPS" "$OPS/workspace/p1" org/p1 91
check_old "B9 a ticket started under the new hooks also has its old-layout marker" "$OPS/.claude/session/tickets/p1" org/p1 91
# A rollback leaves only the old-layout marker readable. Model it by removing
# the new marker: the old-layout marker alone must still pass.
rm -f "$OPS/workspace/p1/.git/apexyard-ticket"
gate "$OPS" "$OPS" "$(edit "$OPS/workspace/p1/src/a.ts")"
expect "B9 the old-layout marker alone carries the ticket after a rollback" 0

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
