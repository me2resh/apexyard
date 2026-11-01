#!/bin/bash
# A linked worktree's owner record and lease live in its git dir, in
# the file named apexyard-owner, next to its ticket marker.
# Identity combines the AgDR-0250 session id with the optional harness table.
# Unknown is never dead. Lease expiry alone never permits a takeover.
# Location, identity and liveness decisions: AgDR-0284.

_wto_host_boot_id() {
  local boot=""
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    IFS= read -r boot < /proc/sys/kernel/random/boot_id || boot=""
  else
    boot=$(sysctl -n kern.boottime 2>/dev/null) || boot=""
    case "$boot" in
      *'}'*) boot="${boot%%\}*}}" ;;
      *) boot="" ;;
    esac
  fi
  printf '%s\n' "${boot:-unknown-boot}"
}

_wto_valid_pid() {
  case "${1:-}" in ''|0*|*[!0-9]*) return 1 ;; esac
}

_wto_pid_start() {
  local start
  _wto_valid_pid "${1:-}" || return 1
  start=$(TZ=UTC0 LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null) || return 1
  printf '%s\n' "$start" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

_wto_claude_code_matches() {
  local executable="$1" pid="$2" args
  # Native installs can expose a versioned executable in comm, while npm
  # installs expose node there and the Claude package's cli.js in args.
  case "$executable" in
    claude|*/claude|claude-code|*/claude-code) return 0 ;;
    */claude/versions/*)
      if [[ ${executable##*/} =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
        return 0
      fi ;;
    node|*/node|nodejs|*/nodejs)
      args=$(LC_ALL=C ps -o args= -p "$pid" 2>/dev/null) || return 2
      if [[ $args =~ ^[^[:space:]]+([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^[:space:]]*/@anthropic-ai/claude-code/cli\.js([[:space:]]|$) ]]; then
        return 0
      fi ;;
  esac
  # Linux comm can be a basename or a truncated native version number.
  args=$(LC_ALL=C ps -o args= -p "$pid" 2>/dev/null) || return 2
  if [[ $args =~ ^([^[:space:]]*/)?claude([[:space:]]|$) ]] ||
    [[ $args =~ ^[^[:space:]]*/claude/versions/[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?([[:space:]]|$) ]]; then
    return 0
  fi
  return 1
}

_wto_harness_ancestor() {
  local pid="$$" row parent executable harness rc depth=0 seen=' '
  while _wto_valid_pid "$pid" && [ "$depth" -lt 128 ]; do
    case "$seen" in *" $pid "*) return 1 ;; esac
    seen="$seen$pid "
    row=$(LC_ALL=C ps -o ppid=,comm= -p "$pid" 2>/dev/null) || return 1
    parent=${row%%[![:space:]]*}
    row=${row#"$parent"}
    parent=${row%%[[:space:]]*}
    executable=${row#"$parent"}
    executable="${executable#"${executable%%[![:space:]]*}"}"
    if [ "$pid" != "$$" ]; then
      # Per-harness matcher table: add another harness and its matcher here.
      # shellcheck disable=SC2043
      for harness in claude-code; do
        case "$harness" in
          claude-code)
            rc=0
            _wto_claude_code_matches "$executable" "$pid" || rc=$?
            if [ "$rc" -eq 0 ]; then
              printf '%s %s\n' "$harness" "$pid"
              return 0
            fi
            [ "$rc" -ne 2 ] || return 1 ;;
        esac
      done
    fi
    _wto_valid_pid "$parent" || return 1
    pid="$parent"
    depth=$((depth + 1))
  done
  return 1
}

_wto_session() {
  printf '%s\n' "${CLAUDE_CODE_SESSION_ID:-${APEXYARD_SESSION_ID:-}}"
}

worktree_owner_identity() {
  local session match harness pid start boot
  session=$(_wto_session)
  if match=$(_wto_harness_ancestor) &&
    harness=${match%% *} && pid=${match#* } && _wto_valid_pid "$pid" &&
    start=$(_wto_pid_start "$pid") && [ -n "$start" ]; then
    boot=$(_wto_host_boot_id)
    if [ -n "$boot" ] && [ "$boot" != unknown-boot ]; then
      jq -cn --arg session "$session" --arg harness "$harness" --argjson pid "$pid" \
        --arg start "$start" --arg boot "$boot" \
        '{session_id:$session,harness:$harness,pid:$pid,pid_start:$start,boot_id:$boot}'
      return "$?"
    fi
  fi
  jq -cn --arg session "$session" \
    '{session_id:$session,harness:null,pid:null,pid_start:null,boot_id:null}'
}

_wto_self_pid() {
  local self_pid="${BASHPID:-}" file
  if [ -z "$self_pid" ]; then
    file=$(mktemp "${TMPDIR:-/tmp}/apexyard-owner-pid.XXXXXX") || return 1
    # Run directly: command substitution would report its own short-lived child.
    if ! sh -c 'echo "$PPID"' > "$file" || ! IFS= read -r self_pid < "$file"; then
      rm -f "$file"
      return 1
    fi
    rm -f "$file" || return 1
  fi
  _wto_valid_pid "$self_pid" || return 1
  # An optional output variable avoids creating a command-substitution process.
  if [ "$#" -gt 0 ]; then printf -v "$1" '%s' "$self_pid" || return 1; fi
  printf '%s\n' "$self_pid"
}

_wto_operation_identity() {
  local pid start boot session
  _wto_self_pid pid >/dev/null || return 1
  session=$(_wto_session)
  start=$(_wto_pid_start "$pid") || return 1
  boot=$(_wto_host_boot_id)
  [ -n "$start" ] && [ -n "$boot" ] && [ "$boot" != unknown-boot ] || return 1
  case "$session$start$boot" in *'|'*|*$'\n'*) return 1 ;; esac
  # Lock and unlock call this directly, in the shell running the critical section.
  if [ "$#" -gt 0 ]; then
    printf -v "$1" '%s|%s|%s|%s' "$pid" "$start" "$session" "$boot"
  else
    printf '%s|%s|%s|%s\n' "$pid" "$start" "$session" "$boot"
  fi
}

_wto_process_state() {
  local pid="${1:-}" start="${2:-}" boot="${3:-}" current_boot current_start
  local visible_pids query_pids ps_stderr ps_rc=0
  if ! _wto_valid_pid "$pid"; then
    printf 'unknown\n'
    return 2
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    # Signal permission does not establish existence: EPERM can mean alive.
    query_pids="$pid"
    [ "$pid" = "$$" ] || query_pids="$query_pids,$$"
    [ "$pid" = 1 ] || [ "$$" = 1 ] || query_pids="$query_pids,1"
    # Capture stdout through fd 3 and stderr separately in this same call.
    # The sentinel preserves even newline-only diagnostics in the variable.
    if ! visible_pids=$(
      {
        ps_stderr=$(
          ps -o pid= -p "$query_pids" 2>&1 >&3
          ps_rc=$?
          printf '.'
          exit "$ps_rc"
        ) || ps_rc=$?
        [ "$ps_stderr" = . ] && [ "$ps_rc" -le 1 ]
      } 3>&1
    ); then
      printf 'unknown\n'
      return 2
    fi
    # Match complete whitespace-separated PID tokens, without glob expansion.
    visible_pids=" ${visible_pids//[[:space:]]/ } "
    case "$visible_pids" in *" $$ "*) ;; *) printf 'unknown\n'; return 2 ;; esac
    # PID 1 shows visibility beyond this shell's own processes.
    # It does not prove cross-user visibility when PID 1 shares our user,
    # for example when a shell runs as a container's init.
    case "$visible_pids" in *' 1 '*) ;; *) printf 'unknown\n'; return 2 ;; esac
    case "$visible_pids" in *" $pid "*) ;; *) printf 'dead\n'; return 1 ;; esac
  fi
  current_boot=$(_wto_host_boot_id)
  if [ -z "$boot" ] || [ "$boot" = unknown-boot ] || [ "$current_boot" = unknown-boot ]; then
    printf 'unknown\n'
    return 2
  fi
  if [ "$boot" != "$current_boot" ]; then
    printf 'dead\n'
    return 1
  fi
  if [ -z "$start" ] || ! current_start=$(_wto_pid_start "$pid") || [ -z "$current_start" ]; then
    printf 'unknown\n'
    return 2
  fi
  if [ "$start" != "$current_start" ]; then
    printf 'dead\n'
    return 1
  fi
  printf 'alive\n'
}

_wto_write_json() {
  local file="${1:-}" json="${2:-}" tmp
  [ -n "$file" ] || return 1
  tmp="$file.tmp.$$"
  if ! printf '%s\n' "$json" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! jq -e . "$tmp" >/dev/null 2>&1 || ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
}

_wto_safe_gitdir() {
  [ -n "${1:-}" ] && [ -d "$1" ] && [ ! -L "$1" ] &&
    [ ! -L "$1/apexyard-owner" ] && [ ! -L "$1/apexyard-owner.lock" ]
}

_wto_gitdir() (
  local tree gitdir common pointer vars var
  [ -n "${1:-}" ] || return 1
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  vars=$(git rev-parse --local-env-vars 2>/dev/null) || return 1
  for var in $vars; do
    case "$var" in GIT_*) case "$var" in *[!A-Z0-9_]*) ;; *) unset "$var" ;; esac ;; esac
  done
  tree=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || return 1
  [ ! -L "$tree/.git" ] || return 1
  if [ -f "$tree/.git" ]; then
    IFS= read -r pointer < "$tree/.git" || return 1
    case "$pointer" in gitdir:\ *) pointer=${pointer#gitdir: } ;; *) return 1 ;; esac
    case "$pointer" in /*) ;; *) pointer="$tree/$pointer" ;; esac
    [ ! -L "$pointer" ] || return 1
  fi
  gitdir=$(git -C "$tree" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  common=$(git -C "$tree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$gitdir" != "$common" ] && [ ! "$gitdir" -ef "$common" ] || return 1
  _wto_safe_gitdir "$gitdir" || return 1
  printf '%s\n' "$gitdir"
)

_wto_read_lock_owner() {
  local owner extra
  [ ! -L "$1/owner" ] || return 1
  {
    IFS= read -r owner || return 1
    [ -n "$owner" ] || return 1
    if IFS= read -r extra || [ -n "$extra" ]; then return 1; fi
  } 2>/dev/null < "$1/owner" || return 1
  printf '%s\n' "$owner"
}

_wto_lock_identity_state() {
  local pid start session boot
  case "$1" in *$'\n'*) printf 'unknown\n'; return 2 ;; esac
  printf '%s\n' "$1" | {
    IFS='|' read -r pid start session boot
    case "$boot" in *'|'*) printf 'unknown\n'; return 2 ;; esac
    if [ -z "$start" ] || [ -z "$boot" ] || [ "$boot" = unknown-boot ]; then
      printf 'unknown\n'; return 2
    fi
    _wto_process_state "$pid" "$start" "$boot"
  }
}

_wto_lock_owner_state() {
  local owner
  if ! owner=$(_wto_read_lock_owner "$1"); then
    printf 'unknown\n'
    return 2
  fi
  _wto_lock_identity_state "$owner"
}

_wto_lock() {
  local gitdir="${1:-}" lockdir identity holder dead_identity current_identity tmp attempts=0 reaped=0
  _wto_safe_gitdir "$gitdir" || return 1
  lockdir="$gitdir/apexyard-owner.lock"
  _wto_operation_identity identity || return 1
  # Six attempts bound contention waits to five short sleeps.
  while [ "$attempts" -lt 6 ]; do
    [ ! -L "$lockdir" ] || return 1
    if mkdir "$lockdir" 2>/dev/null; then
      tmp="$lockdir/owner.${identity%%|*}.tmp"
      if printf '%s\n' "$identity" > "$tmp" && mv -f "$tmp" "$lockdir/owner"; then
        return 0
      fi
      rm -f "$tmp"
      # No reaper acts without a published owner, and only the holder's own
      # identity can unlock. A directory without an owner is still ours.
      if [ ! -e "$lockdir/owner" ] && [ ! -L "$lockdir/owner" ]; then
        rm -rf "$lockdir"
      fi
      return 1
    fi
    holder=unknown
    if dead_identity=$(_wto_read_lock_owner "$lockdir"); then
      holder=$(_wto_lock_identity_state "$dead_identity") || :
    fi
    if [ "$holder" = dead ] && [ "$reaped" -eq 0 ] && mkdir "$lockdir/reaping" 2>/dev/null; then
      # Only the guarded reaper can remove a dead holder's lock. If its owner
      # still equals the identity proved dead, this is that generation's lock.
      # Probing again could outlive that holder and then delete a newer lock.
      if current_identity=$(_wto_read_lock_owner "$lockdir") && [ "$current_identity" = "$dead_identity" ]; then
        rm -rf "$lockdir" || return 1
        reaped=1
        continue
      fi
      # A reaping guard disappears only with its whole lock directory.
      # Removing it by path could remove another lock generation's guard.
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -lt 6 ]; then
      sleep 0.05 || return 1
    fi
  done
  return 1
}

_wto_unlock() {
  local gitdir="${1:-}" lockdir identity holder
  _wto_safe_gitdir "$gitdir" || return 1
  lockdir="$gitdir/apexyard-owner.lock"
  _wto_operation_identity identity || return 1
  holder=$(cat "$lockdir/owner" 2>/dev/null) || return 1
  [ "$holder" = "$identity" ] || return 1
  rm -rf "$lockdir"
}

_wto_with_lock() (
  # A subshell scopes cleanup traps and also handles a command calling exit.
  local gitdir="${1:-}"
  [ "$#" -ge 2 ] || return 1
  shift
  _wto_lock "$gitdir" || return 1
  trap '_wto_unlock "$gitdir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  "$@"
)

_wto_read_record() {
  jq -ces '
    def integer: type == "number" and . >= 0 and . <= 9007199254740991 and . == floor;
    def identity:
      type == "object" and
      (keys == ["boot_id","harness","pid","pid_start","session_id"]) and
      (.session_id | type == "string") and
      (if .harness == null then .pid == null and .pid_start == null and .boot_id == null
       else (.harness | type == "string" and length > 0) and
         (.pid | integer and . > 0) and (.pid_start | type == "string" and length > 0) and
         (.boot_id | type == "string" and length > 0) end);
    select(length == 1) | .[0] | select(type == "object") |
    select(.version == 1 and (.generation | integer and . > 0)) |
    select((.lease_heartbeat_at | integer) and (.lease_expires_at | integer)) |
    select(if .status == "active" then (.owner | identity)
      elif .status == "released" then .owner == null and (.released_by | identity)
      else false end)
  ' "$1" 2>/dev/null
}

_wto_record_state() {
  local owner="$1" pid start boot
  pid=$(printf '%s\n' "$owner" | jq -er '.pid | select(type == "number")') || {
    printf 'unknown\n'; return 2;
  }
  start=$(printf '%s\n' "$owner" | jq -r '.pid_start // ""') || return 2
  boot=$(printf '%s\n' "$owner" | jq -r '.boot_id // ""') || return 2
  _wto_process_state "$pid" "$start" "$boot"
}

_wto_update_locked() {
  local gitdir="$1" action="$2" owner="$3" ttl="$4" file record generation=0
  local state rc=0 now updated
  _wto_safe_gitdir "$gitdir" || return 1
  file="$gitdir/apexyard-owner"
  if [ -e "$file" ]; then
    record=$(_wto_read_record "$file") || return 1
    generation=$(printf '%s\n' "$record" | jq -r '.generation') || return 1
  else
    [ "$action" = acquire ] || return 1
    record='{"status":"released"}'
  fi
  if [ "$action" = acquire ]; then
    if ! printf '%s\n' "$record" | jq -e --argjson owner "$owner" \
      '.status == "released" or .owner == $owner' >/dev/null; then
      state=$(_wto_record_state "$(printf '%s\n' "$record" | jq -c '.owner')") || rc=$?
      [ "$state" = dead ] && [ "$rc" -eq 1 ] || return 1
    fi
  else
    printf '%s\n' "$record" | jq -e --argjson owner "$owner" \
      '.status == "active" and .owner == $owner' >/dev/null || return 1
  fi
  now=$(date +%s) || return 1
  updated=$(printf '%s\n' "$record" | jq -ce --arg action "$action" --argjson owner "$owner" \
    --argjson generation "$generation" --argjson now "$now" --argjson ttl "$ttl" '
      select($generation < 9007199254740991 and $now >= 0 and $now == ($now | floor)) |
      select($ttl > 0 and ($now + $ttl) <= 9007199254740991) |
      .version = 1 | .generation = ($generation + 1) |
      if $action == "release" then .status = "released" | .owner = null | .released_by = $owner
      else .status = "active" | .owner = $owner | del(.released_by) |
        .lease_heartbeat_at = $now | .lease_expires_at = ($now + $ttl) end
    ') || return 1
  _wto_write_json "$file" "$updated"
}

_wto_update() {
  local gitdir action="$2" owner ttl="${APEXYARD_WORKTREE_LEASE_TTL_SECONDS-3600}"
  case "$ttl" in ''|0*|*[!0-9]*) return 1 ;; esac
  jq -en --argjson ttl "$ttl" '$ttl > 0 and $ttl <= 9007199254740991' >/dev/null 2>&1 || return 1
  gitdir=$(_wto_gitdir "${1:-}") || return 1
  owner=$(worktree_owner_identity) || return 1
  _wto_with_lock "$gitdir" _wto_update_locked "$gitdir" "$action" "$owner" "$ttl"
}

worktree_owner_acquire() { _wto_update "${1:-}" acquire; }
worktree_owner_renew() { _wto_update "${1:-}" renew; }
worktree_owner_release() { _wto_update "${1:-}" release; }

worktree_owner_status() {
  local gitdir file record
  if ! gitdir=$(_wto_gitdir "${1:-}"); then printf 'unknown\n'; return 2; fi
  file="$gitdir/apexyard-owner"
  if [ ! -e "$file" ]; then printf 'none\n'; return 3; fi
  if ! record=$(_wto_read_record "$file"); then printf 'unknown\n'; return 2; fi
  if printf '%s\n' "$record" | jq -e '.status == "released"' >/dev/null; then
    printf 'released\n'; return 4
  fi
  _wto_record_state "$(printf '%s\n' "$record" | jq -c '.owner')"
}
