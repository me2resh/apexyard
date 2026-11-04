#!/usr/bin/env bash
# Keep install events separate from repository data.
telemetry_enabled() {
  case "${APEXYARD_TELEMETRY:-}" in
    0|false|off) return 1 ;;
    *) return 0 ;;
  esac
}
telemetry_install_id() (
  telemetry_enabled || return 1
  local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/apexyard" id
  umask 077
  mkdir -p "$config_dir" || return 1
  if [ ! -f "$config_dir/install-id" ]; then
    id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
    [ "${#id}" -eq 32 ] || return 1
    printf '%s\n' "$id" > "$config_dir/install-id" || return 1
  fi
  chmod 600 "$config_dir/install-id" || return 1
  cat "$config_dir/install-id"
)
telemetry_notice_once() (
  telemetry_enabled || return 0
  local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/apexyard"
  [ ! -e "$config_dir/telemetry-notice-shown" ] || return 0
  umask 077
  mkdir -p "$config_dir" || return 0
  printf '%s\n' "ApexYard sends one anonymous install event when you run 'apexyard init'. It holds four fields: a random install id, the CLI version, your operating system, and the agent tool you chose. It never holds a repository, organisation, user name, path or code. To turn it off, set APEXYARD_TELEMETRY=0." >&2
  : > "$config_dir/telemetry-notice-shown"
)
telemetry_payload() {
  local id os
  id=$(telemetry_install_id) || return 1
  os=$(uname -s | tr '[:upper:]' '[:lower:]') || return 1
  jq -cn --arg install_id "$id" --arg cli_version "${APEXYARD_CLI_VERSION:-unknown}" \
    --arg os "$os" --arg agent "$1" \
    '{install_id: $install_id, cli_version: $cli_version, os: $os, agent: $agent}'
}
telemetry_send() {
  telemetry_enabled || return 0
  local payload endpoint="${APEXYARD_TELEMETRY_URL:-dry-run}"
  payload=$(telemetry_payload "$1" 2>/dev/null) || return 0
  if [ "$endpoint" = dry-run ]; then
    printf 'Install ping (dry run, nothing sent): %s\n' "$payload" >&2
  else
    printf '%s' "$payload" | "${APEXYARD_CURL:-curl}" -fsS --max-time 3 \
      -H 'Content-Type: application/json' --data-binary @- -- "$endpoint" >/dev/null 2>&1 || true
  fi
  return 0
}
