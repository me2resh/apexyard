#!/bin/bash
# _lib-agc.sh — helpers for gates that answer with an Agent Gate Contract
# (AGC) object (me2resh/apexyard#1698, AgDR-0237).
#
# AGC is an external open standard for a gate's answer:
# https://github.com/abbaseya/agent-gate-contract (draft 0.1).
# This pilot claims AGC bindings for Claude Code and Codex only. Every other
# runtime keeps the plain exit-2 behaviour.
#
# Functions:
#   agc_sha256 <text>        prints "sha256:<hex>" for the text
#   agc_runtime <hook-json>  prints "claude", "codex" or "none"
#   agc_render_findings <agc-json>
#                            prints one line per finding, for people
#   agc_pretooluse_output <runtime> <new-tool-input-json> <agc-json>
#                            prints the PreToolUse JSON that carries a repair

agc_sha256() {
  local digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)
  else
    digest=$(printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1)
  fi
  printf 'sha256:%s' "$digest"
}

# A repair is only safe where the runtime applies updatedInput. The OpenCode
# and Pi adapters treat exit 0 as "allow" and ignore stdout, so a repair there
# would run the original command unchanged. Detect the two verified runtimes
# positively and answer "none" for everything else.
#   codex:  the Codex adapter wrapper exports APEXYARD_CODEX_HOOK_TOOL
#           (bin/sync-codex-adapter.sh).
#   claude: Claude Code exports CLAUDE_PROJECT_DIR to hook commands and sends
#           hook_event_name and transcript_path in the hook input. The OpenCode
#           and Pi adapters send only tool_name and tool_input.
agc_runtime() {
  local input="$1" event transcript
  if [ -n "${APEXYARD_CODEX_HOOK_TOOL:-}" ]; then
    printf 'codex'
    return 0
  fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && command -v jq >/dev/null 2>&1; then
    event=$(jq -r '.hook_event_name // empty' <<<"$input" 2>/dev/null) || event=""
    transcript=$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null) || transcript=""
    if [ "$event" = "PreToolUse" ] && [ -n "$transcript" ]; then
      printf 'claude'
      return 0
    fi
  fi
  printf 'none'
}

agc_render_findings() {
  jq -r '"AGC \(.verdict): " + ([.findings[]? | "\(.id) — \(.what)"] | join("; "))' <<<"$1"
}

# Claude Code: updatedInput with no permissionDecision, so the rewritten call
# still goes through the person's permission settings. "allow" would skip the
# permission prompt (AGC BINDINGS, Claude Code PreToolUse).
# Codex: updatedInput is only accepted with permissionDecision "allow". It was
# measured not to skip Codex's own approval (AGC BINDINGS, Codex PreToolUse).
# updatedInput replaces the whole tool input, so the caller passes the full
# rewritten tool_input object, not only the changed field.
agc_pretooluse_output() {
  local runtime="$1" new_input="$2" agc="$3" context
  context="$(agc_render_findings "$agc")"$'\n```agc\n'"$(jq -c . <<<"$agc")"$'\n```'
  case "$runtime" in
    claude)
      jq -nc --argjson input "$new_input" --arg ctx "$context" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: $input, additionalContext: $ctx}}'
      ;;
    codex)
      jq -nc --argjson input "$new_input" --arg ctx "$context" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: $input, additionalContext: $ctx}}'
      ;;
    *)
      return 1
      ;;
  esac
}
