#!/bin/bash
# New gates only. Existing gates must never enter this allowlist.
# Add each new gate name as a literal case before the rejecting fallback.
_gate_mode_opted_in() {
  case "$1" in
    # Opted-in gate names go here. No production gate is opted in yet.
    *) return 1 ;;
  esac
}

# gate_mode_resolve NAME [DEFAULT]: print a mode. Refuse unknown gates.
# Config failures use enforce. Missing keys use the declared default.
gate_mode_resolve() {
  local name="$1" default="${2:-enforce}" mode reader file failed=0
  if ! _gate_mode_opted_in "$name"; then
    printf 'WARN: gate mode refused for non-opted-in gate: %s\n' "$name" >&2
    printf 'enforce\n'
    return 1
  fi
  case "$default" in observe|enforce) ;; *) default=enforce ;; esac
  if ! command -v config_get >/dev/null 2>&1; then
    reader="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib-read-config.sh"
    # shellcheck source=/dev/null
    if [ ! -r "$reader" ] || ! { . "$reader"; } 2>/dev/null; then
      failed=1
    fi
  fi
  # The reader can hide parse errors through fallback values or a null result.
  # Validate its input files separately without changing other config callers.
  if [ "$failed" = 0 ] && command -v _config_defaults_file >/dev/null 2>&1; then
    for reader in _config_defaults_file _config_overrides_file; do
      if ! file=$("$reader" 2>/dev/null); then
        failed=1
        break
      fi
      if [ -e "$file" ] || [ -L "$file" ]; then
        # An empty, null, array or scalar file is broken too: require one object.
        if [ ! -f "$file" ] || [ ! -r "$file" ] || ! jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
          failed=1
          break
        fi
      fi
    done
  fi
  if [ "$failed" = 1 ] || ! mode=$(config_get ".gates[\"$name\"].mode" 2>/dev/null); then
    printf 'WARN: config unavailable for gate %s. Using enforce.\n' "$name" >&2
    printf 'enforce\n'
    return 0
  fi
  case "$mode" in
    null) mode="$default" ;;
    off|observe|enforce) ;;
    *) printf 'WARN: invalid mode for gate %s. Using enforce.\n' "$name" >&2; mode=enforce ;;
  esac
  printf '%s\n' "$mode"
}

# Call only for a would-block event. Return 0 to allow, 2 to block.
# gate_would_block NAME DEFAULT EVENT_CODE OPS_ROOT
# EVENT_CODE is a fixed identifier. Never pass command text or secrets.
gate_would_block() {
  local name="$1" default="$2" event="$3" root="$4" mode line
  mode=$(gate_mode_resolve "$name" "$default") || return 2
  case "$mode" in
    off) return 0 ;;
    enforce) return 2 ;;
    observe)
      if [[ ! "$event" =~ ^[a-zA-Z0-9_-]+$ ]] || [ -z "$root" ]; then
        printf 'WARN: gate observation has an invalid event or root.\n' >&2
        return 0
      fi
      line=$(jq -nc --arg gate "$name" --arg event "$event" \
        --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{gate:$gate,event:$event,mode:"observe",timestamp:$time}') &&
        mkdir -p "$root/.claude/session" &&
        printf '%s\n' "$line" >> "$root/.claude/session/gate-observe.log" ||
        printf 'WARN: could not append gate observation.\n' >&2
      return 0
      ;;
  esac
  return 2
}

# Print nothing for an absent or empty log. This function never writes.
gate_observe_summary() {
  local log="$1/.claude/session/gate-observe.log" count
  [ -s "$log" ] || return 0
  count=$(wc -l < "$log" | tr -d '[:space:]')
  [ "$count" -gt 0 ] && printf 'Gate observe: %s would-block events\n' "$count"
  return 0
}
