#!/bin/bash
# Overrides are called by the sourced library; quoted commands run in fresh shells.
# shellcheck disable=SC2016,SC2329
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/worktree-owner.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
LIB=${WORKTREE_OWNER_LIB:-$ROOT/.claude/hooks/_lib-worktree-owner.sh}
if [ ! -f "$LIB" ]; then
  printf 'FAIL: owner library is missing\n'
  exit 1
fi
for dependency in jq git; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf 'FAIL: required command is missing: %s\n' "$dependency"
    exit 1
  fi
done
# shellcheck source=/dev/null
. "$LIB"

PASS=0
FAIL=0
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
rejects() { ! "$@"; }
same_json() { [ "$(printf '%s\n' "$1" | jq -Sc .)" = "$(printf '%s\n' "$2" | jq -Sc .)" ]; }
process_result() {
  local expected=$1 expected_rc=$2 output rc=0
  shift 2
  output=$(_wto_process_state "$@") || rc=$?
  [ "$output" = "$expected" ] && [ "$rc" -eq "$expected_rc" ]
}
status_result() {
  local expected=$1 expected_rc=$2 output rc=0
  shift 2
  output=$(worktree_owner_status "$@") || rc=$?
  [ "$output" = "$expected" ] && [ "$rc" -eq "$expected_rc" ]
}
lock_owner_result() {
  local expected=$1 expected_rc=$2 output rc=0
  shift 2
  output=$(_wto_lock_owner_state "$@") || rc=$?
  [ "$output" = "$expected" ] && [ "$rc" -eq "$expected_rc" ]
}
record_matches() { jq -e "$1" "$RECORD" >/dev/null; }
make_worktree() {
  REPO=$(mktemp -d "$TMP/repository.XXXXXX") || return 1
  WORKTREE="$REPO/linked tree"
  git -c init.defaultBranch=main init -q "$REPO/main" || return 1
  git -C "$REPO/main" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm fixture --allow-empty || return 1
  git -C "$REPO/main" -c core.hooksPath=/dev/null worktree add -q -b fixture "$WORKTREE" || return 1
  GITDIR=$(git -C "$WORKTREE" rev-parse --absolute-git-dir) || return 1
  RECORD="$GITDIR/apexyard-owner"
}

# Use fresh shells so ancestor discovery cannot inherit a test function.
mkdir "$TMP/bin"
cat > "$TMP/bin/ps" <<'SCRIPT'
#!/bin/bash
[ "${OWNER_TEST_PS_FAILURE:-}" != 1 ] || exit 1
case "${2:-}" in
  ppid=,comm=)
    if [ "${OWNER_TEST_NO_ANCESTOR:-}" = 1 ]; then
      if [ "$4" = 1 ]; then printf ' 0 /sbin/init\n'; else printf ' 1 /bin/bash\n'; fi
    elif [ "$4" = "$OWNER_TEST_PID" ]; then
      printf ' 1 %s\n' "${OWNER_TEST_CLI:-/opt/claude/versions/9.8.7}"
    else
      printf ' %s /bin/bash\n' "$OWNER_TEST_PID"
    fi ;;
  lstart=) printf ' Sat Oct 31 10:00:00 2026 \n' ;;
  args=) printf '%s\n' "${OWNER_TEST_ARGS:-node /opt/node_modules/@anthropic-ai/claude-code/cli.js --resume}" ;;
  *) exit 1 ;;
esac
SCRIPT
cat > "$TMP/bin/sysctl" <<'SCRIPT'
#!/bin/sh
printf 'fixture-boot\n'
SCRIPT
chmod +x "$TMP/bin/ps" "$TMP/bin/sysctl"
export OWNER_TEST_LIB="$LIB" OWNER_TEST_PID="$$"
identity_fixture() {
  env PATH="$TMP/bin:$PATH" "$@" "$BASH" -uc '. "$OWNER_TEST_LIB"; worktree_owner_identity'
}
identity_matches() {
  local expression=$1 output
  shift
  output=$(identity_fixture "$@") || return 1
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 1 ] &&
    [ "$(printf '%s\n' "$output" | jq -c .)" = "$output" ] &&
    printf '%s\n' "$output" | jq -e "$expression" >/dev/null
}
complete_identity='(keys | sort) == ["boot_id","harness","pid","pid_start","session_id"] and .harness == "claude-code" and .pid == '
complete_identity="$complete_identity$$ and .pid_start == \"Sat Oct 31 10:00:00 2026\" and (.boot_id | type == \"string\" and length > 0)"
session_only='(keys | sort) == ["boot_id","harness","pid","pid_start","session_id"] and .harness == null and .pid == null and .pid_start == null and .boot_id == null'
check 'identity records all fields and gives the Claude session precedence' identity_matches \
  "$complete_identity and .session_id == \"claude-session\"" CLAUDE_CODE_SESSION_ID=claude-session APEXYARD_SESSION_ID=fallback-session
check 'identity falls back to the shared session variable' identity_matches \
  "$complete_identity and .session_id == \"fallback-session\"" CLAUDE_CODE_SESSION_ID= APEXYARD_SESSION_ID=fallback-session
check 'identity preserves an empty session' identity_matches \
  "$complete_identity and .session_id == \"\"" CLAUDE_CODE_SESSION_ID= APEXYARD_SESSION_ID=
check 'unset session variables remain empty under nounset' env PATH="$TMP/bin:$PATH" "$BASH" -uc \
  'unset CLAUDE_CODE_SESSION_ID APEXYARD_SESSION_ID; . "$OWNER_TEST_LIB"; identity=$(worktree_owner_identity) || exit 1; test "$(printf "%s\n" "$identity" | jq -r .session_id)" = ""'
check 'native command ancestor is recognized' identity_matches "$complete_identity" OWNER_TEST_CLI=claude
check 'node command ancestor is recognized' identity_matches "$complete_identity" OWNER_TEST_CLI=/usr/bin/node
check 'version command ancestor is recognized from its executable argument' identity_matches \
  "$complete_identity" OWNER_TEST_CLI=9.8.7 OWNER_TEST_ARGS='/opt/claude/versions/9.8.7 --resume'
check 'unrelated node process yields session only' identity_matches "$session_only" \
  OWNER_TEST_CLI=/usr/bin/node OWNER_TEST_ARGS='node /tmp/unrelated.js'
check 'a later Claude argument does not identify the executable' identity_matches "$session_only" \
  OWNER_TEST_CLI=/usr/bin/node OWNER_TEST_ARGS='node wrapper.js /opt/node_modules/@anthropic-ai/claude-code/cli.js'
check 'missing ancestor yields session only' identity_matches \
  "$session_only and .session_id == \"retained-session\"" OWNER_TEST_NO_ANCESTOR=1 CLAUDE_CODE_SESSION_ID=retained-session
check 'failed process inspection yields session only' identity_matches "$session_only" OWNER_TEST_PS_FAILURE=1
check 'ancestor discovery reports its harness and process' env PATH="$TMP/bin:$PATH" "$BASH" -c \
  '. "$OWNER_TEST_LIB"; test "$(_wto_harness_ancestor)" = "claude-code $OWNER_TEST_PID"'
check 'lock identity belongs to the command shell rather than its ancestor' env PATH="$TMP/bin:$PATH" \
  CLAUDE_CODE_SESSION_ID=command-session "$BASH" -c \
  '. "$OWNER_TEST_LIB"; identity=$(_wto_operation_identity) || exit 1; test "${identity%%|*}" = "$$" && test "$$" != "$OWNER_TEST_PID"'

export CLAUDE_CODE_SESSION_ID=owner-session
# A live shell supplies a stable owner while retaining real process inspection.
_wto_harness_ancestor() { printf 'claude-code %s\n' "$$"; }
owner_start=$(_wto_pid_start "$$") || owner_start=''
owner_boot=$(_wto_host_boot_id)
identity=$(worktree_owner_identity)
operation_identity=$(_wto_operation_identity) || operation_identity=''
# The command substitution reaps its child, so this PID belongs to no process.
# Killing a background job instead races bash 3.2: a child killed before it
# starts its command runs this shell's EXIT trap, which removes $TMP.
gone_pid=$(sh -c 'echo "$$"')
check 'current process has a start identity' test -n "$owner_start"
check 'host has a usable boot identity' test "$owner_boot" != unknown-boot
for invalid_pid in '' 0 01 -1 abc '1 2' '1|2'; do
  check 'invalid process identifiers are refused' rejects _wto_valid_pid "$invalid_pid"
done
check 'positive process identifiers are accepted' _wto_valid_pid "$$"
check 'current process identity is alive' process_result alive 0 "$$" "$owner_start" "$owner_boot"
check 'exited and waited process is dead' process_result dead 1 "$gone_pid" unused "$owner_boot"
large_process_not_alive() {
  local output rc=0
  output=$(_wto_process_state 99999999 unused "$owner_boot") || rc=$?
  case "$output:$rc" in dead:1|unknown:2) return 0 ;; *) return 1 ;; esac
}
check 'large absent process identifier is never alive' large_process_not_alive
check 'different boot identity is dead' process_result dead 1 "$$" "$owner_start" other-boot
check 'reused process identifier is dead' process_result dead 1 "$$" different-start "$owner_boot"
check 'missing start identity is unknown' process_result unknown 2 "$$" '' "$owner_boot"
check 'missing boot identity is unknown' process_result unknown 2 "$$" "$owner_start" ''
check 'unknown boot identity is unknown' process_result unknown 2 "$$" "$owner_start" unknown-boot
check 'process group identifier is unknown' process_result unknown 2 0 "$owner_start" "$owner_boot"
check 'gone process has no start identity' test -z "$(_wto_pid_start "$gone_pid")"
failed_process_inspection() (
  ps() { return 1; }
  process_result unknown 2 "$$" "$owner_start" "$owner_boot"
)
check 'failed process inspection cannot prove a live process dead' failed_process_inspection
pid_one_start=$(_wto_pid_start 1) || pid_one_start=''
signal_denied() (
  kill() {
    if [ "${1:-}" = -0 ] && [ "${2:-}" = 1 ]; then return 1; fi
    builtin kill "$@"
  }
  "$@"
)
check 'process one with its real identity is alive' process_result alive 0 1 "$pid_one_start" "$owner_boot"
check 'signal denial does not make process one dead' signal_denied process_result alive 0 1 "$pid_one_start" "$owner_boot"
check 'signal denial still detects a changed start identity' signal_denied process_result dead 1 1 wrong-start "$owner_boot"

visibility_case() (
  local mode=$1 expected=${2:-unknown} expected_rc=${3:-2} calls="$TMP/visibility-$1"
  ps() {
    printf '%s\n' "$*" >> "$calls"
    [ "$#" -eq 4 ] && [ "$1" = -o ] && [ "$2" = pid= ] && [ "$3" = -p ] || return 2
    if [ "$4" = "$$" ]; then printf '%s\n' "$$"; return 0; fi
    case "$mode" in
      empty-zero) return 0 ;;
      empty-one) return 1 ;;
      self-only) printf ' %s\n' "$$"; return 0 ;;
      init-only) printf ' 1\n'; return 0 ;;
      stderr|newline|error|controls-zero|controls-one)
        printf ' \t1\n\t%s  \n' "$$"
        case "$mode" in
          stderr) printf 'ps: inspection failed\n' >&2 ;;
          newline) printf '\n' >&2 ;;
          error) return 2 ;;
          controls-one) return 1 ;;
        esac ;;
      *) return 2 ;;
    esac
  }
  process_result "$expected" "$expected_rc" "$gone_pid" unused "$owner_boot" &&
    [ "$(cat "$calls")" = "-o pid= -p $gone_pid,$$,1" ]
)
check 'empty successful process output has unknown visibility' visibility_case empty-zero
check 'empty absent process output has unknown visibility' visibility_case empty-one
check 'seeing only the current shell has unknown visibility' visibility_case self-only
check 'seeing only process one has unknown visibility' visibility_case init-only
check 'process diagnostics prevent a dead conclusion' visibility_case stderr
check 'newline process diagnostics prevent a dead conclusion' visibility_case newline
check 'failed process command prevents a dead conclusion' visibility_case error
check 'both visibility controls establish a missing process at success' visibility_case controls-zero dead 1
check 'both visibility controls establish a missing process at absence' visibility_case controls-one dead 1
whole_process_case() (
  local visible=$1 expected=$2 expected_rc=$3
  kill() { return 1; }
  _wto_host_boot_id() { printf 'token-boot\n'; }
  _wto_pid_start() { printf 'token-start\n'; }
  ps() { printf '%s\n' "$visible"; }
  process_result "$expected" "$expected_rc" 12 token-start token-boot
)
check 'longer identifier does not match the target process' whole_process_case "$$ 1 123" dead 1
check 'longer identifier does not match the shell control' whole_process_case "9$$9 1 12" unknown 2
check 'process eleven does not match the init control' whole_process_case "$$ 11 12" unknown 2
check 'process ten does not match the init control' whole_process_case "$$ 10 12" unknown 2
unique_query_case() (
  local target=$1 other=$2 calls="$TMP/query-$1"
  kill() { return 1; }
  _wto_host_boot_id() { printf 'query-boot\n'; }
  _wto_pid_start() { printf 'query-start\n'; }
  ps() { printf '%s\n' "$*" >> "$calls"; printf ' %s\t1\n' "$$"; }
  process_result alive 0 "$target" query-start query-boot &&
    [ "$(cat "$calls")" = "-o pid= -p $target,$other" ]
)
check 'process one query contains each visibility control once' unique_query_case 1 "$$"
check 'current shell query contains each visibility control once' unique_query_case "$$" 1

mkdir "$TMP/atomic"
atomic="$TMP/atomic/data"
check 'invalid JSON cannot create a destination' rejects _wto_write_json "$atomic" '{broken'
check 'failed JSON creation leaves no destination' test ! -e "$atomic"
check 'valid JSON can be written' _wto_write_json "$atomic" '{"value":1}'
check 'invalid JSON cannot overwrite data' rejects _wto_write_json "$atomic" '{broken'
check 'failed JSON overwrite preserves the original bytes' test "$(cat "$atomic")" = '{"value":1}'
no_temporary_files() {
  local candidate
  for candidate in "$TMP/atomic"/* "$TMP/atomic"/.[!.]* "$TMP/atomic"/..?*; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    [ "$candidate" = "$atomic" ] || return 1
  done
}
check 'atomic writes clean temporary files' no_temporary_files

mkdir "$TMP/lock-directory"
lock_gitdir="$TMP/lock-directory"
lock="$lock_gitdir/apexyard-owner.lock"
check 'operation identity has all four lock fields' test "$operation_identity" = "$$|$owner_start|owner-session|$owner_boot"
check 'first lock acquisition succeeds' _wto_lock "$lock_gitdir"
check 'lock records the complete operation identity' test "$(cat "$lock/owner")" = "$operation_identity"
bounded_contention() (
  local attempt_log="$TMP/lock-attempts" sleep_log="$TMP/lock-sleeps"
  mkdir() {
    if [ "$#" -eq 1 ] && [ "$1" = "$lock" ]; then printf '.\n' >> "$attempt_log"; fi
    command mkdir "$@"
  }
  sleep() { printf '.\n' >> "$sleep_log"; }
  ! _wto_lock "$lock_gitdir" &&
    [ "$(wc -l < "$attempt_log" | tr -d ' ')" = 6 ] &&
    [ "$(wc -l < "$sleep_log" | tr -d ' ')" = 5 ] &&
    [ "$(cat "$lock/owner")" = "$operation_identity" ]
)
check 'held lock has six attempts and five short waits' bounded_contention
check 'unlock by the operation owner succeeds' _wto_unlock "$lock_gitdir"
check 'unlock removes the lock directory' test ! -e "$lock"
check 'lock can be acquired after unlock' _wto_lock "$lock_gitdir"
_wto_unlock "$lock_gitdir"
mkdir "$lock"
printf '%s|unused|old-session|%s\n' "$gone_pid" "$owner_boot" > "$lock/owner"
check 'dead operation lock can be reclaimed' _wto_lock "$lock_gitdir"
check 'reclaimed lock records its new operation owner' test "$(cat "$lock/owner")" = "$operation_identity"
_wto_unlock "$lock_gitdir"
mkdir "$lock"
check 'lock with an unpublished identity is preserved' rejects _wto_lock "$lock_gitdir"
check 'unpublished lock remains present' test -d "$lock"
printf '%s||other-session|%s\n' "$$" "$owner_boot" > "$lock/owner"
check 'lock with an incomplete owner is preserved' rejects _wto_lock "$lock_gitdir"
check 'different operation identity cannot unlock' rejects _wto_unlock "$lock_gitdir"
for missing in start boot; do
  case "$missing" in
    start) printf '%s||other-session|%s\n' "$gone_pid" "$owner_boot" > "$lock/owner" ;;
    boot) printf '%s|unused|other-session|\n' "$gone_pid" > "$lock/owner" ;;
  esac
  cp "$lock/owner" "$TMP/incomplete-lock-before"
  check "gone lock owner with missing $missing is unknown" lock_owner_result unknown 2 "$lock"
  check "gone lock owner with missing $missing is preserved" rejects _wto_lock "$lock_gitdir"
  check "gone lock owner with missing $missing retains its bytes" cmp -s "$TMP/incomplete-lock-before" "$lock/owner"
  check "gone lock owner with missing $missing is never reaped" test ! -e "$lock/reaping"
done
printf '%s|unused|extra-session|%s|extra\n' "$$" "$owner_boot" > "$lock/owner"
check 'extra lock identity field has unknown status' lock_owner_result unknown 2 "$lock"
check 'extra lock identity field fails closed' rejects _wto_lock "$lock_gitdir"
check 'extra lock identity field prevents unlock' rejects _wto_unlock "$lock_gitdir"
printf '%s\n' "$operation_identity" > "$lock/owner"
_wto_unlock "$lock_gitdir"
pid_one_lock_preserved() (
  local expected="1|$pid_one_start|foreign-session|$owner_boot"
  mkdir "$lock" || return 1
  printf '%s\n' "$expected" > "$lock/owner" || return 1
  ! _wto_lock "$lock_gitdir" && [ "$(cat "$lock/owner")" = "$expected" ] && [ ! -e "$lock/reaping" ]
)
check 'signal denied process one lock is never reclaimed' signal_denied pid_one_lock_preserved
rm -rf "$lock"
failed_command() { return 7; }
rc=0
_wto_with_lock "$lock_gitdir" failed_command || rc=$?
check 'locked command failure retains its status' test "$rc" -eq 7
check 'failed command releases its lock' test ! -e "$lock"
rc=0
_wto_with_lock "$lock_gitdir" exit 9 || rc=$?
check 'locked command explicit exit retains its status' test "$rc" -eq 9
check 'explicit exit releases its lock' test ! -e "$lock"

if ! make_worktree; then
  printf 'FAIL: could not create an isolated linked worktree\n'
  exit 1
fi
check 'linked worktree initially has no owner' status_result none 3 "$WORKTREE"
before=$(date +%s)
check 'first acquisition succeeds' worktree_owner_acquire "$WORKTREE"
after=$(date +%s)
check 'owner record lives in the linked Git directory' test -f "$RECORD"
check 'worktree files do not contain the owner record' test ! -e "$WORKTREE/apexyard-owner"
check 'initial owner record has the required version and generation' record_matches \
  '.version == 1 and .status == "active" and .generation == 1'
check 'record contains the full owner identity' same_json "$(jq -c .owner "$RECORD")" "$identity"
check 'default lease is one hour with integer epoch timestamps' record_matches \
  "(.lease_heartbeat_at | type == \"number\" and floor == .) and (.lease_expires_at | type == \"number\" and floor == .) and .lease_heartbeat_at >= $before and .lease_heartbeat_at <= $after and .lease_expires_at == (.lease_heartbeat_at + 3600)"
check 'acquired owner is alive' status_result alive 0 "$WORKTREE"
before=$(date +%s)
APEXYARD_WORKTREE_LEASE_TTL_SECONDS=120 check 'current owner can renew' worktree_owner_renew "$WORKTREE"
after=$(date +%s)
check 'renewal increments generation and uses the requested lease duration' record_matches \
  ".generation == 2 and .lease_heartbeat_at >= $before and .lease_heartbeat_at <= $after and .lease_expires_at == (.lease_heartbeat_at + 120)"
APEXYARD_WORKTREE_LEASE_TTL_SECONDS=180 check 'current owner can acquire again' worktree_owner_acquire "$WORKTREE"
check 'reacquisition refreshes the lease and increments generation' record_matches \
  '.generation == 3 and .lease_expires_at == (.lease_heartbeat_at + 180)'
owned=$(cat "$RECORD")
for field in pid pid_start session_id harness boot_id; do
  case "$field" in
    pid) filter=".owner.pid = $gone_pid" ;;
    pid_start) filter='.owner.pid_start = "different-start"' ;;
    session_id) filter='.owner.session_id = "different-session"' ;;
    harness) filter='.owner.harness = "different-harness"' ;;
    boot_id) filter='.owner.boot_id = "different-boot"' ;;
  esac
  printf '%s\n' "$owned" | jq -c "$filter" > "$RECORD"
  cp "$RECORD" "$TMP/foreign-before"
  check "renew rejects a different owner $field" rejects worktree_owner_renew "$WORKTREE"
  check "release rejects a different owner $field" rejects worktree_owner_release "$WORKTREE"
  check "rejected owner $field mutations preserve bytes" cmp -s "$TMP/foreign-before" "$RECORD"
done
printf '%s\n' "$owned" > "$RECORD"
check 'current owner can release' worktree_owner_release "$WORKTREE"
check 'release records its actor and increments generation' record_matches \
  '.status == "released" and .owner == null and .generation == 4'
check 'release retains the full releasing identity' same_json "$(jq -c .released_by "$RECORD")" "$identity"
check 'released status has its own return code' status_result released 4 "$WORKTREE"
check 'released owner cannot release again' rejects worktree_owner_release "$WORKTREE"
check 'released worktree can be acquired again' worktree_owner_acquire "$WORKTREE"
check 'acquiring a released record advances generation' record_matches '.generation == 5 and .status == "active"'

for ttl in invalid 0 -1 1.5 ''; do
  printf '%s\n' "$owned" > "$RECORD"
  cp "$RECORD" "$TMP/invalid-ttl-before"
  APEXYARD_WORKTREE_LEASE_TTL_SECONDS=$ttl check 'invalid lease duration refuses renewal' rejects worktree_owner_renew "$WORKTREE"
  APEXYARD_WORKTREE_LEASE_TTL_SECONDS=$ttl check 'invalid lease duration refuses acquisition' rejects worktree_owner_acquire "$WORKTREE"
  check 'invalid lease duration preserves record bytes' cmp -s "$TMP/invalid-ttl-before" "$RECORD"
done
default_duration() (
  unset APEXYARD_WORKTREE_LEASE_TTL_SECONDS
  worktree_owner_renew "$WORKTREE" && record_matches '.lease_expires_at == (.lease_heartbeat_at + 3600)'
)
check 'unset lease duration uses the one hour default' default_duration

for scenario in live expired-live unknown-start unknown-boot; do
  case "$scenario" in
    live) filter='.'; expected=alive; expected_rc=0 ;;
    expired-live) filter='.lease_expires_at = 0'; expected=alive; expected_rc=0 ;;
    unknown-start) filter='.owner.pid_start = null'; expected=unknown; expected_rc=2 ;;
    unknown-boot) filter='.owner.boot_id = "unknown-boot"'; expected=unknown; expected_rc=2 ;;
  esac
  printf '%s\n' "$owned" | jq -c '.owner.session_id = "foreign-session" | ('"$filter"')' > "$RECORD"
  cp "$RECORD" "$TMP/acquire-before"
  check "foreign owner status is preserved for $scenario" status_result "$expected" "$expected_rc" "$WORKTREE"
  check "foreign owner acquisition is refused for $scenario" rejects worktree_owner_acquire "$WORKTREE"
  check "foreign owner refusal preserves bytes for $scenario" cmp -s "$TMP/acquire-before" "$RECORD"
done
printf '%s\n' "$owned" | jq -c --argjson pid "$gone_pid" \
  '.owner.pid = $pid | .owner.session_id = "gone-session" | .lease_expires_at = 10000000000' > "$RECORD"
check 'verified dead owner has the dead status' status_result dead 1 "$WORKTREE"
check 'verified dead owner can be replaced before lease expiry' worktree_owner_acquire "$WORKTREE"
check 'dead owner replacement records the caller and increments generation' record_matches \
  ".generation == 4 and .owner.pid == $$ and .owner.session_id == \"owner-session\""
probe_error_refused() (
  local probe_text=$1 probe_rc=$2
  printf '%s\n' "$owned" | jq -c '.owner.session_id = "foreign-session" | .lease_expires_at = 0' > "$RECORD"
  cp "$RECORD" "$TMP/probe-before" || return 1
  _wto_process_state() { printf '%s\n' "$probe_text"; return "$probe_rc"; }
  ! worktree_owner_acquire "$WORKTREE" && cmp -s "$TMP/probe-before" "$RECORD"
)
check 'dead output with probe error cannot authorize takeover' probe_error_refused dead 7
check 'dead output with successful probe cannot authorize takeover' probe_error_refused dead 0
check 'unknown output with dead return code cannot authorize takeover' probe_error_refused unknown 1
pid_one_record_preserved() (
  printf '%s\n' "$owned" | jq -c --arg start "$pid_one_start" \
    '.owner.pid = 1 | .owner.pid_start = $start | .owner.session_id = "foreign-session" | .lease_expires_at = 0' > "$RECORD"
  cp "$RECORD" "$TMP/init-before" || return 1
  status_result alive 0 "$WORKTREE" && ! worktree_owner_acquire "$WORKTREE" && cmp -s "$TMP/init-before" "$RECORD"
)
check 'signal denied process one cannot lose ownership after lease expiry' signal_denied pid_one_record_preserved
foreign_inspection_failure_refused() (
  printf '%s\n' "$owned" | jq -c --arg start "$pid_one_start" \
    '.owner.pid = 1 | .owner.pid_start = $start | .owner.session_id = "foreign-session" | .lease_expires_at = 0' > "$RECORD"
  cp "$RECORD" "$TMP/inspection-before" || return 1
  kill() {
    if [ "${1:-}" = -0 ] && [ "${2:-}" = 1 ]; then return 1; fi
    builtin kill "$@"
  }
  ps() {
    if [ "${2:-}" = pid= ]; then return 2; fi
    command ps "$@"
  }
  _wto_lock "$GITDIR" && _wto_unlock "$GITDIR" || return 1
  status_result unknown 2 "$WORKTREE" && ! worktree_owner_acquire "$WORKTREE" &&
    cmp -s "$TMP/inspection-before" "$RECORD"
)
check 'foreign owner inspection failure preserves the record with a valid operation lock' foreign_inspection_failure_refused

session_only_owner() (
  _wto_harness_ancestor() { return 1; }
  rm -f "$RECORD"
  worktree_owner_acquire "$WORKTREE" &&
    record_matches '.owner.session_id == "owner-session" and .owner.harness == null and .owner.pid == null and .owner.pid_start == null and .owner.boot_id == null' &&
    status_result unknown 2 "$WORKTREE" &&
    worktree_owner_renew "$WORKTREE" &&
    worktree_owner_release "$WORKTREE" &&
    record_matches '.generation == 3 and .status == "released"'
)
check 'session only owner can renew and release its unknown identity' session_only_owner
session_only_foreign() (
  _wto_harness_ancestor() { return 1; }
  printf '%s\n' "$owned" | jq -c \
    '.owner = {session_id:"foreign-session",harness:null,pid:null,pid_start:null,boot_id:null} | .lease_expires_at = 0' > "$RECORD"
  cp "$RECORD" "$TMP/session-before" || return 1
  status_result unknown 2 "$WORKTREE" && ! worktree_owner_acquire "$WORKTREE" &&
    ! worktree_owner_renew "$WORKTREE" && ! worktree_owner_release "$WORKTREE" && cmp -s "$TMP/session-before" "$RECORD"
)
check 'foreign session only owner cannot be replaced or mutated' session_only_foreign

malformed_refused() {
  cp "$RECORD" "$TMP/malformed-before" || return 1
  status_result unknown 2 "$WORKTREE" && ! worktree_owner_acquire "$WORKTREE" &&
    ! worktree_owner_renew "$WORKTREE" && ! worktree_owner_release "$WORKTREE" &&
    cmp -s "$TMP/malformed-before" "$RECORD"
}
printf '{broken\n' > "$RECORD"
check 'invalid owner JSON fails closed and remains unchanged' malformed_refused
printf '%s\n%s\n' "$owned" "$owned" > "$RECORD"
check 'multiple owner JSON documents fail closed and remain unchanged' malformed_refused
for filter in '[]' '.version = 2' '.generation = 0' '.generation = "three"' \
  '.status = "unexpected"' 'del(.owner.session_id)' '.owner = null' \
  '.lease_heartbeat_at = "yesterday"' '.lease_expires_at = null'; do
  printf '%s\n' "$owned" | jq -c "$filter" > "$RECORD"
  check 'malformed owner schema fails closed and remains unchanged' malformed_refused
done
identity_failure_refused() (
  printf '%s\n' "$owned" > "$RECORD"
  cp "$RECORD" "$TMP/identity-before" || return 1
  worktree_owner_identity() { return 1; }
  ! worktree_owner_acquire "$WORKTREE" && ! worktree_owner_renew "$WORKTREE" &&
    ! worktree_owner_release "$WORKTREE" && cmp -s "$TMP/identity-before" "$RECORD"
)
check 'identity capture failure refuses every write' identity_failure_refused

unsafe_path_refused() {
  local target=$1
  ! worktree_owner_acquire "$target" && ! worktree_owner_renew "$target" && ! worktree_owner_release "$target"
}
check 'main checkout refuses ownership writes' unsafe_path_refused "$REPO/main"
check 'main checkout has no owner record' test ! -e "$REPO/main/.git/apexyard-owner"
mkdir "$TMP/not a repository"
check 'nonrepository refuses ownership writes' unsafe_path_refused "$TMP/not a repository"
record_symlink_refused() (
  printf '%s\n' "$owned" > "$TMP/record-target"
  rm -f "$RECORD"
  ln -s "$TMP/record-target" "$RECORD" || return 1
  unsafe_path_refused "$WORKTREE" && [ -L "$RECORD" ] &&
    [ "$(cat "$TMP/record-target")" = "$owned" ]
)
check 'symlink owner record refuses writes without changing its target' record_symlink_refused
lock_symlink_refused() (
  rm -f "$RECORD"
  mkdir "$TMP/lock-target" || return 1
  printf 'unchanged\n' > "$TMP/lock-target/sentinel"
  ln -s "$TMP/lock-target" "$GITDIR/apexyard-owner.lock" || return 1
  unsafe_path_refused "$WORKTREE" && [ -L "$GITDIR/apexyard-owner.lock" ] &&
    [ "$(cat "$TMP/lock-target/sentinel")" = unchanged ] && [ ! -e "$RECORD" ]
)
check 'symlink lock refuses writes without changing its target' lock_symlink_refused
gitdir_symlink_refused() (
  make_worktree || return 1
  mv "$GITDIR" "$GITDIR-real" || return 1
  ln -s "$GITDIR-real" "$GITDIR" || return 1
  unsafe_path_refused "$WORKTREE" && [ ! -e "$GITDIR-real/apexyard-owner" ] &&
    ! _wto_lock "$GITDIR" && [ ! -e "$GITDIR-real/apexyard-owner.lock" ]
)
check 'symlink linked Git directory refuses ownership and lock writes' gitdir_symlink_refused

if [ "$FAIL" -ne 0 ]; then
  printf 'FAIL: %s checks failed and %s checks passed\n' "$FAIL" "$PASS"
  exit 1
fi
printf 'PASS: %s checks passed\n' "$PASS"
