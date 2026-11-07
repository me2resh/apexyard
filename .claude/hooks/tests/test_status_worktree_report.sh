#!/bin/bash
# Real worktrees cover preservation and owner reads. Shims inject Git failures.
# shellcheck source=/dev/null
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
set -u

ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)
REPORT=${WORKTREE_REPORT_SCRIPT:-$ROOT/.claude/skills/status/worktree-report.sh}
[ -f "$REPORT" ] || { printf 'FAIL: worktree report script is missing\n'; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/status-worktrees.XXXXXX") || exit 1
TMP=$(CDPATH='' cd -- "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
check() {
  local label=$1; shift
  if "$@" > "$TMP/check-output" 2>&1; then printf 'PASS: %s\n' "$label"; PASS=$((PASS + 1))
  else printf 'FAIL: %s\n' "$label"; sed 's/^/FAIL: /' "$TMP/check-output"; FAIL=$((FAIL + 1)); fi
}
fail_setup() { printf 'FAIL: fixture setup: %s\n' "$1"; exit 1; }
for dep in git jq; do command -v "$dep" >/dev/null || fail_setup "$dep unavailable"; done
REAL_GIT=$(command -v git)
export REAL_GIT
git() { GIT_OPTIONAL_LOCKS=0 "$REAL_GIT" -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"; }
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
commit() {
  git -C "$1" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm "$2" --allow-empty || fail_setup commit
}
repository() {
  git -c init.defaultBranch=main init -q "$1" || fail_setup init
  printf 'fixture\n' > "$1/tracked"
  git -C "$1" add tracked || fail_setup index
  commit "$1" initial
  git init --bare -q "$2" || fail_setup remote
  git -C "$1" remote add origin "$2" || fail_setup remote
  git -C "$1" push -q origin main || fail_setup push
}
ticket() {
  local gd
  gd=$(git -C "$1" rev-parse --absolute-git-dir) || fail_setup ticket
  printf 'repo=%s\nnumber=%s\n' "$2" "$3" > "$gd/apexyard-ticket"
}
repository "$TMP/main" "$TMP/remote.git"
TREES='clean dirty local no-upstream missing alive released dead detached'
for name in $TREES; do
  tree="$TMP/$name tree"
  git -C "$TMP/main" worktree add -q -b "$name" "$tree" || fail_setup "$name"
done
git -C "$TMP/detached tree" checkout -q --detach || fail_setup detached
printf 'untracked\n' > "$TMP/dirty tree/owner.json"
commit "$TMP/local tree" local
mv "$TMP/missing tree" "$TMP/away" || fail_setup prunable
ticket "$TMP/clean tree" owner/repo 42
ticket "$TMP/no-upstream tree" invalid oops

# Seed records directly: report tests exercise readers, not owner writers.
. "$ROOT/.claude/hooks/_lib-worktree-owner.sh"
OWNER_START=$(_wto_pid_start "$$") || OWNER_START=''
OWNER_BOOT=$(_wto_host_boot_id)
gone_pid=$(sh -c 'echo "$$"')
seed_owner() {
  local gd
  gd=$(git -C "$1" rev-parse --absolute-git-dir) || fail_setup owner
  jq -n --arg status "$2" --argjson pid "${3:-$$}" --arg start "${OWNER_START:-unavailable}" --arg boot "$OWNER_BOOT" '
    {session_id:"report-test",harness:"test-shell",pid:$pid,pid_start:$start,boot_id:$boot} as $identity |
    {version:1,generation:1,status:$status,lease_heartbeat_at:1,lease_expires_at:2} +
    (if $status == "released" then {owner:null,released_by:$identity} else {owner:$identity} end)
  ' > "$gd/apexyard-owner" || fail_setup owner
}
seed_owner "$TMP/alive tree" active
seed_owner "$TMP/released tree" released
seed_owner "$TMP/dead tree" active "$gone_pid"

# A valid released control distinguishes unreadable data from malformed data.
owner_gitdir=$(git -C "$TMP/released tree" rev-parse --absolute-git-dir) || fail_setup owner
cp "$owner_gitdir/apexyard-owner" "$TMP/valid-owner"

run_report() {
  REPORT_RC=0
  "$BASH" "$REPORT" "$@" > "$TMP/report" 2> "$TMP/stderr" || REPORT_RC=$?
}
row_is() {
  local path=$1 expected
  shift
  expected="$path"
  while [ "$#" -gt 0 ]; do expected="$expected"$'\t'"$1"; shift; done
  [ "$REPORT_RC" -eq 0 ] && [ ! -s "$TMP/stderr" ] || return 1
  ROW_PATH="$path" ROW_EXPECTED="$expected" awk -F '\t' '
    $1 == ENVIRON["ROW_PATH"] { found++; if ($0 != ENVIRON["ROW_EXPECTED"]) { bad++; print $0 } }
    END { exit !(found == 1 && !bad) }' "$TMP/report"
}
snapshot() {
  local name gd index
  for name in main $TREES; do
    [ "$name" != missing ] || continue
    tree="$TMP/$name tree"
    [ "$name" != main ] || tree="$TMP/main"
    gd=$(git -C "$tree" rev-parse --absolute-git-dir) || return 1
    index="$gd/index"
    if [ -f "$index" ]; then
      if stat -f '%m' "$index" >/dev/null 2>&1; then stat -f '%m' "$index"
      else stat -c '%Y' "$index"; fi
    else printf 'no index\n'; fi
    git -C "$tree" status --porcelain --untracked-files=normal || return 1
    [ ! -e "$gd/index.lock" ] && [ ! -e "$gd/apexyard-owner.lock" ] || return 1
    if [ -f "$gd/apexyard-owner" ]; then cat "$gd/apexyard-owner"; fi
    for record in apexyard-ticket apexyard-owner; do
      if [ -f "$gd/$record" ]; then
        if stat -f '%m' "$gd/$record" >/dev/null 2>&1; then stat -f '%m' "$gd/$record"
        else stat -c '%Y' "$gd/$record"; fi
        cksum "$gd/$record" || return 1
      fi
    done
  done
}
snapshot > "$TMP/before" || fail_setup snapshot
sleep 1
run_report "$TMP/main"
check 'listing exits zero' test "$REPORT_RC" -eq 0
check 'successful report has no stderr' test ! -s "$TMP/stderr"
check 'header has five fields' test "$(head -1 "$TMP/report")" = $'path\tbranch\towner\twork\tticket'
check 'one row per linked worktree' test "$(wc -l < "$TMP/report" | tr -d ' ')" = 10
check 'main working tree is absent' awk -F '\t' -v p="$TMP/main" '$1 == p { found=1 } END { exit found }' "$TMP/report"
while IFS='|' read -r name branch owner work ticket_value; do
  check "inventory $name evidence" row_is "$TMP/$name tree" "$branch" "$owner" "$work" "$ticket_value"
done <<'CASES'
clean|clean|none|preserved|owner/repo#42
dirty|dirty|none|dirty|-
local|local|none|unpushed|-
no-upstream|no-upstream|none|preserved|-
missing|missing|unknown|unknown:path unavailable|-
alive|alive|alive|preserved|-
released|released|released|preserved|-
dead|dead|dead|preserved|-
detached|detached|none|preserved|-
CASES
snapshot > "$TMP/after" || fail_setup 'post-report snapshot'
check 'indexes statuses owners and lock absence are unchanged' cmp -s "$TMP/before" "$TMP/after"
seed_owner "$TMP/alive tree" released

mkdir "$TMP/bin" "$TMP/no-jq"
cat > "$TMP/bin/git" <<'SHIM'
#!/bin/bash
[ "${GIT_OPTIONAL_LOCKS:-}" = 0 ] || exit 90
[ "$1" = -c ] && [ "$2" = core.fsmonitor=false ] || exit 91
[ "${GIT_NO_LAZY_FETCH:-}" = 1 ] || exit 92
if [ "${REPORT_TEST_TRACE_UNPRINTABLE:-0}" = 1 ]; then
  case "$*" in
    *$'\t'*|*$'\n'*) printf 'git\n' >> "$REPORT_TEST_LOOKUP_LOG" ;;
  esac
fi
case " $* " in
  *' worktree list '*)
    case "${REPORT_TEST_MODE:-}" in
      old-git) case " $* " in *' -z '*) exit 129 ;; esac ;;
      tab-branch)
        printf 'worktree %s\0HEAD fixture\0branch refs/heads/main\0\0worktree %s\0HEAD fixture\0branch refs/heads/odd\tbranch\0\0' "$REPORT_TEST_MAIN" "$REPORT_TEST_TREE"
        exit 0 ;;
    esac ;;
  *' status '*)
    case " $* " in *' --ignore-submodules=all '*) ;; *) exit 93 ;; esac
    case "${REPORT_TEST_MODE:-}" in status-error) exit 1 ;; esac ;;
  *' rev-list '*)
    case "${REPORT_TEST_MODE:-}" in count-error) exit 1 ;; bad-count) printf 'NaN\n'; exit 0 ;; esac ;;
esac
case " $* " in
  *' status '*|*' rev-list '*)
    if [ "${REPORT_TEST_FORBID_CONTENT:-0}" = 1 ]; then
      printf '%s\n' "$*" >> "$REPORT_TEST_CONTENT_LOG"
      exit 94
    fi ;;
esac
exec "$REAL_GIT" "$@"
SHIM
chmod +x "$TMP/bin/git"
export REPORT_TEST_MAIN="$TMP/main" REPORT_TEST_TREE="$TMP/clean tree"
while IFS='|' read -r mode branch work; do
  REPORT_TEST_MODE="$mode" PATH="$TMP/bin:$PATH" run_report "$TMP/main"
  check "$mode guarded work owner ticket and silent success" row_is "$TMP/clean tree" "$branch" none "$work" 'owner/repo#42'
done <<'CASES'
modern|clean|preserved
status-error|clean|unknown:checkout unknown
count-error|clean|unknown:commits unknown
bad-count|clean|unknown:commits unknown
tab-branch|odd?branch|unknown:unprintable path
CASES

unknown_owners() {
  [ "$REPORT_RC" -eq 0 ] && [ ! -s "$TMP/stderr" ] &&
    awk -F '\t' 'NR > 1 { n++; if ($3 != "unknown") bad++ } END { exit !(n == 9 && !bad) }' "$TMP/report"
}
for dep in git dirname; do
  if [ "$dep" = git ]; then target=$REAL_GIT; else target=$(command -v "$dep"); fi
  ln -s "$target" "$TMP/no-jq/$dep"
done
PATH="$TMP/no-jq" run_report "$TMP/main"
check 'missing jq makes owners unknown silently' unknown_owners

mkdir -p "$TMP/no-library/.claude/skills/status" "$TMP/no-library/.claude/hooks"
cp "$REPORT" "$TMP/no-library/.claude/skills/status/worktree-report.sh"
cp "$ROOT/.claude/hooks/_lib-active-ticket.sh" "$TMP/no-library/.claude/hooks/"
REPORT_ORIGINAL=$REPORT
REPORT="$TMP/no-library/.claude/skills/status/worktree-report.sh"
run_report "$TMP/main"
check 'missing owner library makes owners unknown silently' unknown_owners
REPORT=$REPORT_ORIGINAL

# Exercise reader-produced unknown values without changing the row initializer.
owner_unreadable_skip_printed=0
for mode in modern old-git; do
  printf '{bad json}\n' > "$owner_gitdir/apexyard-owner"
  REPORT_TEST_MODE="$mode" PATH="$TMP/bin:$PATH" run_report "$TMP/main"
  check "$mode malformed owner record is unknown" row_is "$TMP/released tree" released unknown preserved -
  cp "$TMP/valid-owner" "$owner_gitdir/apexyard-owner"
  REPORT_TEST_MODE="$mode" PATH="$TMP/bin:$PATH" run_report "$TMP/main"
  check "$mode readable owner control is released" row_is "$TMP/released tree" released released preserved -
  chmod 000 "$owner_gitdir/apexyard-owner"
  if [ -r "$owner_gitdir/apexyard-owner" ]; then
    if [ "$owner_unreadable_skip_printed" -eq 0 ]; then
      printf 'SKIP: unreadable owner record checks skipped because chmod 000 leaves the record readable when running as root.\n'
      owner_unreadable_skip_printed=1
    fi
    chmod 600 "$owner_gitdir/apexyard-owner"
    continue
  fi
  REPORT_TEST_MODE="$mode" PATH="$TMP/bin:$PATH" run_report "$TMP/main"
  check "$mode unreadable owner record is unknown" row_is "$TMP/released tree" released unknown preserved -
  chmod 600 "$owner_gitdir/apexyard-owner"
done

mkdir -p "$TMP/unexpected-owner/.claude/skills/status" "$TMP/unexpected-owner/.claude/hooks"
cp "$REPORT" "$TMP/unexpected-owner/.claude/skills/status/worktree-report.sh"
cp "$ROOT/.claude/hooks/_lib-active-ticket.sh" "$TMP/unexpected-owner/.claude/hooks/"
cat > "$TMP/unexpected-owner/.claude/hooks/_lib-worktree-owner.sh" <<'READER'
worktree_owner_status() { printf 'unexpected reader output\n'; return 2; }
READER
REPORT="$TMP/unexpected-owner/.claude/skills/status/worktree-report.sh"
for mode in modern old-git; do
  REPORT_TEST_MODE="$mode" PATH="$TMP/bin:$PATH" run_report "$TMP/main"
  check "$mode unexpected reader stdout becomes unknown" row_is "$TMP/released tree" released unknown preserved -
done
REPORT=$REPORT_ORIGINAL

head_hash=$(git -C "$TMP/main" rev-parse HEAD)
forged_name="clean tree"$'\n'"HEAD $head_hash"$'\nbranch refs/heads/fake\n\n'
forged_display=${forged_name//$'\n'/?}
for name in $'tab\ttree' $'line\nbreak' 'quote"tree' 'back\slash' \
  $'clean tree\nHEAD fake' $'clean tree\nbare' "clean tree"$'\n'"HEAD $head_hash" \
  "$forged_name" $'empty\n\nline' $'trailing\n' 'relative tree'; do
    git -c worktree.useRelativePaths=true -C "$TMP/main" worktree add -q --detach "$TMP/$name" || fail_setup unusual-path
done
gitdir=$(git -C "$TMP/clean tree" rev-parse --absolute-git-dir)
backpointer=$(cat "$gitdir/gitdir")
printf '%s' "$backpointer" > "$gitdir/gitdir"
head_contents=$(cat "$gitdir/HEAD")
printf '%s' "$head_contents" > "$gitdir/HEAD"
# Stale registrations must never borrow evidence from a replacement repository.
git -C "$TMP/main" worktree add -q -b replaced "$TMP/replaced tree" || fail_setup replaced
git -C "$TMP/main" worktree add -q -b locked "$TMP/locked tree" || fail_setup locked
git -C "$TMP/main" worktree lock "$TMP/locked tree" || fail_setup lock
mv "$TMP/replaced tree" "$TMP/original checkout" || fail_setup replaced
repository "$TMP/unrelated-main" "$TMP/unrelated.git"
git -C "$TMP/unrelated-main" worktree add -q -b unrelated "$TMP/replaced tree" || fail_setup replacement
seed_owner "$TMP/replaced tree" released
ticket "$TMP/replaced tree" unrelated/repo 99
mv "$TMP/locked tree/.git" "$TMP/locked-gitfile" || fail_setup missing-gitfile
# A prunable checkout without .git must not discover its parent repository.
parent_tree="$TMP/replaced tree"
prunable_tree="$parent_tree/prunable tree"
git -C "$TMP/main" worktree add -q -b prunable "$prunable_tree" || fail_setup prunable-parent
mv "$prunable_tree/.git" "$TMP/prunable-gitfile" || fail_setup prunable-parent
git -C "$parent_tree" add 'prunable tree/tracked' || fail_setup prunable-parent
commit "$parent_tree" parent
git -C "$parent_tree" push -q origin unrelated || fail_setup prunable-parent
parent_gitdir=$(git -C "$parent_tree" rev-parse --absolute-git-dir) || fail_setup prunable-parent
ticket "$parent_tree" parent/repo 88
check 'prunable fixture discovers its parent git dir' test "$(git -C "$prunable_tree" rev-parse --absolute-git-dir)" -ef "$parent_gitdir"
check 'prunable fixture parent is clean' test -z "$(git -C "$prunable_tree" status --porcelain --untracked-files=normal)"
check 'prunable fixture parent has no unpushed commits' test "$(git -C "$prunable_tree" rev-list --count HEAD --not --remotes)" = 0
# Git resolves a symlink before a following .. in a relative backpointer.
mkdir -p "$TMP/physical/nested"
ln -s "$TMP/physical/nested" "$TMP/linked-parent"
relative_tree="$TMP/physical/relative symlink tree"
git -C "$TMP/main" worktree add -q -b relative-symlink "$relative_tree" || fail_setup relative-symlink
seed_owner "$relative_tree" released
gitdir=$(git -C "$relative_tree" rev-parse --absolute-git-dir) || fail_setup relative-symlink
ticket "$relative_tree" relative/repo 73
printf '../../../../linked-parent/../relative symlink tree/.git\n' > "$gitdir/gitdir"
relative_resolved=0
probe_output=$(git -C "$TMP/main" worktree list --porcelain 2>/dev/null) || fail_setup relative-symlink-probe
if printf '%s\n' "$probe_output" | grep -Fxq "worktree $relative_tree"; then
  relative_resolved=1
fi
# A trailing newline must never resolve to the printable checkout's evidence.
plain_tree="$TMP/tree"
newline_tree="$plain_tree"$'\n'
git -C "$TMP/main" worktree add -q -b collision-plain "$plain_tree" || fail_setup collision
git -C "$TMP/main" worktree add -q -b collision-newline "$newline_tree" || fail_setup collision
seed_owner "$plain_tree" active
plain_gitdir=$(git -C "$plain_tree" rev-parse --absolute-git-dir) || fail_setup collision
newline_gitdir=$(git -C "$newline_tree" rev-parse --absolute-git-dir) || fail_setup collision
# The owner API rejects this path. Seed its exact administrative record.
jq --argjson pid "$gone_pid" '.owner.pid = $pid' "$plain_gitdir/apexyard-owner" > "$newline_gitdir/apexyard-owner"
printf 'repo=collision/plain\nnumber=61\n' > "$plain_gitdir/apexyard-ticket"
printf 'repo=collision/newline\nnumber=62\n' > "$newline_gitdir/apexyard-ticket"

# Trace owner calls before library rejection and all Git lookups.
mkdir -p "$TMP/collision-report/.claude/skills/status" "$TMP/collision-report/.claude/hooks"
cp "$REPORT" "$TMP/collision-report/.claude/skills/status/worktree-report.sh"
cp "$ROOT/.claude/hooks/_lib-worktree-owner.sh" "$ROOT/.claude/hooks/_lib-active-ticket.sh" "$TMP/collision-report/.claude/hooks/"
cat >> "$TMP/collision-report/.claude/hooks/_lib-worktree-owner.sh" <<'TRACE'
eval "$(declare -f worktree_owner_status | sed '1s/worktree_owner_status/collision_owner_status/')"
worktree_owner_status() {
  case "$1" in
    *$'\t'*|*$'\n'*) printf 'owner\n' >> "$REPORT_TEST_LOOKUP_LOG" ;;
  esac
  collision_owner_status "$@"
}
TRACE
REPORT_ORIGINAL=$REPORT
REPORT="$TMP/collision-report/.claude/skills/status/worktree-report.sh"
export REPORT_TEST_LOOKUP_LOG="$TMP/unprintable-lookups"
for mode in modern old-git; do
  : > "$REPORT_TEST_LOOKUP_LOG"
  REPORT_TEST_TRACE_UNPRINTABLE=1 REPORT_TEST_MODE="$mode" PATH="$TMP/bin:$PATH" run_report "$TMP/main"
  while IFS='|' read -r path branch owner work ticket_value; do
    check "$mode path $path evidence" row_is "$TMP/$path" "$branch" "$owner" "$work" "$ticket_value"
  done <<CASES
tab?tree|detached|unknown|unknown:unprintable path|-
line?break|detached|unknown|unknown:unprintable path|-
quote"tree|detached|none|preserved|-
back\\slash|detached|none|preserved|-
clean tree?HEAD fake|detached|unknown|unknown:unprintable path|-
clean tree?bare|detached|unknown|unknown:unprintable path|-
clean tree?HEAD $head_hash|detached|unknown|unknown:unprintable path|-
$forged_display|detached|unknown|unknown:unprintable path|-
empty??line|detached|unknown|unknown:unprintable path|-
trailing?|detached|unknown|unknown:unprintable path|-
relative tree|detached|none|preserved|-
clean tree|clean|none|preserved|owner/repo#42
replaced tree|replaced|unknown|unknown:path unavailable|-
locked tree|locked|unknown|unknown:path unavailable|-
replaced tree/prunable tree|prunable|unknown|unknown:path unavailable|-
tree|collision-plain|alive|preserved|collision/plain#61
tree?|collision-newline|unknown|unknown:unprintable path|-
CASES
  if [ "$relative_resolved" -eq 1 ]; then
    check "$mode path physical/relative symlink tree evidence" row_is "$TMP/physical/relative symlink tree" relative-symlink released preserved 'relative/repo#73'
  elif [ "$mode" = modern ]; then
    check "$mode path ../../../../linked-parent/../relative symlink tree evidence" row_is '../../../../linked-parent/../relative symlink tree' relative-symlink unknown 'unknown:path unavailable' -
  else
    printf 'SKIP: legacy-mode relative backpointer check skipped because this Git prints relative gitdir backpointers raw and does not resolve them.\n'
  fi
  check "$mode keeps five fields per row" awk -F '\t' 'NF != 5 { bad++ } END { exit bad != 0 }' "$TMP/report"
  check "$mode unprintable paths skip every lookup" test ! -s "$REPORT_TEST_LOOKUP_LOG"
done
REPORT=$REPORT_ORIGINAL
run_report "$TMP/clean tree"
check 'invoking from a linked worktree still omits main' test "$(wc -l < "$TMP/report" | tr -d ' ')" = 27
REPORT_TEST_MODE=old-git PATH="$TMP/bin:$PATH" run_report "$TMP/relative tree"
check 'legacy inventory resolves common metadata from a linked worktree' row_is "$TMP/clean tree" clean none preserved 'owner/repo#42'

# Absolute backpointers use the stored path as Git prints it.
git -C "$TMP/main" worktree add -q -b absolute-symlink "$TMP/moved-target" || fail_setup absolute-symlink
mv "$TMP/moved-target" "$TMP/absolute-real" || fail_setup absolute-symlink
ln -s "$TMP/absolute-real" "$TMP/moved-target" || fail_setup absolute-symlink
mkdir "$TMP/parent-real" || fail_setup parent-symlink
git -C "$TMP/main" worktree add -q -b parent-symlink "$TMP/parent-real/parent tree" || fail_setup parent-symlink
mv "$TMP/parent-real" "$TMP/parent-moved" || fail_setup parent-symlink
ln -s "$TMP/parent-moved" "$TMP/parent-real" || fail_setup parent-symlink
for mode in modern old-git; do
  REPORT_TEST_MODE="$mode" PATH="$TMP/bin:$PATH" run_report "$TMP/main"
  check "$mode absolute symlink backpointer row" row_is "$TMP/moved-target" absolute-symlink none preserved -
  check "$mode parent symlink backpointer row" row_is "$TMP/parent-real/parent tree" parent-symlink none preserved -
done

# A symbolic HEAD outside refs/heads/ prints the full ref in both modes.
git -C "$TMP/main" worktree add -q -b tag-sym "$TMP/tag tree" || fail_setup tag-sym
git -C "$TMP/tag tree" symbolic-ref HEAD refs/tags/v1 || fail_setup tag-sym
for mode in modern old-git; do
  REPORT_TEST_MODE="$mode" PATH="$TMP/bin:$PATH" run_report "$TMP/main"
  check "$mode symbolic HEAD outside refs/heads" row_is "$TMP/tag tree" 'refs/tags/v1' none dirty -
done

# Legacy metadata-unavailable rows print - in the branch column.
git -C "$TMP/main" worktree add -q -b garbage-tree "$TMP/garbage tree" || fail_setup garbage
garbage_gd=$(git -C "$TMP/garbage tree" rev-parse --absolute-git-dir) || fail_setup garbage
printf 'garbage\n' > "$garbage_gd/gitdir" || fail_setup garbage
git -C "$TMP/main" worktree add -q -b empty-tree "$TMP/empty tree" || fail_setup empty-tree
empty_gd=$(git -C "$TMP/empty tree" rev-parse --absolute-git-dir) || fail_setup empty-tree
printf '' > "$empty_gd/gitdir" || fail_setup empty-tree
REPORT_TEST_MODE=old-git PATH="$TMP/bin:$PATH" run_report "$TMP/main"
check 'legacy garbage gitdir metadata unavailable row' row_is "<unreadable worktree: ${garbage_gd##*/}>" - unknown 'unknown:metadata unavailable' -
check 'legacy empty gitdir metadata unavailable row' row_is "<unreadable worktree: ${empty_gd##*/}>" - unknown 'unknown:metadata unavailable' -

# A configured filter can write even when optional Git locks are disabled.
printf 'tracked filter=sentinel\n' > "$TMP/clean tree/.gitattributes"
git -C "$TMP/clean tree" add .gitattributes || fail_setup attributes
commit "$TMP/clean tree" attributes
cat > "$TMP/filter-command" <<'FILTER'
#!/bin/sh
printf 'filter ran\n' > "$0.sentinel"
cat
FILTER
chmod +x "$TMP/filter-command"
# Equal byte counts force the control status to execute the clean filter.
printf 'changed\n' > "$TMP/clean tree/tracked"
git -C "$TMP/clean tree" config filter.sentinel.clean "\"$TMP/filter-command\"" || fail_setup filter
git -C "$TMP/clean tree" status --porcelain --untracked-files=normal > "$TMP/filter-control-status" || fail_setup filter-control
[ -e "$TMP/filter-command.sentinel" ] || fail_setup 'clean filter control'
mv "$TMP/filter-command.sentinel" "$TMP/filter-control-sentinel" || fail_setup filter-control
run_report "$TMP/main"
check 'clean filter makes work unknown' row_is "$TMP/clean tree" clean none 'unknown:filters configured' 'owner/repo#42'
check 'clean filter never writes its sentinel' test ! -e "$TMP/filter-command.sentinel"
git -C "$TMP/clean tree" config --unset filter.sentinel.clean || fail_setup filter
git -C "$TMP/clean tree" config filter.sentinel.process "\"$TMP/filter-command\"" || fail_setup filter
export REPORT_TEST_CONTENT_LOG="$TMP/content-commands"
REPORT_TEST_FORBID_CONTENT=1 PATH="$TMP/bin:$PATH" run_report "$TMP/main"
check 'process filter makes work unknown' row_is "$TMP/clean tree" clean none 'unknown:filters configured' 'owner/repo#42'
check 'filters skip both status and revision count' test ! -e "$REPORT_TEST_CONTENT_LOG"
git -C "$TMP/clean tree" config --unset filter.sentinel.process || fail_setup filter

# Partial clones must skip content reads even without GIT_NO_LAZY_FETCH support.
object_dir=$(git -C "$TMP/main" rev-parse --git-path objects) || fail_setup objects
case "$object_dir" in /*) ;; *) object_dir="$TMP/main/$object_dir" ;; esac
object_snapshot() { find "$object_dir" -type f > "$TMP/object-list" && LC_ALL=C sort "$TMP/object-list"; }
object_snapshot > "$TMP/objects-before" || fail_setup objects
for indicator in both promisor partialClone; do
  case "$indicator" in both|partialClone) git -C "$TMP/main" config extensions.partialClone origin || fail_setup partial ;; esac
  case "$indicator" in both|promisor) git -C "$TMP/main" config remote.origin.promisor yes || fail_setup partial ;; esac
  for mode in modern old-git; do
    REPORT_TEST_FORBID_CONTENT=1 REPORT_TEST_MODE="$mode" PATH="$TMP/bin:$PATH" run_report "$TMP/main"
    check "$mode $indicator partial clone makes work unknown" row_is "$TMP/clean tree" clean none 'unknown:partial clone' 'owner/repo#42'
    check "$mode $indicator partial clone skips content inspection" test ! -e "$REPORT_TEST_CONTENT_LOG"
    object_snapshot > "$TMP/objects-after" || fail_setup objects
    check "$mode $indicator partial clone preserves objects" cmp -s "$TMP/objects-before" "$TMP/objects-after"
  done
  case "$indicator" in both|partialClone) git -C "$TMP/main" config --unset extensions.partialClone || fail_setup partial ;; esac
  case "$indicator" in both|promisor) git -C "$TMP/main" config --unset remote.origin.promisor || fail_setup partial ;; esac
done

# Snapshot index contents and modification times without opening them through Git.
index_snapshot() {
  local directory file
  for directory in "$split_gitdir" "$split_common"; do
    for file in "$directory/index" "$directory"/sharedindex.*; do
      [ -e "$file" ] || continue
      if stat -f '%m' "$file" >/dev/null 2>&1; then stat -f '%m' "$file" || return 1
      else stat -c '%Y' "$file" || return 1; fi
      cksum "$file" || return 1
    done
  done
}
for indicator in worktree-files common-files configured; do
  split_main="$TMP/split-$indicator"
  split_tree="$TMP/split-$indicator tree"
  repository "$split_main" "$TMP/split-$indicator.git"
  git -C "$split_main" worktree add -q -b split "$split_tree" || fail_setup split-index
  split_gitdir=$(git -C "$split_tree" rev-parse --absolute-git-dir) || fail_setup split-index
  split_common=$(git -C "$split_main" rev-parse --absolute-git-dir) || fail_setup split-index
  case "$indicator" in
    worktree-files) split_source=$split_tree ;;
    common-files) split_source=$split_main ;;
    configured) git -C "$split_main" config core.splitIndex true || fail_setup split-index ;;
  esac
  if [ "$indicator" != configured ]; then
    git -C "$split_source" update-index --split-index || fail_setup split-index
    shared_count=0
    for file in "$split_gitdir"/sharedindex.* "$split_common"/sharedindex.*; do
      [ -f "$file" ] || continue
      touch -t 200001010000 "$file" || fail_setup split-index
      shared_count=$((shared_count + 1))
    done
    [ "$shared_count" -gt 0 ] || fail_setup 'shared index was not created'
  fi
  for mode in modern old-git; do
    index_snapshot > "$TMP/split-before" || fail_setup split-index
    : > "$REPORT_TEST_CONTENT_LOG"
    REPORT_TEST_FORBID_CONTENT=1 REPORT_TEST_MODE="$mode" PATH="$TMP/bin:$PATH" run_report "$split_main"
    check "$mode $indicator split index makes work unknown" row_is "$split_tree" split none 'unknown:split index' -
    check "$mode $indicator split index skips status and revision count" test ! -s "$REPORT_TEST_CONTENT_LOG"
    index_snapshot > "$TMP/split-after" || fail_setup split-index
    check "$mode $indicator split index detector preserves index contents and mtimes" cmp -s "$TMP/split-before" "$TMP/split-after"
    # Allow real content inspection so a missing guard cannot hide its writes.
    REPORT_TEST_MODE="$mode" PATH="$TMP/bin:$PATH" run_report "$split_main"
    check "$mode $indicator native split index row is unknown" row_is "$split_tree" split none 'unknown:split index' -
    index_snapshot > "$TMP/split-after" || fail_setup split-index
    check "$mode $indicator report preserves shared index contents and mtimes" cmp -s "$TMP/split-before" "$TMP/split-after"
  done
done

mkdir "$TMP/not-repo"
run_report "$TMP/not-repo"
check 'listing failure exits two' test "$REPORT_RC" -eq 2
check 'listing failure explains the reason on stderr' test -s "$TMP/stderr"
git -c init.defaultBranch=main init -q "$TMP/empty" || fail_setup empty
run_report "$TMP/empty"
check 'no linked worktrees produces the header only' test "$(cat "$TMP/report")" = $'path\tbranch\towner\twork\tticket'
check 'no linked worktrees exits zero' test "$REPORT_RC" -eq 0
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
