#!/bin/bash
# _lib-project-board.sh — auto-move GitHub Projects (v2) board cards through
# the SDLC lifecycle.
#
# Exposed function:
#   board_move_card <issue-or-pr-number> <status-key>
#
# Status keys (map to option labels via .github_projects.status_map in config):
#   in_progress   — ticket picked up via /start-ticket
#   review        — PR created, auto-code-review.sh fires
#   measurement   — PR merged via /approve-merge
#
# CONFIGURATION (.claude/project-config.json — opt-in, defaults in defaults.json):
#
#   "github_projects": {
#     "owner":             "<org-or-user>",   // GitHub owner of the board
#     "board_number":      1,                  // numeric board number
#     "enable_auto_moves": true,               // OPT-IN; default false
#     "status_field_name": "Status",           // label of the single-select field
#     "status_map": {
#       "in_progress":  "In progress",
#       "review":       "In review",
#       "measurement":  "Measurement"
#     }
#   }
#
# GRACEFUL DEGRADE GUARANTEE:
#   Any failure (board/field/item not found, missing scope, bad config) warns
#   to stderr and returns 0. This lib NEVER exits non-zero — it must never
#   block the lifecycle action that called it.
#
# OPS-ROOT:
#   Config is resolved pin-first via resolve_ops_root() from _lib-ops-root.sh,
#   matching the same strategy used by all other apexyard hooks. Do NOT use
#   plain `git rev-parse --show-toplevel` here — in split-portfolio mode or
#   when running from workspace/<project>/ the toplevel is the project clone,
#   NOT the ops fork where the config lives. See me2resh/apexyard#381.
#
# GITHUB-NATIVE WORKFLOW NOTE:
#   For transitions outside the three SDLC attach-points above, use
#   GitHub Projects' built-in Workflows (Settings → Workflows):
#     - "Item added to project"  → auto-add issues/PRs when opened
#     - "Item closed"            → move to Done when an issue is closed
#     - "Pull request merged"    → move to Done when a PR is merged
#   These free built-ins handle the closed/merged → Done hop so this lib
#   doesn't have to. Enable them in the GitHub UI; no config here is needed.
#
# Decision record: docs/agdr/AgDR-0080-board-automation-attach-points.md
#
# Sourced by hooks and skills; never executed directly. Use the source-guard
# so multiple sources in one shell process are idempotent.

[ -n "${_LIB_PROJECT_BOARD_SOURCED:-}" ] && return 0
_LIB_PROJECT_BOARD_SOURCED=1

# ---------------------------------------------------------------------------
# Source sibling libs — located in the same .claude/hooks/ directory.
# Use BASH_SOURCE so the path is correct even when the lib is sourced from a
# different cwd (e.g. from a skill that cd'd into a project clone).
# ---------------------------------------------------------------------------
_lib_board_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pin-first ops-root resolver (provides resolve_ops_root).
if [ -f "$_lib_board_dir/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$_lib_board_dir/_lib-ops-root.sh"
fi

# Config reader (provides config_get / config_get_or; internally sources
# _lib-ops-root.sh for ops-root resolution — idempotent due to source-guard).
if [ -f "$_lib_board_dir/_lib-read-config.sh" ]; then
  # shellcheck source=/dev/null
  . "$_lib_board_dir/_lib-read-config.sh"
fi

# ---------------------------------------------------------------------------
# board_move_card <item-number> <status-key>
#
#   <item-number> — GitHub issue or PR number (plain integer)
#   <status-key>  — one of: in_progress, review, measurement
# ---------------------------------------------------------------------------
board_move_card() {
  local item_ref="$1"
  local status_key="$2"

  # ---- Guard: enable_auto_moves must be exactly "true" --------------------
  # Default is false (opt-in). Absent or any non-"true" value → silent no-op.
  local enabled
  enabled=$(config_get '.github_projects.enable_auto_moves' 2>/dev/null)
  if [ "$enabled" != "true" ]; then
    return 0
  fi

  # ---- Read board coordinates from config ---------------------------------
  local owner board_number status_field_name
  owner=$(config_get '.github_projects.owner' 2>/dev/null)
  board_number=$(config_get '.github_projects.board_number' 2>/dev/null)
  status_field_name=$(config_get_or '.github_projects.status_field_name' 'Status')

  if [ -z "$owner" ] || [ "$owner" = "null" ] || \
     [ -z "$board_number" ] || [ "$board_number" = "null" ] || \
     [ "$board_number" = "0" ]; then
    echo "WARN [board_move_card]: github_projects.owner or board_number not configured; skipping card move for #${item_ref}." >&2
    return 0
  fi

  # ---- Map status key to board option label --------------------------------
  local option_label
  option_label=$(config_get ".github_projects.status_map.${status_key}" 2>/dev/null)
  if [ -z "$option_label" ] || [ "$option_label" = "null" ]; then
    echo "WARN [board_move_card]: no status_map entry for key '${status_key}'; skipping card move for #${item_ref}." >&2
    return 0
  fi

  # ---- gh availability check ----------------------------------------------
  if ! command -v gh >/dev/null 2>&1; then
    echo "WARN [board_move_card]: gh not found; skipping card move for #${item_ref}." >&2
    return 0
  fi

  # ---- Resolve project node ID -------------------------------------------
  # `gh project list` returns {"projects": [{"id": "PVT_xxx", "number": N, ...}]}
  local project_json project_id
  project_json=$(gh project list --owner "$owner" --format json 2>/dev/null)
  project_id=$(printf '%s' "$project_json" \
    | jq -r ".projects[] | select(.number == ${board_number}) | .id" 2>/dev/null)
  if [ -z "$project_id" ] || [ "$project_id" = "null" ]; then
    echo "WARN [board_move_card]: project #${board_number} not found for owner '${owner}'; skipping card move for #${item_ref}." >&2
    return 0
  fi

  # ---- Resolve status field ID and option ID ------------------------------
  # `gh project field-list` returns {"fields": [{"id": "PVTF_xxx", "name": "Status",
  #   "type": "single_select", "options": [{"id": "opt_xxx", "name": "In progress"}, ...]}]}
  local field_json field_id option_id
  field_json=$(gh project field-list "$board_number" --owner "$owner" --format json 2>/dev/null)

  field_id=$(printf '%s' "$field_json" \
    | jq -r ".fields[] | select(.name == \"${status_field_name}\") | .id" 2>/dev/null)
  if [ -z "$field_id" ] || [ "$field_id" = "null" ]; then
    echo "WARN [board_move_card]: field '${status_field_name}' not found on board #${board_number}; skipping card move for #${item_ref}." >&2
    return 0
  fi

  option_id=$(printf '%s' "$field_json" \
    | jq -r ".fields[] | select(.name == \"${status_field_name}\") | .options[] | select(.name == \"${option_label}\") | .id" 2>/dev/null)
  if [ -z "$option_id" ] || [ "$option_id" = "null" ]; then
    echo "WARN [board_move_card]: option '${option_label}' not found in field '${status_field_name}'; skipping card move for #${item_ref}." >&2
    return 0
  fi

  # ---- Resolve project item ID --------------------------------------------
  # `gh project item-list` returns {"items": [{"id": "PVTI_xxx", "content": {"number": N, ...}}]}
  # Pass --limit 200 so boards with >30 items (the gh default page size) don't
  # silently miss the target card. 200 is the GitHub Projects API maximum per page.
  local item_json item_id
  item_json=$(gh project item-list "$board_number" --owner "$owner" --format json --limit 200 2>/dev/null)
  item_id=$(printf '%s' "$item_json" \
    | jq -r ".items[] | select(.content.number == ${item_ref}) | .id" 2>/dev/null)
  if [ -z "$item_id" ] || [ "$item_id" = "null" ]; then
    echo "WARN [board_move_card]: item #${item_ref} not found on board #${board_number}; skipping card move." >&2
    return 0
  fi

  # ---- Move the card -------------------------------------------------------
  if ! gh project item-edit \
       --id "$item_id" \
       --project-id "$project_id" \
       --field-id "$field_id" \
       --single-select-option-id "$option_id" 2>/dev/null; then
    echo "WARN [board_move_card]: gh project item-edit failed for item #${item_ref}; skipping." >&2
    return 0
  fi

  return 0
}
