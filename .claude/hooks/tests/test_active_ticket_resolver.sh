#!/bin/bash
# Tests for the git-dir ticket marker resolver in _lib-active-ticket.sh.
#
# Every case builds on a fixture: an ops fork, a registry, a registered clone
# workspace/p1 and a linked worktree of p1. The resolver runs in this shell, so
# the cases read REPLY, AT_REASON and AT_GITDIR directly.
#
# On the commit before the resolver, none of the functions exist and every
# case fails.

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$SRC_ROOT/.claude/hooks/_lib-active-ticket.sh"

export APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

PASS=0
FAIL=0
ok() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL + 1)); }

if [ ! -f "$LIB" ]; then
  echo "FAIL: $LIB is missing" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$LIB"
if ! command -v active_ticket_gitdir >/dev/null 2>&1; then
  bad "resolver functions exist" "active_ticket_gitdir is not defined"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

B=$(mktemp -d)
B=$(cd -P "$B" && pwd)
trap 'rm -rf "$B"' EXIT

mkrepo() {
  git init -q -b main "$1" 2>/dev/null || git init -q "$1"
  git -C "$1" commit -q --allow-empty -m init
}

write_registry() {
  # $1 = file, rest = extra raw lines appended after the p1 entry
  local f="$1"
  shift
  {
    printf 'version: 1\nprojects:\n  - name: p1\n    repo: org/p1\n    status: active\n'
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
    printf 'defaults:\n  status: active\n'
  } > "$f"
}

OPS="$B/ops"
WS="$OPS/workspace"
mkrepo "$OPS"
: > "$OPS/.apexyard-fork"
: > "$OPS/onboarding.yaml"
write_registry "$OPS/apexyard.projects.yaml"
mkdir -p "$WS"
mkrepo "$WS/p1"
WT="$B/wt1"
git -C "$WS/p1" worktree add -q "$WT" -b wt1
P1G="$WS/p1/.git"
WTG="$P1G/worktrees/wt1"

ctx() {
  active_ticket_set_context "$OPS" "$WS"
  _AT_REG="$OPS/apexyard.projects.yaml"
  _at_memo_clear
}
ctx

# gd <path>: sets G and R (rc) from the lookup of the git dir
gd() {
  _at_memo_clear
  active_ticket_gitdir "$1"
  R=$?
  G="$REPLY"
}
expect_gd() {
  local name="$1" path="$2" want="$3"
  gd "$path"
  if [ "$R" = 0 ] && [ "$G" = "$want" ]; then ok "$name"; else bad "$name" "rc=$R G=$G want=$want reason=$AT_REASON"; fi
}
expect_refuse() {
  local name="$1" path="$2" rx="$3"
  gd "$path"
  if [ "$R" != 0 ] && [ -z "$G" ] && printf '%s' "$AT_REASON" | grep -Eq "$rx"; then ok "$name"; else bad "$name" "rc=$R G=$G reason=[$AT_REASON] want /$rx/"; fi
}

# 1. main clone
expect_gd "1 main clone resolves to its own .git" "$WS/p1/src/a.ts" "$P1G"

# 2. linked worktree, and the main clone's marker is not visible from it
printf 'repo=org/p1\nnumber=1\n' > "$P1G/apexyard-ticket"
expect_gd "2 linked worktree resolves to its own git dir" "$WT/src/a.ts" "$WTG"
_at_memo_clear
active_ticket_lookup "$WT/src/a.ts"
if [ "$?" != 0 ] && [ -z "$REPLY" ] && [ -z "$AT_REASON" ]; then ok "2b main marker is not visible from the worktree"; else bad "2b" "REPLY=$REPLY reason=$AT_REASON"; fi
_at_memo_clear
active_ticket_lookup "$WS/p1/src/a.ts"
if [ "$?" = 0 ] && [ "$REPLY" = "$P1G/apexyard-ticket" ]; then ok "2c main marker is found in the main clone"; else bad "2c" "REPLY=$REPLY"; fi
rm -f "$P1G/apexyard-ticket"

# 3. planted src/sub/.git
mkdir -p "$WS/p1/src/sub" "$B/forged/objects" "$B/forged/refs"
: > "$B/forged/HEAD"
printf 'gitdir: %s\n' "$B/forged" > "$WS/p1/src/sub/.git"
expect_refuse "3a planted gitdir to a forged dir" "$WS/p1/src/sub/x.ts" "unregistered|not listed"
printf '%s\n' "$P1G" > "$B/forged/commondir"
expect_refuse "3b planted gitdir with a forged commondir" "$WS/p1/src/sub/x.ts" "not listed|unregistered"
printf 'gitdir: %s\n' "$WTG" > "$WS/p1/src/sub/.git"
expect_refuse "3c planted gitdir pointing at a real worktree git dir" "$WS/p1/src/sub/x.ts" "not listed"
rm -rf "$WS/p1/src/sub" "$B/forged"

# 4. unregistered clone under workspace
mkrepo "$WS/rogue"
expect_refuse "4 unregistered workspace clone" "$WS/rogue/a.ts" "unregistered common dir"

# 5. hostile registry names
write_registry "$OPS/apexyard.projects.yaml" '  - name: ../x' '    repo: org/x' '  - name: /tmp/x' '    repo: org/y' '  - name: ..' '    repo: org/z'
expect_refuse "5a registry names with dots and slashes never match" "$WS/rogue/a.ts" "unregistered common dir"
write_registry "$OPS/apexyard.projects.yaml"

# 6. git environment and config cannot redirect the lookup
git -C "$WS/p1" config core.worktree /tmp
GIT_DIR=/nonexistent GIT_WORK_TREE=/nonexistent GIT_COMMON_DIR=/nonexistent GIT_CONFIG_GLOBAL=/nonexistent \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.worktree GIT_CONFIG_VALUE_0=/tmp \
  expect_gd "6 GIT_* variables and core.worktree change nothing" "$WS/p1/src/a.ts" "$P1G"
git -C "$WS/p1" config --unset core.worktree

# 7. relative back-pointers
printf '../../../../../../wt1/.git\n' > "$WTG/gitdir"
printf 'gitdir: ../ops/workspace/p1/.git/worktrees/wt1\n' > "$WT/.git"
printf '../..\n' > "$WTG/commondir"
expect_gd "7 relative back-pointers resolve" "$WT/src/a.ts" "$WTG"
printf '%s\n' "$WT/.git" > "$WTG/gitdir"
printf 'gitdir: %s\n' "$WTG" > "$WT/.git"
printf '%s\n' "$P1G" > "$WTG/commondir"

# 23. absolute back-pointers (the form git writes)
expect_gd "23 absolute back-pointers resolve" "$WT/src/a.ts" "$WTG"

# 8. links
printf 'x\n' > "$B/target-file"
ln -s "$B/target-file" "$P1G/apexyard-ticket"
expect_refuse "8a symlinked marker" "$WS/p1/a.ts" "symlink in marker path"
rm -f "$P1G/apexyard-ticket"
ln -s "$B/target-file" "$P1G/apexyard-ticket.tmp.Ab3dE9"
expect_refuse "8b symlinked temporary marker" "$WS/p1/a.ts" "symlink in marker path"
rm -f "$P1G/apexyard-ticket.tmp.Ab3dE9"
mv "$WS/p1" "$B/p1-real"
ln -s "$B/p1-real" "$WS/p1"
expect_refuse "8c symlinked workspace entry" "$WS/p1/a.ts" "symlink in marker path"
rm -f "$WS/p1"
mv "$B/p1-real" "$WS/p1"
mv "$WS/p1/.git" "$B/p1-dotgit"
ln -s "$B/p1-dotgit" "$WS/p1/.git"
expect_refuse "8d symlinked .git" "$WS/p1/a.ts" "symlink in marker path"
rm -f "$WS/p1/.git"
mv "$B/p1-dotgit" "$WS/p1/.git"
ln -s "$B/dangling-nowhere" "$WS/p1/src-dangling.git"
mkdir -p "$WS/p1/dang"
ln -s "$B/dangling-nowhere" "$WS/p1/dang/.git"
expect_refuse "8e dangling .git link" "$WS/p1/dang/a.ts" "symlink in marker path"
rm -rf "$WS/p1/dang" "$WS/p1/src-dangling.git"
mv "$WTG" "$B/wtg-real"
ln -s "$B/wtg-real" "$WTG"
expect_refuse "8f symlinked worktree git dir" "$WT/a.ts" "symlink in marker path|not listed|not a git tree"
rm -f "$WTG"
mv "$B/wtg-real" "$WTG"
mv "$WS" "$B/ws-real"
ln -s "$B/ws-real" "$WS"
expect_refuse "8g symlinked workspace root" "$B/ws-real/p1/a.ts" "symlink in marker path|unregistered"
rm -f "$WS"
mv "$B/ws-real" "$WS"

# 9. a link inside the tree
mkdir -p "$WS/p1/src"
ln -s "$WS/p1/src" "$WS/p1/srclink"
expect_refuse "9 link inside the tree" "$WS/p1/srclink/app.ts" "symlink in marker path"
rm -f "$WS/p1/srclink"

# 10. submodule
mkdir -p "$WS/p1/sub" "$P1G/modules/sub/objects" "$P1G/modules/sub/refs"
: > "$P1G/modules/sub/HEAD"
printf 'gitdir: %s\n' "$P1G/modules/sub" > "$WS/p1/sub/.git"
expect_refuse "10 submodule is not a tree" "$WS/p1/sub/a.ts" "unregistered|not listed"
rm -rf "$WS/p1/sub" "$P1G/modules"

# 11. ownership
_at_owned() { return 1; }
expect_refuse "11 not owned by the current user" "$WS/p1/a.ts" "not owned by current user"
if printf '%s' "$AT_REASON" | grep -q "safe.directory"; then ok "11b the message names the fix"; else bad "11b" "$AT_REASON"; fi
_at_owned() { [ -O "$1" ]; }

# 12. missing HEAD or objects
mv "$P1G/HEAD" "$P1G/HEAD.bak"
expect_refuse "12a git dir without HEAD" "$WS/p1/a.ts" "not a git tree"
mv "$P1G/HEAD.bak" "$P1G/HEAD"
mv "$P1G/objects" "$P1G/objects.bak"
expect_refuse "12b common dir without objects" "$WS/p1/a.ts" "not a git tree"
mv "$P1G/objects.bak" "$P1G/objects"

# 13. marker targets
_at_memo_clear
mt() {
  active_ticket_is_marker_target "$1"
}
mt "$P1G/apexyard-ticket" && ok "13a main marker is a target" || bad "13a" ""
mt "$WTG/apexyard-ticket" && ok "13b worktree marker is a target" || bad "13b" ""
mt "$P1G/apexyard-ticket.tmp.Ab3dE9" && ok "13c temporary marker is a target" || bad "13c" ""
mt "$P1G/hooks/pre-commit" && bad "13d hooks file" "accepted" || ok "13d .git/hooks/pre-commit is not a target"
mt "$P1G/config" && bad "13e" "accepted" || ok "13e .git/config is not a target"
mkdir -p "$WS/p1/src/x/.git"
mt "$WS/p1/src/x/.git/apexyard-ticket" && bad "13f" "accepted" || ok "13f nested .git marker is not a target"
rm -rf "$WS/p1/src/x"
mt "$P1G/apexyard-ticket.bak" && bad "13g" "accepted" || ok "13g .bak is not a target"
mt "$P1G/apexyard-ticket.tmp.12345" && bad "13h" "accepted" || ok "13h short tmp suffix is not a target"
mkdir -p "$B/rogue2/.git/objects" "$B/rogue2/.git/refs"
: > "$B/rogue2/.git/HEAD"
mt "$B/rogue2/.git/apexyard-ticket" && bad "13i" "accepted" || ok "13i marker path in an unregistered repo is not a target"
mt "$WS/p1/src/apexyard-ticket" && bad "13j" "accepted" || ok "13j marker name outside .git is not a target"

# 14. writer refuses a planted link and writes nothing outside the git dir
printf 'untouched\n' > "$B/victim"
ln -s "$B/victim" "$P1G/apexyard-ticket"
( active_ticket_write "$WS/p1" org/p1 1 t u b ) 2> "$B/w14.err"
rc=$?
if [ "$rc" != 0 ] && [ "$(cat "$B/victim")" = untouched ]; then ok "14 writer refuses a planted link"; else bad "14" "rc=$rc"; fi
rm -f "$P1G/apexyard-ticket"

# 15. git worktree remove deletes the marker
( _at_memo_clear; active_ticket_write "$WT" org/p1 7 "wt ticket" "http://x" "feature/x" ) 2> "$B/w15.err"
if [ -f "$WTG/apexyard-ticket" ]; then ok "15a writer wrote the worktree marker"; else bad "15a" "$(cat "$B/w15.err")"; fi
git -C "$WS/p1" worktree remove --force "$WT" 2>/dev/null
if [ ! -e "$WTG/apexyard-ticket" ]; then ok "15b git worktree remove deleted the marker"; else bad "15b" "marker survived"; fi
git -C "$WS/p1" worktree add -q "$WT" -b wt1b

# 16. ~user is refused
_at_memo_clear
active_ticket_lookup '~nobody/x'
if [ "$?" != 0 ] && [ -z "$REPLY" ]; then ok "16 ~user target gives an empty reply"; else bad "16" "REPLY=$REPLY"; fi
WTG="$P1G/worktrees/wt1b"

# 17. missing context
active_ticket_set_context "" ""
_at_memo_clear
active_ticket_lookup "$WS/p1/a.ts"
if [ "$?" != 0 ] && [ -z "$REPLY" ] && [ "$AT_REASON" = "resolver context missing" ]; then ok "17 missing context is refused"; else bad "17" "reason=$AT_REASON"; fi
ctx

# 18. registry formats
check_registry() {
  local name="$1"
  shift
  printf '%s\n' "$@" > "$OPS/apexyard.projects.yaml"
  _at_memo_clear
  active_ticket_gitdir "$WS/p1/a.ts"
  if [ "$?" = 0 ] && [ "$REPLY" = "$P1G" ]; then ok "$name"; else bad "$name" "reason=$AT_REASON"; fi
}
check_registry "18a quoted names" 'projects:' '  - name: "p1"' '    repo: "org/p1"'
check_registry "18b single quotes and a comment" 'projects:' "  - name: 'p1'   # main" "    repo: 'org/p1'"
check_registry "18c extra indentation" 'projects:' '      -   name: p1' '          repo: org/p1'
check_registry "18d CRLF line endings" $'projects:\r' $'  - name: p1\r' $'    repo: org/p1\r'
check_registry "18e entry without a dash indent" 'projects:' '- name: p1' '  repo: org/p1'
check_registry "18f repo before name" 'projects:' '  - repo: org/p1' '    name: p1'
printf 'projects:\n  - name: other\n    meta:\n      name: p1\n    repo: org/o\n' > "$OPS/apexyard.projects.yaml"
_at_memo_clear
active_ticket_gitdir "$WS/p1/a.ts"
if [ "$?" != 0 ]; then ok "18g a nested name: key does not register p1"; else bad "18g" "accepted"; fi
printf 'projects:\n  - name: p1x\n    repo: org/p1x\n    sub:\n      repo: org/p1\n' > "$OPS/apexyard.projects.yaml"
_at_memo_clear
_at_reg_scan p1x
if [ "$AT_REG_REPO" = "org/p1x" ]; then ok "18h a nested repo: key does not replace the entry repo"; else bad "18h" "repo=$AT_REG_REPO"; fi
write_registry "$OPS/apexyard.projects.yaml"

# 19. ops alias and ambiguity
mv "$OPS/.git" "$B/ops-dotgit"
ln -s "$P1G" "$OPS/.git"
expect_refuse "19a ops .git linked to a project .git" "$WS/p1/a.ts" "symlink in marker path"
expect_refuse "19b ops .git link refuses ops edits too" "$OPS/src/a.ts" "symlink in marker path"
rm -f "$OPS/.git"
mv "$B/ops-dotgit" "$OPS/.git"
active_ticket_set_context "$WS/p1" "$WS"
expect_refuse "19c a common dir that matches both roots is ambiguous" "$WS/p1/a.ts" "ambiguous common dir"
ctx

# 20. the writer from a clean shell with no preset variables
CLEAN_DIR="$OPS"
env -i HOME="$HOME" PATH="$PATH" APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1 \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com \
  bash -c "cd '$CLEAN_DIR' && . '$LIB' && active_ticket_write '$WS/p1' org/p1 20 'clean shell' 'http://x/20' 'feature/clean'" 2> "$B/w20.err"
rc=$?
if [ "$rc" = 0 ] && [ -f "$P1G/apexyard-ticket" ]; then ok "20 writer works from a clean shell"; else bad "20" "rc=$rc $(cat "$B/w20.err")"; fi
if grep -q '^number=20$' "$P1G/apexyard-ticket" && grep -q '^repo=org/p1$' "$P1G/apexyard-ticket" && grep -q '^started_at=' "$P1G/apexyard-ticket"; then ok "20b marker keeps the key=value format"; else bad "20b" "$(cat "$P1G/apexyard-ticket")"; fi
rm -f "$P1G/apexyard-ticket"

# 21. PWD and OLDPWD are unchanged, and a deleted working directory is refused
cd "$B" || exit 1
OLDPWD="$B/ops"
pw_before="$PWD"
opw_before="$OLDPWD"
_at_memo_clear
active_ticket_lookup "$WS/p1/a.ts"
active_ticket_lookup "$WS/rogue/a.ts"
active_ticket_lookup_cwd
if [ "$PWD" = "$pw_before" ] && [ "$OLDPWD" = "$opw_before" ]; then ok "21a PWD and OLDPWD are unchanged"; else bad "21a" "PWD=$PWD OLDPWD=$OLDPWD"; fi
mkdir "$B/gone"
cd "$B/gone" || exit 1
rmdir "$B/gone"
_at_memo_clear
active_ticket_lookup "$WS/p1/a.ts"
rc=$?
reason="$AT_REASON"
cd "$B" || exit 1
if [ "$rc" != 0 ] && [ -z "$REPLY" ] && [ "$reason" = "cwd unavailable" ]; then ok "21b deleted working directory is refused"; else bad "21b" "rc=$rc reason=$reason"; fi

# 22. malformed .git files
mkdir -p "$WS/p1/two"
printf 'gitdir: %s\ngitdir: %s\n' "$WTG" "$WTG" > "$WS/p1/two/.git"
expect_refuse "22a .git file with a second gitdir line" "$WS/p1/two/a.ts" "not a git tree"
rm -rf "$WS/p1/two"
mkdir -p "$WS/p1/two/.git/objects" "$WS/p1/two/.git/refs"
: > "$WS/p1/two/.git/HEAD"
printf '%s\n' "$P1G" > "$WS/p1/two/.git/commondir"
expect_refuse "22b main .git dir with a commondir file" "$WS/p1/two/a.ts" "not a git tree"
rm -rf "$WS/p1/two"

# 24. a pass followed by a refusal in one process
_at_memo_clear
active_ticket_gitdir "$WS/p1/a.ts"
first="$REPLY"
active_ticket_gitdir "$WS/rogue/a.ts"
if [ "$first" = "$P1G" ] && [ -z "$REPLY" ]; then ok "24 REPLY is empty after a refusal"; else bad "24" "first=$first REPLY=$REPLY"; fi

# 25. forged environment
mkrepo "$B/planted"
FORGE=(env
  OPS_ROOT=/evil WORKSPACE_DIR=/evil PORTFOLIO_WORKSPACE_DIR="$B" PORTFOLIO_REGISTRY=/dev/null AT_REGISTRY=/dev/null
  _AT_OPS="$B" _AT_WS="$B" _AT_REG=/dev/null _PP_WS="$B" _PP_REG=/dev/null
  _LIB_ACTIVE_TICKET_SOURCED=1 _LIB_PORTFOLIO_PATHS_SOURCED=1 _AT_GUARD=1 _PP_GUARD=1
  'BASH_FUNC__at_owned%%=() { return 0; }'
  'BASH_FUNC_active_ticket_lookup%%=() { REPLY=/forged; return 0; }'
  'BASH_FUNC_active_ticket_gitdir%%=() { REPLY=/forged; return 0; }'
  'BASH_FUNC_portfolio_resolve_into_vars%%=() { _PP_WS=/evil; _PP_REG=/dev/null; }'
  HOME="$HOME" PATH="$PATH" APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1)
out=$("${FORGE[@]}" bash -c "cd '$OPS' && . '$LIB' && active_ticket_init && active_ticket_gitdir '$B/planted/a.ts'; echo \"rc=\$? reply=[\$REPLY] reason=[\$AT_REASON]\"" 2>&1)
case "$out" in
  *"rc=1 reply=[]"*"unregistered common dir"*) ok "25a forged environment cannot make a planted repo pass" ;;
  *) bad "25a" "$out" ;;
esac
out=$("${FORGE[@]}" bash -c "cd '$OPS' && . '$LIB' && active_ticket_init && active_ticket_gitdir '$WS/p1/a.ts'; echo \"rc=\$? reply=[\$REPLY]\"" 2>&1)
case "$out" in
  *"rc=0 reply=[$P1G]"*) ok "25b forged environment does not change a real result" ;;
  *) bad "25b" "$out" ;;
esac
out=$("${FORGE[@]}" bash -c "cd '$OPS' && . '$LIB' && active_ticket_write '$B/planted' org/x 1 t u b; echo rc=\$?" 2>&1)
case "$out" in
  *"rc=1"*) ok "25c forged environment cannot make the writer accept a planted repo" ;;
  *) bad "25c" "$out" ;;
esac
if [ ! -e "$B/planted/.git/apexyard-ticket" ]; then ok "25d nothing was written to the planted repo"; else bad "25d" "marker exists"; fi

# 25e. The config reader is absent, and the forged names include the portfolio
# guard. The planted repo is still refused and the real clone still resolves.
mkdir -p "$B/hooks-noconfig" "$B/hooks-noportfolio"
for f in "$SRC_ROOT"/.claude/hooks/_lib-*.sh; do
  case "${f##*/}" in
    _lib-read-config.sh) ;;
    *) cp "$f" "$B/hooks-noconfig/" ;;
  esac
  case "${f##*/}" in
    _lib-portfolio-paths.sh|_lib-read-config.sh) ;;
    *) cp "$f" "$B/hooks-noportfolio/" ;;
  esac
done
FORGE2=(env _PP_WS="$B" _PP_REG="$OPS/apexyard.projects.yaml" _PP_GUARD=1 _PP_FP=forged _AT_REG="$OPS/apexyard.projects.yaml"
  HOME="$HOME" PATH="$PATH" APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1)
out=$("${FORGE2[@]}" bash -c "cd '$OPS' && . '$B/hooks-noconfig/_lib-active-ticket.sh' && active_ticket_init && active_ticket_gitdir '$B/planted/a.ts'; echo \"rc=\$?\"" 2>&1)
case "$out" in *"rc=1"*) ok "25e planted repo is refused without the config reader" ;; *) bad "25e" "$out" ;; esac
out=$("${FORGE2[@]}" bash -c "cd '$OPS' && . '$B/hooks-noconfig/_lib-active-ticket.sh' && active_ticket_init && active_ticket_gitdir '$WS/p1/a.ts'; echo \"rc=\$? \$REPLY\"" 2>&1)
case "$out" in *"rc=0 $P1G"*) ok "25f the real clone resolves without the config reader" ;; *) bad "25f" "$out" ;; esac

# 25g. The portfolio library is absent too. An inherited registry path is not
# trusted, so even the real clone fails closed.
out=$("${FORGE2[@]}" bash -c "cd '$OPS' && . '$B/hooks-noportfolio/_lib-active-ticket.sh' && active_ticket_init; active_ticket_gitdir '$WS/p1/a.ts'; echo \"rc=\$? reason=\$AT_REASON\"" 2>&1)
case "$out" in *"rc=1"*"unregistered common dir"*) ok "25g an inherited registry path is not trusted" ;; *) bad "25g" "$out" ;; esac

# 27. a link before a .. is refused
mkdir -p "$B/elsewhere/src" "$WS/p1/src"
ln -s "$B/elsewhere/src" "$WS/p1/lnk"
expect_refuse "27a a symlinked component before .. is refused" "$WS/p1/lnk/../a.ts" "symlink in marker path"
expect_gd "27b the same path with a real directory resolves" "$WS/p1/src/../a.ts" "$P1G"
rm -f "$WS/p1/lnk"

# 28. the writer refuses a directory at the marker name
mkdir -p "$P1G/apexyard-ticket"
( _at_memo_clear; active_ticket_write "$WS/p1" org/p1 28 t u b ) 2> "$B/w28.err"
rc=$?
leftover=0
for f in "$P1G"/apexyard-ticket.tmp.* "$P1G"/apexyard-ticket/apexyard-ticket.tmp.*; do
  [ ! -e "$f" ] || leftover=$((leftover + 1))
done
if [ "$rc" != 0 ] && [ "$leftover" = 0 ] && grep -q "not a regular file" "$B/w28.err"; then ok "28 the writer refuses a directory at the marker name"; else bad "28" "rc=$rc leftover=$leftover $(cat "$B/w28.err")"; fi
rmdir "$P1G/apexyard-ticket" 2>/dev/null

# 26. re-sourcing keeps the memo
ctx
active_ticket_gitdir "$WS/p1/a.ts"
v1="$AT_VALIDATIONS"
# shellcheck source=/dev/null
. "$LIB"
active_ticket_gitdir "$WS/p1/b.ts"
# shellcheck source=/dev/null
. "$LIB"
active_ticket_gitdir "$WS/p1/c/d.ts"
v2="$AT_VALIDATIONS"
if [ "$v2" = "$v1" ] && [ "$REPLY" = "$P1G" ]; then ok "26 re-sourcing keeps the validation memo"; else bad "26" "v1=$v1 v2=$v2"; fi

# 29. A registry entry's workspace: path names a registered clone outside the
# workspace dir, absolute or relative to the ops root.
EXT="$B/elsewhere/p5"
mkrepo "$EXT"
git -C "$EXT" worktree add -q "$B/p5-wt" -b p5wt
mkrepo "$OPS/other/p6"
mkrepo "$B/real7"
ln -s "$B/real7" "$B/link7"
mkrepo "$B/shared"
write_registry "$OPS/apexyard.projects.yaml" \
  '  - name: p5' '    repo: org/p5' "    workspace: $EXT" \
  '  - name: p6' '    repo: org/p6' '    workspace: other/p6' \
  '  - name: p7' '    repo: org/p7' "    workspace: $B/link7" \
  '  - name: p8' '    repo: org/p8' "    workspace: $B/shared" \
  '  - name: p9' '    repo: org/p9' "    workspace: \"$B/shared\""
ctx
expect_gd "29a an absolute workspace: outside the workspace dir is registered" "$EXT/src/a.ts" "$EXT/.git"
expect_gd "29b a linked worktree of that clone is registered" "$B/p5-wt/src/a.ts" "$EXT/.git/worktrees/p5-wt"
_at_memo_clear
active_ticket_gitdir "$EXT/src/a.ts"
if [ "$AT_PROJECT" = p5 ]; then ok "29c the project name comes from the entry"; else bad "29c" "project=$AT_PROJECT"; fi
expect_gd "29d a relative workspace: resolves against the ops root" "$OPS/other/p6/a.ts" "$OPS/other/p6/.git"
clones=""
for n in p5 p6 p1; do active_ticket_project_clone "$n"; clones="$clones $REPLY"; done
if [ "$clones" = " $EXT $OPS/other/p6 $WS/p1" ]; then ok "29j the clone path of a project follows its workspace: entry"; else bad "29j" "$clones"; fi
expect_refuse "29e a workspace: path that is a symlink is refused" "$B/real7/a.ts" "symlink in marker path"
expect_refuse "29f two entries with the same workspace: are ambiguous" "$B/shared/a.ts" "ambiguous common dir"
printf 'repo=org/p5\nnumber=29\n' > "$EXT/.git/apexyard-ticket"
_at_memo_clear
active_ticket_lookup "$EXT/src/a.ts"
if [ "$?" = 0 ] && [ "$REPLY" = "$EXT/.git/apexyard-ticket" ] && [ "$AT_SOURCE" = tree ]; then ok "29g the new marker of an entry clone counts"; else bad "29g" "REPLY=$REPLY source=$AT_SOURCE reason=$AT_REASON"; fi
_at_memo_clear
active_ticket_project_markers
case "$REPLY" in *"$EXT/.git/apexyard-ticket"*) ok "29h project markers include an entry clone" ;; *) bad "29h" "$REPLY" ;; esac
# A refused tree falls back to the old-layout resolution.
printf 'repo=org/p7\nnumber=30\n' > "$B/real7/.git/apexyard-ticket"
mkdir -p "$OPS/.claude/session"
printf 'repo=org/p7\nnumber=31\n' > "$OPS/.claude/session/current-ticket"
_at_memo_clear
active_ticket_lookup "$B/real7/a.ts"
if [ "$?" = 0 ] && [ "$REPLY" = "$OPS/.claude/session/current-ticket" ] && [ "$AT_SOURCE" = legacy ]; then ok "29i a refused symlinked clone falls back to the old-layout marker"; else bad "29i" "REPLY=$REPLY source=$AT_SOURCE"; fi
rm -f "$OPS/.claude/session/current-ticket" "$EXT/.git/apexyard-ticket" "$B/real7/.git/apexyard-ticket"
write_registry "$OPS/apexyard.projects.yaml"
ctx

# 30. The writer binds the ticket's repo to the tree. A project tree takes
# only a ticket of its own registry entry. The ops fork takes no ticket of a
# registered project. A refused write leaves no marker.
mkrepo "$WS/p2"
write_registry "$OPS/apexyard.projects.yaml" '  - name: p2' '    repos: [org/p2a, org/p2b]'
ctx
rm -f "$P1G/apexyard-ticket" "$WS/p2/.git/apexyard-ticket" "$OPS/.git/apexyard-ticket"
( _at_memo_clear; active_ticket_write "$WS/p2" org/p1 30 t u b ) 2> "$B/w30.err"
if [ "$?" != 0 ] && [ ! -e "$WS/p2/.git/apexyard-ticket" ] && grep -q "not a repo of" "$B/w30.err"; then ok "30a another project's ticket is not written into a project clone"; else bad "30a" "$(cat "$B/w30.err")"; fi
( _at_memo_clear; active_ticket_write "$WS/p2" ORG/P2B 31 t u b ) 2> "$B/w31.err"
if [ "$?" = 0 ] && [ -f "$WS/p2/.git/apexyard-ticket" ]; then ok "30b a repos: slug of the entry is written, without regard to case"; else bad "30b" "$(cat "$B/w31.err")"; fi
rm -f "$WS/p2/.git/apexyard-ticket"
( _at_memo_clear; active_ticket_write "$OPS" org/p1 32 t u b ) 2> "$B/w32.err"
if [ "$?" != 0 ] && [ ! -e "$OPS/.git/apexyard-ticket" ] && grep -q "registered project" "$B/w32.err"; then ok "30c a registered project's ticket is not written into the ops fork"; else bad "30c" "$(cat "$B/w32.err")"; fi
( _at_memo_clear; active_ticket_write "$OPS" org/ops 33 t u b ) 2> "$B/w33.err"
if [ "$?" = 0 ] && [ -f "$OPS/.git/apexyard-ticket" ]; then ok "30d an ops ticket is written into the ops fork"; else bad "30d" "$(cat "$B/w33.err")"; fi
rm -f "$OPS/.git/apexyard-ticket"

# 31. A marker that names a repo outside its tree's entry, planted by hand or
# by an older writer, is not trusted. The old-layout resolution decides.
printf 'repo=org/p1\nnumber=34\n' > "$WS/p2/.git/apexyard-ticket"
_at_memo_clear
active_ticket_lookup "$WS/p2/src/a.ts"
if [ "$?" != 0 ] && [ -z "$REPLY" ] && [ "$AT_REASON" = "marker repo is not bound to this tree" ]; then ok "31a a mismatched project marker is not trusted"; else bad "31a" "REPLY=$REPLY reason=$AT_REASON"; fi
printf 'repo=org/p1\nnumber=35\n' > "$OPS/.git/apexyard-ticket"
_at_memo_clear
active_ticket_lookup "$OPS/bin/tool.sh"
if [ "$?" != 0 ] && [ -z "$REPLY" ]; then ok "31b a project ticket in the ops fork's git dir is not trusted"; else bad "31b" "REPLY=$REPLY reason=$AT_REASON"; fi
mkdir -p "$OPS/.claude/session"
printf 'repo=org/p2a\nnumber=36\n' > "$OPS/.claude/session/current-ticket"
_at_memo_clear
active_ticket_lookup "$WS/p2/src/a.ts"
if [ "$?" = 0 ] && [ "$REPLY" = "$OPS/.claude/session/current-ticket" ] && [ "$AT_SOURCE" = legacy ]; then ok "31c the old-layout marker decides past a mismatched marker"; else bad "31c" "REPLY=$REPLY source=$AT_SOURCE"; fi
rm -f "$OPS/.claude/session/current-ticket" "$WS/p2/.git/apexyard-ticket" "$OPS/.git/apexyard-ticket"
rm -rf "$WS/p2"
write_registry "$OPS/apexyard.projects.yaml"
ctx

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
