#!/bin/bash
# PreToolUse guard. Blocks Edit, Write, MultiEdit, and Bash writes that put
# approval_channel=menu into a review marker.
#
# CLASS: BACKSTOP (AgDR-0104, AgDR-0234). The control that records a human
# menu answer is record-menu-approval.sh, which reads the harness payload.
# This guard stops the common model write of that same record. It matches
# text. AgDR-0104 says a text match cannot see every spelling. A later copy
# that hides the channel string can still pass. The gate then trusts the
# file. There is no unreadable key file in this repo, so an HMAC would not
# prove the writer either.
#
# The typed /approve-merge path does not set approval_channel=menu. This
# guard lets that write through.
#
# Exit 0 to allow. Exit 2 to block.

INPUT=$(cat)

_menu_block() {
  cat >&2 <<'EOF'
BLOCKED: use the human approval menu to record menu approval.
Do not write approval_channel=menu into a review marker.
The operator selects the approve option in the menu. That selection is the approval.
EOF
  exit 2
}

_menu_path_is_marker() {
  case "$1" in
    *-ceo.approved|*-design.approved|*-architecture.approved) return 0 ;;
    *) return 1 ;;
  esac
}

if ! command -v jq >/dev/null 2>&1; then
  if printf '%s' "$INPUT" | grep -qE 'record-menu-approval|_lib-menu-approval|menu_approval_write_record'; then
    _menu_block
  fi
  if printf '%s' "$INPUT" | grep -q 'approval_channel=' &&
     printf '%s' "$INPUT" | grep -qE -- '-(ceo|design|architecture)\.approved'; then
    _menu_block
  fi
  exit 0
fi

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""

case "$TOOL_NAME" in
  Write|Edit|MultiEdit)
    PATHS=$(printf '%s' "$INPUT" | jq -r '
      [
        .tool_input.file_path // empty,
        .tool_input.path // empty,
        (.tool_input.edits // [] | .[] | .file_path // empty)
      ] | .[] | select(type == "string" and length > 0)
    ' 2>/dev/null) || PATHS=""
    BLOB=$(printf '%s' "$INPUT" | jq -r '
      [
        .tool_input.content // empty,
        .tool_input.new_string // empty,
        .tool_input.old_string // empty,
        (.tool_input.edits // [] | .[] | .new_string // empty, .old_string // empty)
      ] | map(select(type == "string")) | join("\n")
    ' 2>/dev/null) || BLOB=""
    if ! printf '%s' "$BLOB" | grep -qE "approval_channel=[\"']?menu[\"']?"; then
      exit 0
    fi
    while IFS= read -r one_path; do
      [ -n "$one_path" ] || continue
      if _menu_path_is_marker "$one_path"; then
        _menu_block
      fi
    done <<EOF
$PATHS
EOF
    exit 0
    ;;
esac

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || COMMAND=""
[ -n "$COMMAND" ] || exit 0
if printf '%s' "$COMMAND" | grep -qE 'record-menu-approval|_lib-menu-approval|menu_approval_write_record'; then
  _menu_block
fi
if ! printf '%s' "$COMMAND" | grep -qE "approval_channel=[\"']?menu[\"']?"; then
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -r "$HOOK_DIR/_lib-detect-bash-write.sh" ]; then
  echo "BLOCKED: menu approval guard cannot load its write detector." >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-detect-bash-write.sh"

if ! bash_command_appears_to_write "$COMMAND"; then
  exit 0
fi
if declare -F bash_command_is_deletion_only >/dev/null 2>&1; then
  if bash_command_is_deletion_only "$COMMAND"; then
    exit 0
  fi
fi

TARGETS=$(bash_extract_write_targets "$COMMAND" 2>/dev/null) || TARGETS=""
while IFS= read -r one_target; do
  [ -n "$one_target" ] || continue
  one_target=${one_target#\"}
  one_target=${one_target%\"}
  one_target=${one_target#\'}
  one_target=${one_target%\'}
  if _menu_path_is_marker "$one_target"; then
    _menu_block
  fi
done <<EOF
$TARGETS
EOF

# The extractor can miss a simple redirect and return no target.
# Scan that shape only then, so a doc body that mentions a marker path
# does not block a write to a different file.
if [ -z "$TARGETS" ]; then
  if printf '%s' "$COMMAND" | grep -qE -- '(>>?)[[:space:]]*[^[:space:];|&]*-(ceo|design|architecture)\.approved'; then
    _menu_block
  fi
fi

exit 0
