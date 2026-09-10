#!/bin/bash
# Raw-payload trigger checks for hooks whose jq parse failed. These checks are
# deliberately narrow: they block only when the JSON still contains the hook's
# own command shape, and leave unrelated or genuinely empty payloads alone.

raw_payload_command_matches() {
  local payload="$1" pattern="$2"
  printf '%s' "$payload" | grep -qE '"command"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*'"$pattern"
}

raw_payload_tool_matches() {
  local payload="$1" tool="$2"
  printf '%s' "$payload" | grep -qE '"tool_name"[[:space:]]*:[[:space:]]*"'"$tool"'"'
}
