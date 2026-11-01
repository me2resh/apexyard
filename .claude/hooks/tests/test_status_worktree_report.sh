#!/bin/bash
# Real worktrees exercise preservation and owner reads. Git shims inject errors
# and porcelain fields that Git refuses to create, such as a tab in a branch.
# shellcheck source=/dev/null
. "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
set -u

ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)
REPORT=${WORKTREE_REPORT_SCRIPT:-$ROOT/.claude/skills/status/worktree-report.sh}
if [ ! -f "$REPORT" ]; then
  printf 'FAIL: worktree report script is missing\n'
  exit 1
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/status-worktrees.XXXXXX") || exit 1
TMP=$(CDPATH='' cd -- "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
check() {
  local label=$1
  shift
  if "$@" > "$TMP/check-output" 2>&1; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s\n' "$label"
    sed 's/^/FAIL: /' "$TMP/check-output"
    FAIL=$((FAIL + 1))
  fi
}
fail_setup() { printf 'FAIL: fixture setup: %s\n' "$1"; exit 1; }
for dep in git jq; do command -v "$dep" >/dev/null || fail_setup "$dep unavailable"; done
REAL_GIT=$(command -v git)
export REAL_GIT
git() { GIT_OPTIONAL_LOCKS=0 "$REAL_GIT" -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"; }
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
git -c init.defaultBranch=main init -q "$TMP/main" || fail_setup init
printf 'fixture\n' > "$TMP/main/tracked"
git -C "$TMP/main" add tracked || fail_setup index
git -C "$TMP/main" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c commit.gpgsign=false commit -qm initial || fail_setup commit
git init --bare -q "$TMP/remote.git" || fail_setup remote
git -C "$TMP/main" remote add origin "$TMP/remote.git" || fail_setup remote
git -C "$TMP/main" push -q origin main || fail_setup push
TREES='clean dirty local no-upstream missing alive released dead detached'
for name in $TREES; do
  tree="$TMP/$name tree"
  git -C "$TMP/main" worktree add -q -b "$name" "$tree" || fail_setup "$name"
done
git -C "$TMP/detached tree" checkout -q --detach || fail_setup detached
printf 'untracked\n' > "$TMP/dirty tree/owner.json"
git -C "$TMP/local tree" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c commit.gpgsign=false commit -qm local --allow-empty || fail_setup local
# A moved directory leaves the original registration prunable.
mv "$TMP/missing tree" "$TMP/away" || fail_setup prunable
gitdir=$(git -C "$TMP/clean tree" rev-parse --absolute-git-dir)
printf 'repo=owner/repo\nnumber=42\ntitle=Fixture\n' > "$gitdir/apexyard-ticket"
gitdir=$(git -C "$TMP/no-upstream tree" rev-parse --absolute-git-dir)
printf 'repo=invalid\nnumber=oops\n' > "$gitdir/apexyard-ticket"

# Use the public acquire and release APIs with this shell's identity.
. "$ROOT/.claude/hooks/_lib-worktree-owner.sh"
OWNER_START=$(TZ=UTC0 LC_ALL=C ps -o lstart= -p "$$" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
OWNER_BOOT=''
if [ -r /proc/sys/kernel/random/boot_id ]; then
  IFS= read -r OWNER_BOOT < /proc/sys/kernel/random/boot_id
else
  OWNER_BOOT=$(sysctl -n kern.boottime 2>/dev/null) || OWNER_BOOT=''
  case "$OWNER_BOOT" in *'}'*) OWNER_BOOT="${OWNER_BOOT%%\}*}}" ;; *) OWNER_BOOT='' ;; esac
fi
# Missing process evidence must remain visible as failed liveness assertions.
worktree_owner_identity() {
  jq -cn --argjson pid "$$" --arg start "${OWNER_START:-unavailable}" --arg boot "${OWNER_BOOT:-unknown-boot}" \
    '{session_id:"report-test",harness:"test-shell",pid:$pid,pid_start:$start,boot_id:$boot}'
}
# Lock setup can use synthetic process evidence when the sandbox denies host
# inspection. These functions are scoped to setup, never the report process.
fixture_owner_action() (
  ps() {
    command ps "$@" 2>/dev/null && return
    case "$*" in '-o lstart= -p '*) printf 'Sat Oct 31 10:00:00 2026\n' ;; *) return 1 ;; esac
  }
  sysctl() {
    command sysctl "$@" 2>/dev/null && return
    printf '{ sec = 123, usec = 456 }\n'
  }
  "$@"
)
fixture_owner_action worktree_owner_acquire "$TMP/alive tree" || fail_setup acquire
fixture_owner_action worktree_owner_acquire "$TMP/released tree" || fail_setup acquire
fixture_owner_action worktree_owner_release "$TMP/released tree" || fail_setup release
fixture_owner_action worktree_owner_acquire "$TMP/dead tree" || fail_setup acquire
( exit 0 ) &
gone_pid=$!
wait "$gone_pid"
record=$(git -C "$TMP/dead tree" rev-parse --absolute-git-dir)/apexyard-owner
jq --argjson pid "$gone_pid" '.owner.pid = $pid' "$record" > "$TMP/dead-record"
mv "$TMP/dead-record" "$record"

run_report() {
  REPORT_RC=0
  "$BASH" "$REPORT" "$@" > "$TMP/report" 2> "$TMP/stderr" || REPORT_RC=$?
}
field_is() {
  local path=$1 column=$2 expected=$3
  ROW_PATH="$path" ROW_COLUMN="$column" ROW_EXPECTED="$expected" awk -F '\t' \
    '$1 == ENVIRON["ROW_PATH"] {
       found++
       if ($ENVIRON["ROW_COLUMN"] != ENVIRON["ROW_EXPECTED"]) {
         bad++
         print "expected " ENVIRON["ROW_EXPECTED"] ", got " $ENVIRON["ROW_COLUMN"]
       }
     }
     END { if (found != 1) print "matching rows: " found + 0; exit !(found == 1 && !bad) }' "$TMP/report"
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
check 'clean pushed work is preserved' field_is "$TMP/clean tree" 4 preserved
check 'untracked owner.json is dirty' field_is "$TMP/dirty tree" 4 dirty
check 'local commits are unpushed' field_is "$TMP/local tree" 4 unpushed
check 'remote HEAD without an upstream is preserved' field_is "$TMP/no-upstream tree" 4 preserved
check 'prunable registration is unavailable' field_is "$TMP/missing tree" 4 'unknown:path unavailable'
check 'detached worktree is identified' field_is "$TMP/detached tree" 2 detached
check 'branch prefix is removed' field_is "$TMP/clean tree" 2 clean
check 'missing owner record is none' field_is "$TMP/clean tree" 3 none
check 'test shell owner is alive with real process tools' field_is "$TMP/alive tree" 3 alive
check 'released owner is released' field_is "$TMP/released tree" 3 released
check 'exited owner is dead with real process tools' field_is "$TMP/dead tree" 3 dead
check 'valid ticket uses the marker reader' field_is "$TMP/clean tree" 5 'owner/repo#42'
check 'absent ticket is a dash' field_is "$TMP/dirty tree" 5 '-'
check 'invalid ticket is a dash' field_is "$TMP/no-upstream tree" 5 '-'
snapshot > "$TMP/after" || fail_setup 'post-report snapshot'
check 'indexes statuses owners and lock absence are unchanged' cmp -s "$TMP/before" "$TMP/after"
fixture_owner_action worktree_owner_release "$TMP/alive tree" || fail_setup release

mkdir "$TMP/bin" "$TMP/no-jq"
cat > "$TMP/bin/git" <<'SHIM'
#!/bin/bash
# Every call, including library calls, must carry all read-only settings.
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
PATH="$TMP/bin:$PATH" run_report "$TMP/main"
check 'every Git call disables optional locks FSMonitor and lazy fetching' field_is "$TMP/clean tree" 4 preserved
check 'guarded calls include owner library calls' field_is "$TMP/clean tree" 3 none
check 'guarded calls include ticket metadata reads' field_is "$TMP/clean tree" 5 'owner/repo#42'
for mode in status-error count-error bad-count; do
  REPORT_TEST_MODE="$mode" PATH="$TMP/bin:$PATH" run_report "$TMP/main"
  case "$mode" in status-error) expected='unknown:checkout unknown' ;; *) expected='unknown:commits unknown' ;; esac
  check "$mode produces unknown work" field_is "$TMP/clean tree" 4 "$expected"
  check "$mode exits zero without stderr" test "$REPORT_RC:$(cat "$TMP/stderr")" = '0:'
done
REPORT_TEST_MODE=tab-branch PATH="$TMP/bin:$PATH" run_report "$TMP/main"
check 'branch tab is sanitized' field_is "$TMP/clean tree" 2 'odd?branch'
check 'unprintable branch makes work unknown' field_is "$TMP/clean tree" 4 'unknown:unprintable path'

# Git permits tabs, newlines, quotes and backslashes in worktree paths.
head_hash=$(git -C "$TMP/main" rev-parse HEAD)
forged_name="clean tree"$'\n'"HEAD $head_hash"$'\nbranch refs/heads/fake\n\n'
for name in $'tab\ttree' $'line\nbreak' 'quote"tree' 'back\slash' \
  $'clean tree\nHEAD fake' $'clean tree\nbare' "clean tree"$'\n'"HEAD $head_hash" \
  "$forged_name" $'empty\n\nline' $'trailing\n' 'relative tree'; do
  # Older Git ignores this configuration key and still exercises absolute paths.
  git -c worktree.useRelativePaths=true -C "$TMP/main" worktree add -q --detach "$TMP/$name" || fail_setup unusual-path
done
gitdir=$(git -C "$TMP/clean tree" rev-parse --absolute-git-dir)
backpointer=$(cat "$gitdir/gitdir")
printf '%s' "$backpointer" > "$gitdir/gitdir"
head_contents=$(cat "$gitdir/HEAD")
printf '%s' "$head_contents" > "$gitdir/HEAD"
for mode in modern old-git; do
  REPORT_TEST_MODE="$mode" PATH="$TMP/bin:$PATH" run_report "$TMP/main"
  check "$mode sanitizes a tab in the path" field_is "$TMP/tab?tree" 4 'unknown:unprintable path'
  check "$mode marks a newline path unreadable" field_is "$TMP/line?break" 4 'unknown:unprintable path'
  check "$mode preserves double quotes in a path" field_is "$TMP/quote\"tree" 4 preserved
  check "$mode preserves backslashes in a path" field_is "$TMP/back\slash" 4 preserved
  check "$mode retains a HEAD-like path continuation" field_is "$TMP/clean tree?HEAD fake" 4 'unknown:unprintable path'
  check "$mode retains a bare-like path continuation" field_is "$TMP/clean tree?bare" 4 'unknown:unprintable path'
  check "$mode retains a full HEAD hash in the path" field_is "$TMP/clean tree?HEAD $head_hash" 4 'unknown:unprintable path'
  check "$mode retains forged metadata within a path" field_is "$TMP/${forged_name//$'\n'/?}" 4 'unknown:unprintable path'
  check "$mode retains an empty line within a path" field_is "$TMP/empty??line" 4 'unknown:unprintable path'
  check "$mode retains a trailing newline in the path" field_is "$TMP/trailing?" 4 'unknown:unprintable path'
  check "$mode handles relative administrative backpointers when supported" field_is "$TMP/relative tree" 4 preserved
  check "$mode accepts a backpointer without a final newline" field_is "$TMP/clean tree" 4 preserved
  check "$mode accepts a symbolic HEAD without a final newline" field_is "$TMP/clean tree" 2 clean
  check "$mode does not duplicate a clean prefix" field_is "$TMP/clean tree" 4 preserved
  check "$mode keeps five fields per row" awk -F '\t' 'NF != 5 { bad++ } END { exit bad != 0 }' "$TMP/report"
done
run_report "$TMP/clean tree"
check 'invoking from a linked worktree still omits main' test "$(wc -l < "$TMP/report" | tr -d ' ')" = 21
REPORT_TEST_MODE=old-git PATH="$TMP/bin:$PATH" run_report "$TMP/relative tree"
check 'legacy inventory resolves common metadata from a linked worktree' field_is "$TMP/clean tree" 4 preserved

# A minimal PATH omits jq without relying on its installation location.
for dep in git dirname; do
  if [ "$dep" = git ]; then target=$REAL_GIT; else target=$(command -v "$dep"); fi
  ln -s "$target" "$TMP/no-jq/$dep"
done
PATH="$TMP/no-jq" run_report "$TMP/main"
check 'missing jq exits zero without stderr' test "$REPORT_RC:$(cat "$TMP/stderr")" = '0:'
check 'missing jq makes every owner unknown' awk -F '\t' 'NR > 1 { n++; if ($3 != "unknown") bad++ } END { exit !(n == 20 && !bad) }' "$TMP/report"

mkdir -p "$TMP/no-library/.claude/skills/status" "$TMP/no-library/.claude/hooks"
cp "$REPORT" "$TMP/no-library/.claude/skills/status/worktree-report.sh"
cp "$ROOT/.claude/hooks/_lib-active-ticket.sh" "$TMP/no-library/.claude/hooks/"
REPORT_ORIGINAL=$REPORT
REPORT="$TMP/no-library/.claude/skills/status/worktree-report.sh"
run_report "$TMP/main"
check 'missing owner library makes owners unknown' awk -F '\t' 'NR > 1 { n++; if ($3 != "unknown") bad++ } END { exit !(n == 20 && !bad) }' "$TMP/report"
check 'missing owner library exits zero without stderr' test "$REPORT_RC:$(cat "$TMP/stderr")" = '0:'
REPORT=$REPORT_ORIGINAL

# Stale registrations must never borrow evidence from a replacement repository.
git -C "$TMP/main" worktree add -q -b replaced "$TMP/replaced tree" || fail_setup replaced
git -C "$TMP/main" worktree add -q -b locked "$TMP/locked tree" || fail_setup locked
git -C "$TMP/main" worktree lock "$TMP/locked tree" || fail_setup lock
mv "$TMP/replaced tree" "$TMP/original checkout" || fail_setup replaced
git -c init.defaultBranch=main init -q "$TMP/unrelated-main" || fail_setup replacement
printf 'unrelated\n' > "$TMP/unrelated-main/tracked"
git -C "$TMP/unrelated-main" add tracked || fail_setup replacement
git -C "$TMP/unrelated-main" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c commit.gpgsign=false commit -qm unrelated || fail_setup replacement
git init --bare -q "$TMP/unrelated.git" || fail_setup replacement
git -C "$TMP/unrelated-main" remote add origin "$TMP/unrelated.git" || fail_setup replacement
git -C "$TMP/unrelated-main" push -q origin main || fail_setup replacement
git -C "$TMP/unrelated-main" worktree add -q -b unrelated "$TMP/replaced tree" || fail_setup replacement
fixture_owner_action worktree_owner_acquire "$TMP/replaced tree" || fail_setup replacement-owner
fixture_owner_action worktree_owner_release "$TMP/replaced tree" || fail_setup replacement-owner
gitdir=$(git -C "$TMP/replaced tree" rev-parse --absolute-git-dir) || fail_setup replacement
printf 'repo=unrelated/repo\nnumber=99\n' > "$gitdir/apexyard-ticket"
mv "$TMP/locked tree/.git" "$TMP/locked-gitfile" || fail_setup missing-gitfile
for mode in modern old-git; do
  REPORT_TEST_MODE="$mode" PATH="$TMP/bin:$PATH" run_report "$TMP/main"
  for name in replaced locked; do
    check "$mode $name registration retains its branch" field_is "$TMP/$name tree" 2 "$name"
    check "$mode $name registration has unknown owner" field_is "$TMP/$name tree" 3 unknown
    check "$mode $name registration has unavailable work" field_is "$TMP/$name tree" 4 'unknown:path unavailable'
    check "$mode $name registration has no ticket" field_is "$TMP/$name tree" 5 '-'
  done
  check "$mode unavailable checkout exits zero without stderr" test "$REPORT_RC:$(cat "$TMP/stderr")" = '0:'
done

# A prunable checkout without .git must not discover its parent repository.
parent_tree="$TMP/replaced tree"
prunable_tree="$parent_tree/prunable tree"
git -C "$TMP/main" worktree add -q -b prunable "$prunable_tree" || fail_setup prunable-parent
mv "$prunable_tree/.git" "$TMP/prunable-gitfile" || fail_setup prunable-parent
git -C "$parent_tree" add 'prunable tree/tracked' || fail_setup prunable-parent
git -C "$parent_tree" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c commit.gpgsign=false commit -qm parent || fail_setup prunable-parent
git -C "$parent_tree" push -q origin unrelated || fail_setup prunable-parent
parent_gitdir=$(git -C "$parent_tree" rev-parse --absolute-git-dir) || fail_setup prunable-parent
printf 'repo=parent/repo\nnumber=88\n' > "$parent_gitdir/apexyard-ticket"
check 'prunable fixture discovers its parent git dir' test "$(git -C "$prunable_tree" rev-parse --absolute-git-dir)" -ef "$parent_gitdir"
check 'prunable fixture parent is clean' test -z "$(git -C "$prunable_tree" status --porcelain --untracked-files=normal)"
check 'prunable fixture parent has no unpushed commits' test "$(git -C "$prunable_tree" rev-list --count HEAD --not --remotes)" = 0
for mode in modern old-git; do
  REPORT_TEST_MODE="$mode" PATH="$TMP/bin:$PATH" run_report "$TMP/main"
  check "$mode prunable parent discovery retains its branch" field_is "$prunable_tree" 2 prunable
  check "$mode prunable parent discovery has unknown owner" field_is "$prunable_tree" 3 unknown
  check "$mode prunable parent discovery has unavailable work" field_is "$prunable_tree" 4 'unknown:path unavailable'
  check "$mode prunable parent discovery has no ticket" field_is "$prunable_tree" 5 '-'
  check "$mode prunable parent discovery exits zero without stderr" test "$REPORT_RC:$(cat "$TMP/stderr")" = '0:'
done

# Git resolves a symlink before a following .. in a relative backpointer.
mkdir -p "$TMP/physical/nested"
ln -s "$TMP/physical/nested" "$TMP/linked-parent"
relative_tree="$TMP/physical/relative symlink tree"
git -C "$TMP/main" worktree add -q -b relative-symlink "$relative_tree" || fail_setup relative-symlink
fixture_owner_action worktree_owner_acquire "$relative_tree" || fail_setup relative-owner
fixture_owner_action worktree_owner_release "$relative_tree" || fail_setup relative-owner
gitdir=$(git -C "$relative_tree" rev-parse --absolute-git-dir) || fail_setup relative-symlink
printf 'repo=relative/repo\nnumber=73\n' > "$gitdir/apexyard-ticket"
printf '../../../../linked-parent/../relative symlink tree/.git\n' > "$gitdir/gitdir"
for mode in modern old-git; do
  REPORT_TEST_MODE="$mode" PATH="$TMP/bin:$PATH" run_report "$TMP/main"
  check "$mode relative symlink retains its branch" field_is "$relative_tree" 2 relative-symlink
  check "$mode relative symlink reads its owner" field_is "$relative_tree" 3 released
  check "$mode relative symlink preserves pushed work" field_is "$relative_tree" 4 preserved
  check "$mode relative symlink reads its ticket" field_is "$relative_tree" 5 'relative/repo#73'
  check "$mode relative symlink exits zero without stderr" test "$REPORT_RC:$(cat "$TMP/stderr")" = '0:'
done

# A trailing newline must never resolve to the printable checkout's evidence.
plain_tree="$TMP/tree"
newline_tree="$plain_tree"$'\n'
git -C "$TMP/main" worktree add -q -b collision-plain "$plain_tree" || fail_setup collision
git -C "$TMP/main" worktree add -q -b collision-newline "$newline_tree" || fail_setup collision
fixture_owner_action worktree_owner_acquire "$plain_tree" || fail_setup collision-owner
plain_gitdir=$(git -C "$plain_tree" rev-parse --absolute-git-dir) || fail_setup collision
newline_gitdir=$(git -C "$newline_tree" rev-parse --absolute-git-dir) || fail_setup collision
# The owner API itself strips trailing newlines. Write the second record to
# its exact administrative directory, retaining all other valid owner fields.
jq --argjson pid "$gone_pid" '.owner.pid = $pid' "$plain_gitdir/apexyard-owner" > "$newline_gitdir/apexyard-owner"
printf 'repo=collision/plain\nnumber=61\n' > "$plain_gitdir/apexyard-ticket"
printf 'repo=collision/newline\nnumber=62\n' > "$newline_gitdir/apexyard-ticket"

# Trace the real owner reader, including its argument before path resolution.
# The Git shim traces ticket and work reads, and checkout identity resolution.
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
  check "$mode collision plain checkout keeps its branch" field_is "$plain_tree" 2 collision-plain
  check "$mode collision plain checkout keeps its owner" field_is "$plain_tree" 3 alive
  check "$mode collision plain checkout keeps its work" field_is "$plain_tree" 4 preserved
  check "$mode collision plain checkout keeps its ticket" field_is "$plain_tree" 5 'collision/plain#61'
  check "$mode collision newline checkout keeps its branch" field_is "$plain_tree?" 2 collision-newline
  check "$mode collision newline checkout has unknown owner" field_is "$plain_tree?" 3 unknown
  check "$mode collision newline checkout has unprintable work" field_is "$plain_tree?" 4 'unknown:unprintable path'
  check "$mode collision newline checkout has no ticket" field_is "$plain_tree?" 5 '-'
  check "$mode unprintable paths skip every lookup" test ! -s "$REPORT_TEST_LOOKUP_LOG"
  check "$mode collision exits zero without stderr" test "$REPORT_RC:$(cat "$TMP/stderr")" = '0:'
done
REPORT=$REPORT_ORIGINAL

# A configured filter can write even when optional Git locks are disabled.
printf 'tracked filter=sentinel\n' > "$TMP/clean tree/.gitattributes"
git -C "$TMP/clean tree" add .gitattributes || fail_setup attributes
git -C "$TMP/clean tree" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c commit.gpgsign=false commit -qm attributes || fail_setup attributes
cat > "$TMP/filter-command" <<'FILTER'
#!/bin/sh
printf 'filter ran\n' > "$0.sentinel"
cat
FILTER
chmod +x "$TMP/filter-command"
# Keep the original byte count so status hashes content instead of declaring
# it dirty from size alone, which would not execute the clean filter.
printf 'changed\n' > "$TMP/clean tree/tracked"
git -C "$TMP/clean tree" config filter.sentinel.clean "\"$TMP/filter-command\"" || fail_setup filter
git -C "$TMP/clean tree" status --porcelain --untracked-files=normal > "$TMP/filter-control-status" || fail_setup filter-control
[ -e "$TMP/filter-command.sentinel" ] || fail_setup 'clean filter control'
mv "$TMP/filter-command.sentinel" "$TMP/filter-control-sentinel" || fail_setup filter-control
run_report "$TMP/main"
check 'clean filter makes work unknown' field_is "$TMP/clean tree" 4 'unknown:filters configured'
check 'clean filter never writes its sentinel' test ! -e "$TMP/filter-command.sentinel"
git -C "$TMP/clean tree" config --unset filter.sentinel.clean || fail_setup filter
git -C "$TMP/clean tree" config filter.sentinel.process "\"$TMP/filter-command\"" || fail_setup filter
export REPORT_TEST_CONTENT_LOG="$TMP/content-commands"
REPORT_TEST_FORBID_CONTENT=1 PATH="$TMP/bin:$PATH" run_report "$TMP/main"
check 'process filter makes work unknown' field_is "$TMP/clean tree" 4 'unknown:filters configured'
check 'filters skip both status and revision count' test ! -e "$REPORT_TEST_CONTENT_LOG"
git -C "$TMP/clean tree" config --unset filter.sentinel.process || fail_setup filter

# Partial clones must not inspect contents, including on Git versions that
# predate GIT_NO_LAZY_FETCH. Inventory the real shared object directory.
git -C "$TMP/main" config extensions.partialClone origin || fail_setup partial
git -C "$TMP/main" config remote.origin.promisor true || fail_setup partial
object_dir=$(git -C "$TMP/main" rev-parse --git-path objects) || fail_setup objects
case "$object_dir" in /*) ;; *) object_dir="$TMP/main/$object_dir" ;; esac
object_snapshot() {
  find "$object_dir" -type f > "$TMP/object-list" || return 1
  LC_ALL=C sort "$TMP/object-list"
}
object_snapshot > "$TMP/objects-before" || fail_setup objects
for mode in modern old-git; do
  REPORT_TEST_FORBID_CONTENT=1 REPORT_TEST_MODE="$mode" PATH="$TMP/bin:$PATH" run_report "$TMP/main"
  check "$mode partial clone makes work unknown" field_is "$TMP/clean tree" 4 'unknown:partial clone'
  check "$mode partial clone skips status and revision count" test ! -e "$REPORT_TEST_CONTENT_LOG"
  object_snapshot > "$TMP/objects-after" || fail_setup objects
  check "$mode partial clone creates no object or pack files" cmp -s "$TMP/objects-before" "$TMP/objects-after"
done
git -C "$TMP/main" config --unset extensions.partialClone || fail_setup partial
git -C "$TMP/main" config remote.origin.promisor yes || fail_setup partial
REPORT_TEST_FORBID_CONTENT=1 PATH="$TMP/bin:$PATH" run_report "$TMP/main"
check 'a true promisor alone identifies a partial clone' field_is "$TMP/clean tree" 4 'unknown:partial clone'
check 'a true promisor alone skips content inspection' test ! -e "$REPORT_TEST_CONTENT_LOG"
git -C "$TMP/main" config --unset remote.origin.promisor || fail_setup partial
git -C "$TMP/main" config extensions.partialClone origin || fail_setup partial
REPORT_TEST_FORBID_CONTENT=1 PATH="$TMP/bin:$PATH" run_report "$TMP/main"
check 'partialClone alone identifies a partial clone' field_is "$TMP/clean tree" 4 'unknown:partial clone'
check 'partialClone alone skips content inspection' test ! -e "$REPORT_TEST_CONTENT_LOG"

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
