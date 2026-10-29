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

# Bash is Claude Code's tool name. shellToolCall is the Cursor stream name
# reproduced with cursor-agent 2026.10.22 (GH-1909, 2026-10-29). Do not guess
# further aliases: Claude-format hook payloads can be recognized by shape.
# A file target takes precedence over the command-shape fallback.
hook_is_shell_call() {
  local payload="$1"
  printf '%s' "$payload" | jq -e '
    (.tool_name == "Bash" or .tool_name == "shellToolCall") or
    ((.tool_input.command | type == "string" and length > 0) and
     ((.tool_input.file_path // "") == "") and
     ((.tool_input.notebook_path // "") == ""))
  ' >/dev/null 2>&1
}
