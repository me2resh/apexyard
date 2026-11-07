#!/bin/bash
# Overrides run in subshells. External fixtures also exercise fresh-shell discovery.
# shellcheck disable=SC2016,SC2329
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/worktree-owner.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
LIB=${WORKTREE_OWNER_LIB:-$ROOT/.claude/hooks/_lib-worktree-owner.sh}
for dependency in jq git; do command -v "$dependency" >/dev/null || exit 1; done
[ -f "$LIB" ] || { printf 'FAIL: owner library is missing\n'; exit 1; }
# shellcheck source=/dev/null
. "$LIB"
PASS=0 FAIL=0
check() {
  local label=$1; shift
  if "$@" > "$TMP/check-output" 2>&1; then printf 'PASS: %s\n' "$label"; PASS=$((PASS + 1))
  else printf 'FAIL: %s\n' "$label"; sed 's/^/FAIL: /' "$TMP/check-output"; FAIL=$((FAIL + 1)); fi
}
rejects() { ! "$@"; }
result() { local expected=$1 code=$2 output rc=0; shift 2; output=$("$@") || rc=$?; [ "$output:$rc" = "$expected:$code" ]; }
process_result() { local expected=$1 code=$2; shift 2; result "$expected" "$code" _wto_process_state "$@"; }
status_result() { local expected=$1 code=$2; shift 2; result "$expected" "$code" worktree_owner_status "$@"; }
lock_state() { local owner; owner=$(_wto_read_lock_owner "$1") || { printf 'unknown\n'; return 2; }; _wto_lock_identity_state "$owner"; }
record_matches() { jq -e "$1" "$RECORD" >/dev/null; }
same_json() { [ "$(printf '%s\n' "$1" | jq -Sc .)" = "$(printf '%s\n' "$2" | jq -Sc .)" ]; }
mutate() { printf '%s\n' "$owned" | jq -c --arg start "$wrong_start" --argjson pid "$gone_pid" "$1" > "$RECORD"; }
writes_refused() { local action; for action in "$@"; do ! "worktree_owner_$action" "$WORKTREE" || return 1; done; }
preserved() { cmp -s "$TMP/before" "$RECORD"; }
refused_record() { cp "$RECORD" "$TMP/before" && status_result "$1" "$2" "$WORKTREE" && writes_refused acquire renew release && preserved; }
malformed_record() { cp "$RECORD" "$TMP/before" && status_result unknown 2 "$WORKTREE" && writes_refused acquire renew release && ! worktree_owner_force_release "$WORKTREE" 3 && preserved; }
make_worktree() {
  REPO=$(mktemp -d "$TMP/repository.XXXXXX") || return 1; WORKTREE="$REPO/linked tree"
  git -c init.defaultBranch=main init -q "$REPO/main" &&
    git -C "$REPO/main" -c user.name=Fixture -c user.email=fixture@example.invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm fixture --allow-empty &&
    git -C "$REPO/main" -c core.hooksPath=/dev/null worktree add -q -b fixture "$WORKTREE" || return 1
  GITDIR=$(git -C "$WORKTREE" rev-parse --absolute-git-dir) || return 1; RECORD="$GITDIR/apexyard-owner"
}
mkdir "$TMP/bin"
cat > "$TMP/bin/ps" <<'SCRIPT'
#!/bin/bash
[ "${OWNER_TEST_PS_FAILURE:-}" != 1 ] || exit 1
case "${2:-}" in
  ppid=,comm=)
    if [ "${OWNER_TEST_NO_ANCESTOR:-}" = 1 ]; then
      if [ "$4" = 1 ]; then printf ' 0 /sbin/init\n'; else printf ' 1 /bin/bash\n'; fi
    elif [ "$4" = "$OWNER_TEST_PID" ]; then printf ' 1 %s\n' "${OWNER_TEST_CLI:-/opt/claude/versions/9.8.7}"
    else printf ' %s /bin/bash\n' "$OWNER_TEST_PID"; fi ;;
  lstart=) [ "${OWNER_TEST_EMPTY_START:-}" != 1 ] || { printf ' \t \n'; exit 0; }
    if [ "${TZ:-}" = UTC0 ]; then printf ' Sat Oct 31 10:00:00 2026 \n'; else printf ' Sat Oct 31 05:00:00 2026 \n'; fi ;;
  args=) printf '%s\n' "${OWNER_TEST_ARGS:-node /opt/node_modules/@anthropic-ai/claude-code/cli.js --resume}" ;;
  *) exit 1 ;;
esac
SCRIPT
cat > "$TMP/bin/sysctl" <<'SCRIPT'
#!/bin/sh
if [ -n "${OWNER_TEST_BOOT:-}" ]; then printf '%s\n' "$OWNER_TEST_BOOT"
else printf '{ sec = 123, usec = 456 } Sat Oct 31 10:00:00 2026\n'; fi
SCRIPT
chmod +x "$TMP/bin/ps" "$TMP/bin/sysctl"
export OWNER_TEST_LIB="$LIB" OWNER_TEST_PID="$$"
identity_matches() {
  local expression=$1 output; shift
  output=$(env PATH="$TMP/bin:$PATH" "$@" "$BASH" -uc '. "$OWNER_TEST_LIB"; worktree_owner_identity') || return 1
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 1 ] &&
    [ "$(printf '%s\n' "$output" | jq -c .)" = "$output" ] &&
    printf '%s\n' "$output" | jq -e "$expression" >/dev/null
}
complete='(keys | sort) == ["boot_id","harness","pid","pid_start","session_id"] and .harness == "claude-code" and .pid == '
complete="$complete$$ and .pid_start == \"UTC Sat Oct 31 10:00:00 2026\" and (.boot_id | type == \"string\" and length > 0)"
session_only='(keys | sort) == ["boot_id","harness","pid","pid_start","session_id"] and .harness == null and .pid == null and .pid_start == null and .boot_id == null'
check 'identity: session precedence and complete compact JSON' identity_matches "$complete and .session_id == \"claude-session\"" CLAUDE_CODE_SESSION_ID=claude-session APEXYARD_SESSION_ID=fallback-session
check 'identity: UTC capture' identity_matches "$complete" TZ=EST5
check 'identity: fallback session' identity_matches "$complete and .session_id == \"fallback-session\"" CLAUDE_CODE_SESSION_ID= APEXYARD_SESSION_ID=fallback-session
check 'identity: empty session' identity_matches "$complete and .session_id == \"\"" CLAUDE_CODE_SESSION_ID= APEXYARD_SESSION_ID=
check 'identity: unset sessions under nounset' env PATH="$TMP/bin:$PATH" "$BASH" -uc 'unset CLAUDE_CODE_SESSION_ID APEXYARD_SESSION_ID; . "$OWNER_TEST_LIB"; identity=$(worktree_owner_identity) || exit 1; test "$(printf "%s\n" "$identity" | jq -r .session_id)" = ""'
for cli in claude 9.8.7; do check "identity: executable $cli" identity_matches "$complete" OWNER_TEST_CLI="$cli" OWNER_TEST_ARGS='/opt/claude/versions/9.8.7 --resume'; done
check 'identity: node package executable' identity_matches "$complete" OWNER_TEST_CLI=/usr/bin/node
for args in 'node /tmp/unrelated.js' 'node wrapper.js /opt/node_modules/@anthropic-ai/claude-code/cli.js'; do check "identity: unrelated executable $args" identity_matches "$session_only" OWNER_TEST_CLI=/usr/bin/node OWNER_TEST_ARGS="$args"; done
check 'identity: missing ancestor retains session' identity_matches "$session_only and .session_id == \"retained-session\"" OWNER_TEST_NO_ANCESTOR=1 CLAUDE_CODE_SESSION_ID=retained-session
check 'identity: failed inspection' identity_matches "$session_only" OWNER_TEST_PS_FAILURE=1
check 'identity: empty start yields session only' identity_matches "$session_only" OWNER_TEST_EMPTY_START=1
check 'identity: ancestor harness and PID' env PATH="$TMP/bin:$PATH" "$BASH" -c '. "$OWNER_TEST_LIB"; test "$(_wto_harness_ancestor)" = "claude-code $OWNER_TEST_PID"'
check 'identity: command shell owns lock' env PATH="$TMP/bin:$PATH" CLAUDE_CODE_SESSION_ID=command-session "$BASH" -c '. "$OWNER_TEST_LIB"; _wto_operation_identity identity && test "${identity%%|*}" = "$$" && test "$$" != "$OWNER_TEST_PID"'
unavailable_identity() (
  local mode=$1 rc expected=2 action
  make_worktree || return 1
  if [ "$mode" = ps ]; then ps() { return 1; }
  elif [ "$mode" = empty-start ]; then ps() { return 0; }
  else
    _wto_pid_start() { printf 'UTC Sat Oct 31 10:00:00 2026\n'; }
    _wto_host_boot_id() { printf 'unknown-boot\n'; }
    if [ "$mode" = empty-boot ]; then _wto_host_boot_id() { :; }; fi
    if [ "$mode" = invalid-session ]; then
      export CLAUDE_CODE_SESSION_ID='invalid|session'
      _wto_host_boot_id() { printf 'fixture-boot\n'; }
      expected=1
    fi
  fi
  for action in acquire renew release; do
    rc=0
    "worktree_owner_$action" "$WORKTREE" || rc=$?
    [ "$rc" -eq "$expected" ] && [ ! -e "$RECORD" ] && [ ! -e "$GITDIR/apexyard-owner.lock" ] || return 1
    expected=1
  done
)
for mode in ps empty-start no-boot empty-boot; do check "identity unavailable: $mode acquire=2 renew=1 release=1 without state" unavailable_identity "$mode"; done
check 'acquire: invalid session returns 1 without state' unavailable_identity invalid-session
pid_temp_failure() (
  local mode=$1 rc=0 candidate directory="$TMP/pid-$1"
  make_worktree && mkdir "$directory" || return 1
  export TMPDIR="$directory"
  # Exercise the Bash 3.2 fallback under newer shells too.
  unset BASHPID
  mktemp() {
    case "$1" in */apexyard-owner-pid.*) [ "$mode" != create ] || return 1 ;; esac
    command mktemp "$@"
  }
  rm() {
    case "$*" in *apexyard-owner-pid.*) [ "$mode" != cleanup ] || return 1 ;; esac
    command rm "$@"
  }
  sh() { [ "$mode" != write ] || return 1; command sh "$@"; }
  worktree_owner_acquire "$WORKTREE" || rc=$?
  [ "$rc" -eq 1 ] && [ ! -e "$RECORD" ] && [ ! -e "$GITDIR/apexyard-owner.lock" ] || return 1
  for candidate in "$directory"/apexyard-owner-pid.*; do
    [ "$mode" = cleanup ] || [ ! -e "$candidate" ] || return 1
  done
  # A refused deletion can leave a file. Remove it once cleanup is possible.
  for candidate in "$directory"/apexyard-owner-pid.*; do command rm -f "$candidate" || return 1; done
  for candidate in "$directory"/apexyard-owner-pid.*; do [ ! -e "$candidate" ] || return 1; done
)
for mode in create write cleanup; do check "acquire: PID temp $mode failure returns 1" pid_temp_failure "$mode"; done
predictable_temp() (
  local directory="$TMP/predictable" file target
  mkdir "$directory" || return 1
  file="$directory/apexyard-owner" target="$directory/target"
  printf 'unchanged\n' > "$target"
  ln -s "$target" "$file.tmp.$$" || return 1
  _wto_write_json "$file" '{"value":1}' && [ ! -L "$file" ] &&
    [ -L "$file.tmp.$$" ] && [ "$(cat "$target")" = unchanged ] &&
    [ "$(cat "$file")" = '{"value":1}' ]
)
check 'atomic: predictable symlink is not followed' predictable_temp
export CLAUDE_CODE_SESSION_ID=owner-session
_wto_harness_ancestor() { printf 'claude-code %s\n' "$$"; }
owner_start=$(_wto_pid_start "$$") || owner_start=''; owner_boot=$(_wto_host_boot_id)
identity=$(worktree_owner_identity); operation_identity=''; _wto_operation_identity operation_identity || :
# Command substitution waits for this child, avoiding background-child trap races.
gone_pid=$(sh -c 'echo "$$"'); wrong_start='UTC Sat Oct 31 00:00:00 1998'
check 'process: usable start' test -n "$owner_start"; check 'process: usable boot' test "$owner_boot" != unknown-boot
for pid in '' 0 01 -1 abc '1 2' '1|2'; do check "process: invalid PID [$pid]" rejects _wto_valid_pid "$pid"; done
check 'process: positive PID' _wto_valid_pid "$$"
for state in live gone boot boot-legacy reused missing-start missing-boot unknown-boot group legacy-start; do
  pid=$$ start=$owner_start boot=$owner_boot expected=unknown code=2
  case "$state" in
    live) expected=alive; code=0 ;;
    gone) pid=$gone_pid; start=unused; expected=dead; code=1 ;;
    boot) boot=other-boot; expected=dead; code=1 ;;
    boot-legacy) boot=other-boot; start=unrecognised; expected=dead; code=1 ;;
    reused) start=$wrong_start; expected=dead; code=1 ;;
    missing-start) start='' ;; missing-boot) boot='' ;; unknown-boot) boot=unknown-boot ;;
    group) pid=0 ;; legacy-start) start='Sat Oct 31 10:00:00 2026' ;;
  esac
  check "process: $state" process_result "$expected" "$code" "$pid" "$start" "$boot"
done
cross_zone() (
  local start boot real_path=/bin:/usr/bin:/sbin:/usr/sbin
  start=$(PATH=$real_path TZ="$1" _wto_pid_start "$$") && boot=$(PATH=$real_path TZ="$1" _wto_host_boot_id) &&
    PATH=$real_path TZ="$2" process_result alive 0 "$$" "$start" "$boot"
)
for zones in 'UTC0 EST5' 'EST5 UTC0'; do check "process: real timezone $zones" cross_zone "${zones%% *}" "${zones#* }"; done
if [ ! -r /proc/sys/kernel/random/boot_id ]; then
  mac_boot() ( local boot; boot=$(PATH=/bin:/usr/bin:/sbin:/usr/sbin _wto_host_boot_id) && case "$boot" in *'}') return 0 ;; *) return 1 ;; esac; )
  check 'process: macOS boot strips local text' mac_boot
  check 'process: macOS incomplete boot is unknown' env PATH="$TMP/bin:$PATH" OWNER_TEST_BOOT=broken "$BASH" -c '. "$OWNER_TEST_LIB"; test "$(_wto_host_boot_id)" = unknown-boot'
fi
large_absent() { local output rc=0; output=$(_wto_process_state 99999999 unused "$owner_boot") || rc=$?; case "$output:$rc" in dead:1|unknown:2) return 0 ;; *) return 1 ;; esac; }
check 'process: large PID never alive' large_absent; check 'process: absent start lookup' test -z "$(_wto_pid_start "$gone_pid")"
failed_inspection() ( ps() { return 1; }; process_result unknown 2 "$$" "$owner_start" "$owner_boot"; )
check 'process: failed inspection stays unknown' failed_inspection
signal_denied() ( kill() { if [ "${1:-}" = -0 ] && [ "${2:-}" = 1 ]; then return 1; fi; builtin kill "$@"; }; "$@"; )
pid_one_start=$(_wto_pid_start 1) || pid_one_start=''
check 'process: init alive' process_result alive 0 1 "$pid_one_start" "$owner_boot"
check 'process: EPERM init alive' signal_denied process_result alive 0 1 "$pid_one_start" "$owner_boot"
check 'process: EPERM changed start dead' signal_denied process_result dead 1 1 "$wrong_start" "$owner_boot"
visibility_case() (
  local mode=$1 expected=unknown code=2 calls="$TMP/visibility-$1"
  ps() {
    printf '%s\n' "$*" >> "$calls"; [ "$#" -eq 4 ] && [ "$1" = -o ] && [ "$2" = pid= ] && [ "$3" = -p ] || return 2
    [ "$4" != "$$" ] || { printf '%s\n' "$$"; return 0; }
    case "$mode" in empty-zero) return 0 ;; empty-one) return 1 ;; self-only) printf '%s\n' "$$" ;; init-only) printf '1\n' ;;
      *) printf ' \t1\n\t%s  \n' "$$"; case "$mode" in stderr) printf 'ps: inspection failed\n' >&2 ;; newline) printf '\n' >&2 ;; error) return 2 ;; controls-one) return 1 ;; esac ;; esac
  }
  case "$mode" in controls-*) expected=dead; code=1 ;; esac
  process_result "$expected" "$code" "$gone_pid" unused "$owner_boot" && [ "$(cat "$calls")" = "-o pid= -p $gone_pid,$$,1" ]
)
for mode in empty-zero empty-one self-only init-only stderr newline error controls-zero controls-one; do check "visibility: $mode" visibility_case "$mode"; done
token_case() (
  local target=$1 visible=$2 expected=$3 code=$4 query=${5:-} calls="$TMP/query-$1-$3"
  kill() { return 1; }; _wto_host_boot_id() { printf 'token-boot\n'; }; _wto_pid_start() { printf '%s\n' "$wrong_start"; }
  ps() { printf '%s\n' "$*" > "$calls"; printf '%s\n' "$visible"; }
  process_result "$expected" "$code" "$target" "$wrong_start" token-boot && { [ -z "$query" ] || [ "$(cat "$calls")" = "-o pid= -p $query" ]; }
)
check 'visibility: whole target token' token_case 12 "$$ 1 123" dead 1
check 'visibility: whole shell token' token_case 12 "9$$9 1 12" unknown 2
for init in 11 10; do check "visibility: whole init token $init" token_case 12 "$$ $init 12" unknown 2; done
check 'visibility: deduplicated init query' token_case 1 "$$ 1" alive 0 "1,$$"
check 'visibility: deduplicated shell query' token_case "$$" "$$ 1" alive 0 "$$,1"
atomic_case() (
  local directory="$TMP/atomic" file="$TMP/atomic/data" candidate; mkdir "$directory" || return 1
  ! _wto_write_json "$file" '{broken' && [ ! -e "$file" ] && _wto_write_json "$file" '{"value":1}' && ! _wto_write_json "$file" '{broken' && [ "$(cat "$file")" = '{"value":1}' ] || return 1
  for candidate in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do [ ! -e "$candidate" ] && [ ! -L "$candidate" ] || [ "$candidate" = "$file" ] || return 1; done
)
check 'atomic: reject invalid JSON, preserve bytes and clean temporaries' atomic_case
lock_reader() (
  local mode=$1 directory="$TMP/reader-$1" output rc=0; mkdir "$directory" || return 1
  case "$mode" in
    missing) ;;
    symlink) printf '%s\n' "$operation_identity" > "$directory/target"; ln -s "$directory/target" "$directory/owner" ;;
    multiple) printf '%s\nother\n' "$operation_identity" > "$directory/owner" ;;
    extra-newline) printf '%s\n\n' "$operation_identity" > "$directory/owner" ;;
    single) printf '%s\n' "$operation_identity" > "$directory/owner" ;;
    unterminated) printf '%s' "$operation_identity" > "$directory/owner" ;;
    partial) printf '%s' "${operation_identity%?}" > "$directory/owner" ;;
    zero-byte) : > "$directory/owner" ;; newline-only) printf '\n' > "$directory/owner" ;;
  esac
  output=$(_wto_read_lock_owner "$directory") || rc=$?
  if [ "$mode" = single ]; then [ "$output:$rc" = "$operation_identity:0" ]; else [ -z "$output" ] && [ "$rc" -eq 1 ] && result unknown 2 lock_state "$directory"; fi
)
for mode in single unterminated zero-byte newline-only missing symlink multiple extra-newline partial; do check "lock reader: $mode" lock_reader "$mode"; done
lock_case() (
  local mode=$1 directory="$TMP/lock-$1" lock calls="$TMP/calls-$1" before="$TMP/owner-$1"
  local rc=0 count holder candidate operation_identity current_pid current_start
  _wto_self_pid current_pid >/dev/null && current_start=$(_wto_pid_start "$current_pid") &&
    _wto_operation_identity operation_identity || return 1
  mkdir "$directory" || return 1; lock="$directory/apexyard-owner.lock"
  case "$mode" in
    lifecycle)
      [ "$operation_identity" = "$current_pid|$current_start|owner-session|$owner_boot" ] &&
        _wto_lock "$directory" || return 1
      printf '%s\n' "$operation_identity" > "$before"; cmp -s "$before" "$lock/owner" || return 1
      for candidate in "$lock"/owner.*.tmp; do [ ! -e "$candidate" ] || return 1; done
      mkdir() { [ "$#" -ne 1 ] || [ "$1" != "$lock" ] || printf '.\n' >> "$calls"; command mkdir "$@"; }; sleep() { printf '.\n' >> "$calls-sleeps"; }
      ! _wto_lock "$directory" && [ "$(wc -l < "$calls" | tr -d ' ')" = 6 ] &&
        [ "$(wc -l < "$calls-sleeps" | tr -d ' ')" = 5 ] && cmp -s "$before" "$lock/owner" &&
        _wto_unlock "$directory" && [ ! -e "$lock" ] && _wto_lock "$directory" && _wto_unlock "$directory"
      return $? ;;
    publication-*)
      mv() { [ "$mode" != publication-published ] || printf '%s|%s|successor|%s\n' "$$" "$owner_start" "$owner_boot" > "$lock/owner"; return 1; }
      _wto_lock "$directory" || rc=$?; [ "$rc" -eq 1 ] || return 1
      for candidate in "$lock"/owner.*.tmp; do [ ! -e "$candidate" ] || return 1; done
      if [ "$mode" = publication-unpublished ]; then [ ! -e "$lock" ]; else [ "$(cat "$lock/owner")" = "$$|$owner_start|successor|$owner_boot" ]; fi; return $? ;;
  esac
  mkdir "$lock" || return 1; printf '%s|unused|old|%s\n' "$gone_pid" "$owner_boot" > "$lock/owner"
  case "$mode" in
    dead) _wto_lock "$directory" && [ "$(cat "$lock/owner")" = "$operation_identity" ] && _wto_unlock "$directory"; return $? ;;
    recheck|race)
      _wto_lock_identity_state() {
        count=0; [ ! -e "$calls" ] || count=$(cat "$calls"); count=$((count + 1)); printf '%s\n' "$count" > "$calls"
        if [ "$mode" = recheck ] && [ "$count" = 1 ]; then printf '%s\n' "$operation_identity" > "$lock/owner"; printf 'dead\n'; return 1; fi
        if [ "$mode" = race ] && [ "$count" -le 2 ]; then rm -rf "$lock"; mkdir "$lock" || return 2; printf '%s|%s|successor-%s|%s\n' "$$" "$owner_start" "$count" "$owner_boot" > "$lock/owner"; printf 'dead\n'; return 1; fi
        printf 'alive\n'
      } ;;
    guard) mkdir "$lock/reaping" || return 1 ;;
    missing) rm -f "$lock/owner" ;;
    partial) printf '%s' "${operation_identity%?}" > "$lock/owner" ;;
    incomplete) printf '%s||other|%s\n' "$$" "$owner_boot" > "$lock/owner" ;;
    missing-start) printf '%s||other|%s\n' "$gone_pid" "$owner_boot" > "$lock/owner" ;;
    missing-boot) printf '%s|unused|other|\n' "$gone_pid" > "$lock/owner" ;;
    extra) printf '%s|unused|other|%s|extra\n' "$$" "$owner_boot" > "$lock/owner" ;;
    init) printf '1|%s|foreign|%s\n' "$pid_one_start" "$owner_boot" > "$lock/owner" ;;
  esac
  [ ! -f "$lock/owner" ] || cp "$lock/owner" "$before"; _wto_lock "$directory" || rc=$?
  [ "$rc" -eq 1 ] && [ -d "$lock" ] || return 1
  case "$mode" in
    recheck) [ -d "$lock/reaping" ] && [ "$(cat "$lock/owner")" = "$operation_identity" ] ;;
    race) holder=$(cat "$lock/owner"); [ "$holder" = "$$|$owner_start|successor-1|$owner_boot" ] || [ "$holder" = "$$|$owner_start|successor-2|$owner_boot" ] ;;
    missing) [ ! -e "$lock/owner" ] ;;
    *) cmp -s "$before" "$lock/owner" || return 1
       case "$mode" in guard) [ -d "$lock/reaping" ] ;; init) [ ! -e "$lock/reaping" ] ;; *) result unknown 2 lock_state "$lock" && ! _wto_unlock "$directory" && [ ! -e "$lock/reaping" ] ;; esac ;;
  esac
)
for mode in lifecycle publication-unpublished publication-published dead recheck race guard missing partial incomplete missing-start missing-boot extra; do check "lock: $mode" lock_case "$mode"; done
check 'lock: EPERM init preserved' signal_denied lock_case init
callback_case() (
  local mode=$1 directory="$TMP/callback-$1" rc=0; mkdir "$directory" || return 1
  callback() {
    local pid recorded
    case "$mode" in failure) return 7 ;; exit) exit 9 ;;
      owner) _wto_self_pid pid >/dev/null &&
        IFS='|' read -r recorded _ < "$directory/apexyard-owner.lock/owner" &&
        [ "$pid" = "$recorded" ] && { [ "$pid" = "$$" ] || [ "$recorded" != "$$" ]; } ;;
    esac
  }
  _wto_with_lock "$directory" callback || rc=$?; case "$mode" in failure) [ "$rc" -eq 7 ] ;; exit) [ "$rc" -eq 9 ] ;; owner) [ "$rc" -eq 0 ] ;; esac && [ ! -e "$directory/apexyard-owner.lock" ]
)
for mode in failure exit owner; do check "callback: $mode and cleanup" callback_case "$mode"; done
wait_for() { local attempts=0; while [ "$attempts" -lt 100 ]; do "$@" && return 0; sleep 0.1; attempts=$((attempts + 1)); done; return 1; }
parent_death() (
  local child rc=0 log="$TMP/parent.log" directory="$TMP/parent"; mkdir "$directory" || return 1
  "$BASH" -c '. "$1"; writer() { printf "first-start\n" >> "$2"; sleep 3; printf "first-end\n" >> "$2"; }; _wto_with_lock "$2" writer "$2" "$3"' owner-parent "$LIB" "$directory" "$log" & child=$!
  if ! wait_for grep -qx first-start "$log"; then kill -9 "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :; return 1; fi
  kill -9 "$child" && { wait "$child" 2>/dev/null || :; } || return 1
  second() { printf 'second-in\n' >> "$log"; }; _wto_with_lock "$directory" second || rc=$?
  [ "$rc" -eq 1 ] && ! grep -qx second-in "$log" && wait_for grep -qx first-end "$log" && wait_for test ! -d "$directory/apexyard-owner.lock" && _wto_with_lock "$directory" second && grep -qx second-in "$log"
)
check 'callback: survives killed parent and excludes second writer' parent_death
make_worktree || exit 1
check 'record: initially none' status_result none 3 "$WORKTREE"
missing_force() { local rc=0; worktree_owner_force_release "$WORKTREE" 1 || rc=$?; [ "$rc" -eq 1 ] && [ ! -e "$RECORD" ] && [ ! -e "$GITDIR/apexyard-owner.lock" ]; }
check 'record: missing owner record cannot be force released' missing_force
lease_step() {
  local action=$1 generation=$2 ttl=$3 before after; before=$(date +%s)
  APEXYARD_WORKTREE_LEASE_TTL_SECONDS=$ttl "worktree_owner_$action" "$WORKTREE" || return 1; after=$(date +%s)
  record_matches ".version == 1 and .status == \"active\" and .generation == $generation and (.lease_heartbeat_at | type == \"number\" and floor == .) and (.lease_expires_at | type == \"number\" and floor == .) and .lease_heartbeat_at >= $before and .lease_heartbeat_at <= $after and .lease_expires_at == (.lease_heartbeat_at + $ttl)" && same_json "$(jq -c .owner "$RECORD")" "$identity" && status_result alive 0 "$WORKTREE"
}
check 'record: acquire one-hour lease and complete identity in Git directory' lease_step acquire 1 3600
check 'record: owner exists only in Git directory' test ! -e "$WORKTREE/apexyard-owner"
check 'record: renew advances generation and uses TTL' lease_step renew 2 120
check 'record: reacquire advances generation and uses TTL' lease_step acquire 3 180
owned=$(cat "$RECORD")
for field in pid pid_start session_id harness boot_id; do
  case "$field" in pid) filter='.owner.pid = $pid' ;; pid_start) filter='.owner.pid_start = $start' ;; *) filter=".owner.$field = \"different-$field\"" ;; esac
  mutate "$filter"; cp "$RECORD" "$TMP/before"; check "record: foreign $field rejects renew/release and preserves bytes" writes_refused renew release; check "record: foreign $field bytes" preserved
done
printf '%s\n' "$owned" > "$RECORD"
release_step() {
  worktree_owner_release "$WORKTREE" && record_matches '.status == "released" and .owner == null and .generation == 4' &&
    same_json "$(jq -c .released_by "$RECORD")" "$identity" && status_result released 4 "$WORKTREE" &&
    ! worktree_owner_release "$WORKTREE" && worktree_owner_acquire "$WORKTREE" &&
    record_matches '.generation == 5 and .status == "active"'
}
check 'record: release actor, released status and reacquisition generation' release_step
for ttl in invalid 0 -1 1.5 ''; do mutate '.'; cp "$RECORD" "$TMP/before"; APEXYARD_WORKTREE_LEASE_TTL_SECONDS=$ttl check "lease: invalid [$ttl] refuses acquire/renew and preserves bytes" writes_refused acquire renew; check "lease: invalid [$ttl] bytes" preserved; done
default_duration() ( unset APEXYARD_WORKTREE_LEASE_TTL_SECONDS; worktree_owner_renew "$WORKTREE" && record_matches '.lease_expires_at == (.lease_heartbeat_at + 3600)'; )
check 'lease: unset TTL defaults to one hour' default_duration
for scenario in live expired-live null-start unknown-boot legacy-start; do
  expected=alive code=0; case "$scenario" in live) filter='.' ;; expired-live) filter='.lease_expires_at = 0' ;; null-start) filter='.owner.pid_start = null'; expected=unknown; code=2 ;; unknown-boot) filter='.owner.boot_id = "unknown-boot"'; expected=unknown; code=2 ;; legacy-start) filter='.owner.pid_start = "Sat Oct 31 10:00:00 2026"'; expected=unknown; code=2 ;; esac
  mutate ".owner.session_id = \"foreign\" | ($filter)"; check "record: $scenario refuses takeover and preserves bytes" refused_record "$expected" "$code"
done
inspection_record() (
  local mode=$1; mutate '.owner.session_id = "foreign" | .lease_expires_at = 0'
  if [ "$mode" = init ] || [ "$mode" = visibility ]; then mutate ".owner.pid = 1 | .owner.pid_start = \"$pid_one_start\" | .owner.session_id = \"foreign\" | .lease_expires_at = 0"; fi
  ps() { case "$mode:${2:-}:${4:-}" in start:lstart=:"$$") return 1 ;; visibility:pid=:*) return 2 ;; esac; command ps "$@"; }
  _wto_with_lock "$GITDIR" true || return 1
  if [ "$mode" = init ]; then refused_record alive 0; else refused_record unknown 2; fi
)
check 'record: unreadable live start with valid lock refuses takeover' inspection_record start
check 'record: EPERM init survives expired lease' signal_denied inspection_record init
check 'record: foreign inspection failure with valid lock preserves bytes' signal_denied inspection_record visibility
mutate '.owner.pid = $pid | .owner.session_id = "gone" | .lease_expires_at = 10000000000'
check 'record: verified death precedes lease expiry' status_result dead 1 "$WORKTREE"
check 'record: dead takeover records caller and increments generation' lease_step acquire 4 3600
probe_case() ( local output=$1 code=$2; mutate '.owner.session_id = "foreign" | .lease_expires_at = 0'; cp "$RECORD" "$TMP/before"; _wto_process_state() { printf '%s\n' "$output"; return "$code"; }; ! worktree_owner_acquire "$WORKTREE" && preserved; )
for pair in 'dead 7' 'dead 0' 'unknown 1'; do check "record: inconsistent probe $pair refuses takeover" probe_case "${pair%% *}" "${pair#* }"; done
session_case() (
  local mode=$1; _wto_harness_ancestor() { return 1; }
  if [ "$mode" = own ]; then
    rm -f "$RECORD"
    worktree_owner_acquire "$WORKTREE" &&
      record_matches '.owner.session_id == "owner-session" and .owner.harness == null and .owner.pid == null and .owner.pid_start == null and .owner.boot_id == null' &&
      status_result unknown 2 "$WORKTREE" && worktree_owner_renew "$WORKTREE" &&
      worktree_owner_release "$WORKTREE" && record_matches '.generation == 3 and .status == "released"'
  else mutate '.owner = {session_id:"foreign",harness:null,pid:null,pid_start:null,boot_id:null} | .lease_expires_at = 0'; refused_record unknown 2; fi
)
for mode in own foreign; do check "record: session-only $mode" session_case "$mode"; done
force_match() (
  local before_heartbeat before_expires
  mutate '.owner = {session_id:"foreign-session",harness:null,pid:null,pid_start:null,boot_id:null}' &&
  before_heartbeat=$(jq -r '.lease_heartbeat_at' "$RECORD") &&
  before_expires=$(jq -r '.lease_expires_at' "$RECORD") &&
  worktree_owner_force_release "$WORKTREE" 3 &&
  record_matches '.status == "released" and .owner == null and .forced == true and .generation == 4' &&
  record_matches ".lease_heartbeat_at == $before_heartbeat and .lease_expires_at == $before_expires" &&
  same_json "$(jq -c .released_by "$RECORD")" "$identity" &&
  status_result released 4 "$WORKTREE" &&
  worktree_owner_acquire "$WORKTREE" && record_matches '.generation == 5 and (has("forced") | not)'
)
check 'record: force release matches shown generation and actor' force_match
force_refused() (
  local mode=$1 generation=3
  case "$mode" in stale) generation=2 ;; invalid) generation=invalid ;; missing) generation='' ;; overflow) generation=9007199254740991 ;; esac
  mutate '.owner = {session_id:"foreign-session",harness:null,pid:null,pid_start:null,boot_id:null}'
  case "$mode" in
    released) jq -c --argjson actor "$identity" '.status = "released" | .owner = null | .released_by = $actor' "$RECORD" > "$TMP/force-released" && cp "$TMP/force-released" "$RECORD" ;;
    alive) mutate '.' ;;
    malformed) printf '{broken\n' > "$RECORD" ;;
    overflow) mutate '.owner = {session_id:"foreign-session",harness:null,pid:null,pid_start:null,boot_id:null} | .generation = 9007199254740991' ;;
  esac
  cp "$RECORD" "$TMP/before" && ! worktree_owner_force_release "$WORKTREE" "$generation" && preserved
)
for scenario in stale invalid missing released alive malformed overflow; do check "record: force release refuses $scenario and preserves bytes" force_refused "$scenario"; done
force_race() (
  mutate '.owner = {session_id:"foreign-session",harness:null,pid:null,pid_start:null,boot_id:null}' &&
  _wto_with_lock() { shift; jq -c '.generation += 1' "$RECORD" > "$TMP/force-raced" && cp "$TMP/force-raced" "$RECORD" && "$@"; } &&
  ! worktree_owner_force_release "$WORKTREE" 3 && cmp -s "$TMP/force-raced" "$RECORD"
)
check 'record: force release checks generation inside lock' force_race
for filter in 'broken' 'multiple' '[]' '.version = 2' '.generation = 0' '.generation = "three"' '.status = "unexpected"' 'del(.owner.session_id)' '.owner = null' '.lease_heartbeat_at = "yesterday"' '.lease_expires_at = null'; do
  case "$filter" in broken) printf '{broken\n' > "$RECORD" ;; multiple) printf '%s\n%s\n' "$owned" "$owned" > "$RECORD" ;; *) mutate "$filter" ;; esac
  check "record: invalid schema $filter fails closed with bytes intact" malformed_record
done
identity_failure() (
  local generation
  mutate '.'; cp "$RECORD" "$TMP/before"; worktree_owner_identity() { return 1; }
  writes_refused acquire renew release && preserved || return 1
  mutate '.owner = {session_id:"foreign-session",harness:null,pid:null,pid_start:null,boot_id:null}'; cp "$RECORD" "$TMP/before"
  generation=$(jq -r '.generation' "$RECORD") || return 1
  ! worktree_owner_force_release "$WORKTREE" "$generation" && preserved
)
check 'record: failed identity refuses every write' identity_failure
eval "$(declare -f _wto_read_record | sed '1s/_wto_read_record/_saved_read_record/')"
snapshot_case() (
  local action=$1 reads="$TMP/reads-$1" replacement; mutate '.snapshot = "checked"'; replacement=$(printf '%s\n' "$owned" | jq -c '.generation = 91 | .snapshot = "unchecked" | .owner.session_id = "foreign"')
  _wto_read_record() { printf '.\n' >> "$reads"; _saved_read_record "$@" || return 1; printf '%s\n' "$replacement" > "$RECORD"; }
  _wto_update_locked "$GITDIR" "$action" "$identity" 120 &&
    [ "$(wc -l < "$reads" | tr -d ' ')" = 1 ] && record_matches '.generation == 4 and .snapshot == "checked"' &&
    same_json "$(jq -c 'if .status == "released" then .released_by else .owner end' "$RECORD")" "$identity"
)
for action in acquire renew release; do check "record: $action reads once and writes checked snapshot" snapshot_case "$action"; done
unsafe_writes() { local target=$1 action; for action in acquire renew release; do ! "worktree_owner_$action" "$target" || return 1; done; ! worktree_owner_force_release "$target" 3; }
check 'path: main checkout refuses writes' unsafe_writes "$REPO/main"; check 'path: main record absent' test ! -e "$REPO/main/.git/apexyard-owner"
mkdir "$TMP/not a repository"; check 'path: nonrepository refuses writes' unsafe_writes "$TMP/not a repository"
symlink_case() (
  local mode=$1 target="$TMP/target-$1" link current_identity
  make_worktree && _wto_operation_identity current_identity || return 1
  case "$mode" in
    record) printf '%s\n' "$owned" > "$target"; link=$RECORD ;;
    lock|unlock) mkdir "$target"; printf '%s\n' "$current_identity" > "$target/owner"; link="$GITDIR/apexyard-owner.lock" ;;
    gitdir) target="$GITDIR-real"; mv "$GITDIR" "$target"; link=$GITDIR ;;
  esac
  ln -s "$target" "$link" || return 1
  if [ "$mode" = unlock ]; then
    ! _wto_unlock "$GITDIR" && [ -L "$link" ] && [ "$(cat "$target/owner")" = "$current_identity" ]
  else
    unsafe_writes "$WORKTREE" && [ -L "$link" ] && case "$mode" in
      record) [ "$(cat "$target")" = "$owned" ] ;;
      lock) [ "$(cat "$target/owner")" = "$current_identity" ] && [ ! -e "$RECORD" ] ;;
      gitdir) [ ! -e "$target/apexyard-owner" ] && ! _wto_lock "$GITDIR" && [ ! -e "$target/apexyard-owner.lock" ] ;;
    esac
  fi
)
for mode in record lock gitdir unlock; do check "path: $mode symlink preserves link and target" symlink_case "$mode"; done
colliding_paths() (
  local plain newline tab plain_record newline_record
  make_worktree || return 1
  plain="$REPO/tree" newline="$REPO/tree"$'\n' tab="$REPO/tree"$'\t'
  git -C "$REPO/main" -c core.hooksPath=/dev/null worktree add -q -b plain "$plain" && git -C "$REPO/main" -c core.hooksPath=/dev/null worktree add -q -b newline "$newline" && git -C "$REPO/main" -c core.hooksPath=/dev/null worktree add -q -b tab "$tab" || return 1
  worktree_owner_acquire "$plain" || return 1
  plain_record=$(git -C "$plain" rev-parse --absolute-git-dir)/apexyard-owner
  newline_record=$(git -C "$newline" rev-parse --absolute-git-dir)/apexyard-owner
  [ "$plain_record" != "$newline_record" ] || return 1
  jq -c '.owner.session_id = "newline-owner"' "$plain_record" > "$newline_record" || return 1
  cp "$plain_record" "$TMP/path-before"; cp "$newline_record" "$TMP/newline-before"
  for WORKTREE in "$newline" "$tab"; do status_result unknown 2 "$WORKTREE" && unsafe_writes "$WORKTREE" || return 1; done
  status_result alive 0 "$plain" && cmp -s "$TMP/path-before" "$plain_record" &&
    cmp -s "$TMP/newline-before" "$newline_record" &&
    [ ! -e "$(git -C "$tab" rev-parse --absolute-git-dir)/apexyard-owner" ]
)
check 'path: actual newline and tab trees cannot alias a plain owner' colliding_paths
if [ "$FAIL" -ne 0 ]; then printf 'FAIL: %s checks failed and %s checks passed\n' "$FAIL" "$PASS"; exit 1; fi
printf 'PASS: %s checks passed\n' "$PASS"
