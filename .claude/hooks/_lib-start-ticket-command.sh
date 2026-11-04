#!/bin/bash
# Exact raw-command grammar. Do not tokenize or expand caller text here.
start_ticket_command_allowed() {
  local cmd="$1" cwd="$2" root="$3" ref re
  case "$cmd" in
    "$root/bin/apexyard-start-ticket "*) ref=${cmd#"$root/bin/apexyard-start-ticket "} ;;
    'bin/apexyard-start-ticket '*)
      [ "$cwd" = "$root" ] || return 1
      ref=${cmd#'bin/apexyard-start-ticket '} ;;
    *) return 1 ;;
  esac
  re='^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*#[0-9]+$'
  [[ "$ref" =~ $re ]] && [ ! -L "$root/bin/apexyard-start-ticket" ] \
    && [ -f "$root/bin/apexyard-start-ticket" ]
}
