#!/bin/bash
# PostToolUse hook on AskUserQuestion.
#
# Menu records have the same trust level as typed markers (AgDR-0234).
# The guard is a text-match backstop (AgDR-0104). The real control is the
# human-only menu answer plus the gate's head-SHA match. This script is the
# supported writer; invoking it with crafted stdin can also write a record.
#
# A question must match a strict shape that names the repo, the PR number,
# and the full 40-hex head SHA. The selected option must be the exact
# approve label. "Not yet" and every other answer write nothing.
# An umbrella "go" never reaches this hook as that shape.
#
# Marker home matches block-unreviewed-merge.sh: ops root when the walk
# finds one, otherwise the git toplevel. See _lib-menu-approval.sh.

INPUT=$(cat)

TOOL_NAME=""
if command -v jq >/dev/null 2>&1; then
  TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
fi
if [ "$TOOL_NAME" != "AskUserQuestion" ]; then
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "WARN: menu approval hook cannot parse the payload because jq is missing. No record was written." >&2
  exit 0
fi

# A timeout closes the menu without human approval. Check decoded responses too.
if printf '%s' "$INPUT" | jq -e '
  def decoded: if type == "string" then (fromjson? // .) else . end;
  [., (.tool_response | decoded)] | any(.. | objects; has("afkTimeoutMs"))
' >/dev/null 2>&1; then
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-ops-root.sh"
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-review-markers.sh"
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-menu-approval.sh"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
OPS_ROOT=$(resolve_ops_root ${REPO_ROOT:+"$REPO_ROOT"})
MARKER_HOME="${OPS_ROOT:-${REPO_ROOT:-$PWD}}"

QUESTIONS=$(printf '%s' "$INPUT" | jq -r '.tool_input.questions // [] | .[] | .question // empty' 2>/dev/null) || QUESTIONS=""
[ -n "$QUESTIONS" ] || exit 0

while IFS= read -r qtext; do
  [ -n "$qtext" ] || continue
  parsed=$(menu_approval_parse "$qtext") || continue
  role=$(printf '%s\n' "$parsed" | sed -n '1p')
  repo=$(printf '%s\n' "$parsed" | sed -n '2p')
  pr=$(printf '%s\n' "$parsed" | sed -n '3p')
  sha=$(printf '%s\n' "$parsed" | sed -n '4p')
  label=$(menu_approval_label "$role") || continue
  selected=$(menu_approval_selected "$qtext" "$INPUT")
  [ "$selected" = "$label" ] || continue
  path=$(review_marker_path "$repo" "$pr" "$role" "$MARKER_HOME") || continue
  if ! menu_approval_write_record "$path" "$sha" "$label"; then
    echo "WARN: menu approval hook could not write the record for ${repo}#${pr}." >&2
  fi
done <<EOF
$QUESTIONS
EOF

exit 0
