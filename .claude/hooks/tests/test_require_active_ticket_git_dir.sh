#!/bin/bash
# Gate behaviour with the ticket marker in each working tree's git dir
# (AgDR-0222). Each case builds an ops fork sandbox that holds the real hook
# and its libraries, a registered clone workspace/p1 and a linked worktree of
# it, then pipes a synthetic PreToolUse payload to require-active-ticket.sh.
#
# Cases:
#   1  writes into .git other than the marker are blocked
#   2  the marker and its temporary file can be written with no ticket
#   2d a hard-linked marker is blocked; a single link and a missing file stay exempt
#   3  the marker exemption does not cover a second, ordinary target
#   4  a planted nested .git is blocked even with an ops marker
#   5  GIT_DIR and GIT_WORK_TREE in the hook environment change nothing
#   6  an unextractable Bash write honours the marker of the working directory
#   7  both gates return the same verdict for the same path
#   8  an exempt path starts no validation
#   9  a Bash command with several targets in one tree validates once

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

# make_sb: ops fork with the hook, p1 (registered), and a linked worktree wt1.
make_sb() {
  local sb
  sb=$(mktemp -d)
  sb=$(cd -P "$sb" && pwd)
  mkrepo "$sb"
  : > "$sb/.apexyard-fork"
  : > "$sb/onboarding.yaml"
  printf 'projects:\n  - name: p1\n    repo: org/p1\n' > "$sb/apexyard.projects.yaml"
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session" "$sb/workspace"
  local f
  for f in require-active-ticket.sh require-migration-ticket.sh _lib-awk-fallback.sh _lib-detect-bash-write.sh _lib-read-config.sh \
           _lib-path-resolve.sh _lib-active-ticket.sh _lib-mask-quoted.sh _lib-ticket-path-exemptions.sh _lib-portfolio-paths.sh \
           _lib-ops-root.sh _lib-resolution-cache.sh _lib-tracker.sh; do
    cp "$HOOKS/$f" "$sb/.claude/hooks/$f"
  done
  cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  chmod +x "$sb/.claude/hooks/"*.sh
  mkrepo "$sb/workspace/p1"
  git -C "$sb/workspace/p1" worktree add -q "$sb/wt1" -b wt1
  echo "$sb"
}

gdir() { git -C "$1" rev-parse --absolute-git-dir; }
put_marker() { printf 'repo=org/p1\nnumber=1\n' > "$(gdir "$1")/apexyard-ticket"; }
put_ops_marker() { printf 'repo=org/ops\nnumber=2\n' > "$(gdir "$1")/apexyard-ticket"; }

# hook <sb> <json> [cwd] -> sets RC and ERR
hook() {
  local sb="$1" in="$2" cwd="${3:-$1}"
  ERR=$(cd "$cwd" && printf '%s' "$in" | bash "$sb/.claude/hooks/require-active-ticket.sh" 2>&1 >/dev/null)
  RC=$?
}
edit_json() { jq -nc --arg p "$1" '{tool_name:"Edit", tool_input:{file_path:$p}}'; }
bash_json() { jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

expect() {
  local name="$1" want="$2" rx="${3:-}"
  if [ "$RC" != "$want" ]; then bad "$name" "want rc=$want got $RC (${ERR:0:300})"; return; fi
  if [ -n "$rx" ] && ! printf '%s' "$ERR" | grep -Eq "$rx"; then bad "$name" "stderr did not match /$rx/: ${ERR:0:300}"; return; fi
  ok "$name"
}

# --- 1. .git writes other than the marker are blocked ---------------------
SB=$(make_sb)
G="$(gdir "$SB/workspace/p1")"
hook "$SB" "$(bash_json "echo x > $G/hooks/pre-commit")";  expect "1a Bash write to .git/hooks/pre-commit is blocked" 2 BLOCKED
hook "$SB" "$(bash_json "echo x > $G/config")";            expect "1b Bash write to .git/config is blocked" 2 BLOCKED
mkdir -p "$SB/workspace/p1/src/x/.git"
hook "$SB" "$(bash_json "echo x > $SB/workspace/p1/src/x/.git/apexyard-ticket")"; expect "1c Bash write to src/x/.git/apexyard-ticket is blocked" 2 BLOCKED
hook "$SB" "$(bash_json "echo x > $G/apexyard-ticket.bak")"; expect "1d Bash write to apexyard-ticket.bak is blocked" 2 BLOCKED
rm -rf "$SB"

# --- 2. the marker and its temporary file need no ticket ------------------
SB=$(make_sb)
for tree in "$SB/workspace/p1" "$SB/wt1"; do
  G="$(gdir "$tree")"
  label="${tree#"$SB"/}"
  hook "$SB" "$(bash_json "printf x > $G/apexyard-ticket")"; expect "2a ($label) write of the marker is allowed with no ticket" 0
  hook "$SB" "$(bash_json "printf x > $G/apexyard-ticket.tmp.Ab3dE9")"; expect "2b ($label) write of the temporary marker is allowed" 0
  hook "$SB" "$(bash_json "mv $G/apexyard-ticket.tmp.Ab3dE9 $G/apexyard-ticket")"; expect "2c ($label) mv of the temporary file onto the marker is allowed" 0
done
rm -rf "$SB"

# --- 2d. a hard link is not exempt; one link and a missing file are -------
# ln is not a write. Linking .git/config onto the marker name must not let a
# later write through that name pass with no ticket.
SB=$(make_sb)
G="$(gdir "$SB/workspace/p1")"
ln "$G/config" "$G/apexyard-ticket"
hook "$SB" "$(bash_json "printf x > $G/apexyard-ticket")"
expect "2f a hard-linked marker is blocked with no ticket" 2 BLOCKED
rm -f "$G/apexyard-ticket"
printf 'repo=org/p1\nnumber=1\n' > "$G/apexyard-ticket"
hook "$SB" "$(bash_json "printf x > $G/apexyard-ticket")"
expect "2d an existing single-link marker is allowed with no ticket" 0
rm -f "$G/apexyard-ticket"
hook "$SB" "$(bash_json "printf x > $G/apexyard-ticket")"
expect "2e a marker that does not exist yet is allowed" 0
ln "$G/config" "$G/apexyard-ticket.tmp.Ab3dE9"
hook "$SB" "$(bash_json "printf x > $G/apexyard-ticket.tmp.Ab3dE9")"
expect "2g a hard-linked temporary marker is blocked with no ticket" 2 BLOCKED
rm -rf "$SB"

# --- 2h. refused links cannot use an active ticket ------------------------
SB=$(make_sb)
G="$(gdir "$SB/workspace/p1")"
put_marker "$SB/workspace/p1"
mkdir -p "$SB/.claude/session/tickets"
mv "$G/apexyard-ticket" "$SB/.claude/session/tickets/p1"
hook "$SB" "$(edit_json "$SB/workspace/p1/src/a.ts")"
expect "2h the old-layout ticket covers p1" 0
for name in apexyard-ticket apexyard-ticket.tmp.Ab3dE9; do
  ln "$G/config" "$G/$name"
  hook "$SB" "$(bash_json "printf x > $G/$name")"
  expect "2i ($name) a hard link is blocked with an active ticket" 2 "more than one hard link"
  rm -f "$G/$name"
  rm -f "$SB/.claude/session/tickets/p1"
  put_marker "$SB/workspace/p1"
  hook "$SB" "$(edit_json "$SB/workspace/p1/src/a.ts")"
  expect "2j ($name) the new-layout ticket covers p1" 0
  if [ "$name" = apexyard-ticket ]; then
    mv "$G/apexyard-ticket" "$SB/ticket"
    ln -s "$SB/ticket" "$G/$name"
  else
    ln -s "$G/config" "$G/$name"
  fi
  hook "$SB" "$(bash_json "printf x > $G/$name")"
  expect "2j ($name) a symlink is blocked with an active ticket" 2 BLOCKED
  rm -f "$G/$name"
  put_marker "$SB/workspace/p1"
  mv "$G/apexyard-ticket" "$SB/.claude/session/tickets/p1"
done
rm -rf "$SB"

# --- 3. one exempt target does not exempt another -------------------------
SB=$(make_sb)
G="$(gdir "$SB/workspace/p1")"
hook "$SB" "$(bash_json "printf x > $G/apexyard-ticket; echo y > $SB/workspace/p1/src/a.ts")"
expect "3 the marker exemption does not cover src/a.ts" 2 BLOCKED
hook "$SB" "$(bash_json "mv $G/apexyard-ticket.tmp.Ab3dE9 $SB/workspace/p1/src/a.ts")"
expect "3b mv of a temporary marker onto a source file is blocked" 2 BLOCKED
rm -rf "$SB"

# --- 4. a planted nested .git is blocked even with an ops marker ----------
SB=$(make_sb)
put_ops_marker "$SB"
mkdir -p "$SB/workspace/p1/src/sub" "$SB/forged/objects" "$SB/forged/refs"
: > "$SB/forged/HEAD"
printf 'gitdir: %s\n' "$SB/forged" > "$SB/workspace/p1/src/sub/.git"
hook "$SB" "$(edit_json "$SB/workspace/p1/src/sub/a.ts")"
expect "4 planted src/sub/.git is blocked" 2 BLOCKED
put_marker "$SB/workspace/p1"
hook "$SB" "$(edit_json "$SB/workspace/p1/src/sub/a.ts")"
expect "4b planted src/sub/.git is blocked even with a p1 marker" 2 BLOCKED
rm -rf "$SB"

# --- 4c. a symlink before .. cannot lend p1's marker to another path -------
SB=$(make_sb)
put_marker "$SB/workspace/p1"
mkdir -p "$SB/elsewhere/src" "$SB/workspace/p1/src"
ln -s "$SB/elsewhere/src" "$SB/workspace/p1/lnk"
hook "$SB" "$(edit_json "$SB/workspace/p1/lnk/../a.ts")"
expect "4c a symlink before .. is refused" 2 "symlink in marker path"
hook "$SB" "$(edit_json "$SB/workspace/p1/src/../a.ts")"
expect "4d the same path through a real directory passes" 0
rm -rf "$SB"

# --- 5. GIT_* in the hook environment change nothing ----------------------
SB=$(make_sb)
put_marker "$SB/workspace/p1"
ERR=$(cd "$SB" && printf '%s' "$(edit_json "$SB/workspace/p1/src/a.ts")" | GIT_DIR="$SB/.git" GIT_WORK_TREE="$SB" \
  bash "$SB/.claude/hooks/require-active-ticket.sh" 2>&1 >/dev/null)
RC=$?
expect "5a GIT_DIR and GIT_WORK_TREE do not redirect a tree that has a marker" 0
ERR=$(cd "$SB" && printf '%s' "$(edit_json "$SB/wt1/src/a.ts")" | GIT_DIR="$SB/workspace/p1/.git" GIT_WORK_TREE="$SB/workspace/p1" \
  bash "$SB/.claude/hooks/require-active-ticket.sh" 2>&1 >/dev/null)
RC=$?
expect "5b the same variables do not lend p1's marker to the worktree" 2 BLOCKED
rm -rf "$SB"

# --- 6. unextractable target honours the working directory's marker -------
UNEXTRACTABLE='python3 -c "import os; open(os.environ[\"T\"], \"w\").write(\"x\")"'
SB=$(make_sb)
put_ops_marker "$SB"
hook "$SB" "$(bash_json "$UNEXTRACTABLE")" "$SB"
expect "6a unextractable write from the ops fork with an ops marker passes" 0
rm -f "$SB/.git/apexyard-ticket"
hook "$SB" "$(bash_json "$UNEXTRACTABLE")" "$SB"
expect "6b the same write with no marker is blocked" 2 BLOCKED
if printf '%s' "$ERR" | grep -q "Prefer an absolute target path"; then ok "6b2 the block message gives the absolute-path hint"; else bad "6b2" "$ERR"; fi
put_ops_marker "$SB"
hook "$SB" "$(bash_json "$UNEXTRACTABLE")" "$SB/workspace/p1"
expect "6c the marker of the ops fork does not cover a write run from p1" 2 BLOCKED
rm -rf "$SB"

# --- 7. both gates agree ---------------------------------------------------
SB=$(make_sb)
cat > "$SB/.claude/project-config.json" <<'JSON'
{ "tracker": { "kind": "none" } }
JSON
put_marker "$SB/workspace/p1"
put_ops_marker "$SB"
mkdir -p "$SB/old/session"
mkdir -p "$SB/.claude/session/tickets"
printf 'repo=org/p1\nnumber=9\n' > "$SB/.claude/session/tickets/p1"
rm -f "$(gdir "$SB/workspace/p1")/apexyard-ticket"
parity() {
  local label="$1" path="$2" want="$3" r1 r2
  hook "$SB" "$(edit_json "$path")"
  r1=$RC
  ERR=$(cd "$SB" && printf '%s' "$(edit_json "$path")" | bash "$SB/.claude/hooks/require-migration-ticket.sh" 2>&1 >/dev/null)
  r2=$?
  if [ "$r1" = "$want" ] && [ "$r2" = "$want" ]; then ok "7 parity ($label): both gates return $want"; else bad "7 parity ($label)" "ticket gate $r1, migration gate $r2, want $want"; fi
}
parity "ops fork with its own marker" "$SB/db/migrations/001.sql" 0
parity "p1 main clone through the legacy rule" "$SB/workspace/p1/db/migrations/001.sql" 0
parity "p1 worktree with no marker" "$SB/wt1/db/migrations/001.sql" 2
put_marker "$SB/wt1"
parity "p1 worktree with its own marker" "$SB/wt1/db/migrations/001.sql" 0
mkrepo "$SB/rogue"
parity "unregistered nested repo" "$SB/rogue/db/migrations/001.sql" 2
rm -rf "$SB"

# --- 8 and 9. validation counts -------------------------------------------
# The sandbox library prints the validation count when the hook process exits.
count_sb() {
  local sb
  sb=$(make_sb)
  put_marker "$sb/workspace/p1"
  printf '\ntrap '"'"'printf "%%s" "${AT_VALIDATIONS:-0}" > "${AT_COUNT_FILE:-/dev/null}"'"'"' EXIT\n' >> "$sb/.claude/hooks/_lib-active-ticket.sh"
  echo "$sb"
}
SB=$(count_sb)
CF="$SB/count"
ERR=$(cd "$SB" && printf '%s' "$(edit_json "$SB/workspace/p1/README.md")" | AT_COUNT_FILE="$CF" bash "$SB/.claude/hooks/require-active-ticket.sh" 2>&1 >/dev/null)
RC=$?
if [ "$RC" = 0 ] && [ ! -s "$CF" ]; then ok "8a an exempt path starts no validation"; else bad "8a" "rc=$RC count=$(cat "$CF" 2>/dev/null)"; fi
ERR=$(cd "$SB" && printf '%s' "$(edit_json "$SB/workspace/p1/src/a.ts")" | AT_COUNT_FILE="$CF" bash "$SB/.claude/hooks/require-active-ticket.sh" 2>&1 >/dev/null)
RC=$?
if [ "$RC" = 0 ] && [ "$(cat "$CF" 2>/dev/null)" = 1 ]; then ok "8b a gated path validates once"; else bad "8b" "rc=$RC count=$(cat "$CF" 2>/dev/null)"; fi
mkdir -p "$SB/workspace/p1/src" "$SB/workspace/p1/lib"
cmd="cat a > $SB/workspace/p1/src/a.ts; cat b > $SB/workspace/p1/src/b.ts; cat c > $SB/workspace/p1/lib/c.ts"
ERR=$(cd "$SB" && printf '%s' "$(bash_json "$cmd")" | AT_COUNT_FILE="$CF" bash "$SB/.claude/hooks/require-active-ticket.sh" 2>&1 >/dev/null)
RC=$?
if [ "$RC" = 0 ] && [ "$(cat "$CF" 2>/dev/null)" = 1 ]; then ok "9 three targets in two directories of one tree validate once"; else bad "9" "rc=$RC count=$(cat "$CF" 2>/dev/null) ${ERR:0:200}"; fi
rm -rf "$SB"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
