#!/bin/bash
# Adapt patch targets to the existing edit checks; this adds no policy gate.
set -uo pipefail
HOOK_DIR=$(cd "$(dirname "$0")" && pwd -P)
INPUT=$(cat)
blocked() { echo "BLOCKED: apply_patch $1" >&2; exit 2; }
cwd=$(jq -r '.cwd // .tool_input.cwd // empty' <<<"$INPUT" 2>/dev/null) || blocked 'cannot read the effective directory.'
cd "${cwd:-${CLAUDE_PROJECT_DIR:-$PWD}}" || blocked 'cannot enter the effective directory.'
targets=$(jq -cer '
  .tool_input.command | select(type == "string") | split("\n")
  | if .[-1] == "" then .[:-1] else . end
  | select(.[0] == "*** Begin Patch" and .[-1] == "*** End Patch")
  | .[1:-1]
  | select(all(.[]; . != "*** Begin Patch" and . != "*** End Patch"))
  | select(all(.[]; if startswith("*** ") then
      test("^\\*\\*\\* (Add File|Update File|Delete File|Move to): .+$") or . == "*** End of File"
      else true end))
  | [ .[] | select(test("^\\*\\*\\* (Add File|Update File|Delete File|Move to):"))
      | capture("^\\*\\*\\* (?:Add File|Update File|Delete File|Move to): (?<path>.+)$").path ]
  | select(length > 0 and all(.[]; test("[^[:space:]]")))
' <<<"$INPUT" 2>/dev/null) || blocked 'has a malformed envelope or no targets.'
# Use the configured edit checks, including Write-only checks. Retain their
# commands and diagnostics instead of duplicating their policies here.
commands=$(jq -cer '[.hooks.PreToolUse[]
  | select((.matcher // "") | split("|") | any(. == "Edit" or . == "Write" or . == "MultiEdit" or . == "NotebookEdit"))
  | .hooks[] | .command] | select(length > 0)' \
  "$HOOK_DIR/../settings.json" 2>/dev/null) || blocked 'cannot load the existing edit checks.'
count=$(jq length <<<"$targets") || exit 2
i=0
while [ "$i" -lt "$count" ]; do
  target=$(jq -r --argjson i "$i" '.[$i]' <<<"$targets") || exit 2
  payload=$(jq -c --arg path "$target" '.tool_name = "Write" | .tool_input = {file_path:$path,content:.tool_input.command,new_string:.tool_input.command}' <<<"$INPUT") || exit 2
  n=0
  total=$(jq length <<<"$commands") || exit 2
  while [ "$n" -lt "$total" ]; do
    command=$(jq -r --argjson n "$n" '.[$n]' <<<"$commands") || exit 2
    rc=0
    bash -c "$command" <<<"$payload" || rc=$?
    [ "$rc" -ne 2 ] || exit 2
    [ "$rc" -eq 0 ] || blocked "edit check exited $rc instead of PASS."
    n=$((n+1))
  done
  i=$((i+1))
done
