#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WRAPPER="$ROOT/.codex/hooks/codex-pre-edit.sh"

if [ ! -x "$WRAPPER" ]; then
  echo "SKIP: Codex pre-edit wrapper not generated"
  exit 0
fi

SESSION_DIR="$ROOT/.codex/session"
BACKUP_DIR="$(mktemp -d)"
mkdir -p "$SESSION_DIR"

restore_session_markers() {
  for name in current-ticket tickets active-bootstrap; do
    rm -rf "$SESSION_DIR/$name"
    if [ -e "$BACKUP_DIR/$name" ]; then
      mv "$BACKUP_DIR/$name" "$SESSION_DIR/$name"
    fi
  done
  rm -rf "$BACKUP_DIR"
}
trap restore_session_markers EXIT

for name in current-ticket tickets active-bootstrap; do
  if [ -e "$SESSION_DIR/$name" ]; then
    mv "$SESSION_DIR/$name" "$BACKUP_DIR/$name"
  fi
done

expect_ticket_block() {
  local label="$1"
  local payload="$2"
  local output rc

  set +e
  output=$(printf '%s' "$payload" | (
    cd "$ROOT"
    unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID CLAUDE_WORKTREE_BRANCH CODEX_WORKTREE_BRANCH
    APEXYARD_OPS_DISABLE_PIN=1 "$WRAPPER"
  ) 2>&1)
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    echo "FAIL: $label should block without a ticket"
    echo "$output"
    exit 1
  fi

  if ! printf '%s' "$output" | grep -q "BLOCKED: No active ticket"; then
    echo "FAIL: $label blocked with unexpected output"
    echo "$output"
    exit 1
  fi
}

pretty_write=$(jq -n --arg p "$ROOT/src/probe.ts" \
  '{tool_name:"Write", tool_input:{file_path:$p}}')
expect_ticket_block "pretty Write payload" "$pretty_write"

patch_payload=$(jq -n --arg patch $'*** Begin Patch\n*** Update File: src/probe.ts\n+probe\n*** End Patch\n' \
  '{tool_name:"apply_patch", tool_input:{patch:$patch}}')
expect_ticket_block "pretty apply_patch payload" "$patch_payload"

echo "PASS: Codex pre-edit wrapper blocks pretty JSON payloads"
