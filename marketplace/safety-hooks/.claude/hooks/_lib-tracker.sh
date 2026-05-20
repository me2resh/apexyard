#!/bin/bash
# _lib-tracker.sh — tracker-agnostic existence verification + ID-shape regex.
#
# Source this library from any hook or skill that needs to verify a ticket
# exists in the adopter's tracker (GitHub Issues, Linear, Jira, Asana, custom).
# It dispatches based on the `tracker` block of .claude/project-config.{defaults,}.json.
#
# Resolved at config time:
#   tracker.kind         — "gh" | "linear" | "jira" | "asana" | "custom" | "none"
#   tracker.view_command — template string with {id} and {owner_repo} placeholders
#   tracker.id_pattern   — regex for valid ticket-ID shape (no-existence-check fallback)
#
# Public functions:
#   tracker_kind                       echoes the configured tracker kind
#   tracker_id_pattern                 echoes the configured ID regex
#   tracker_owner_repo_param <slug>    formats the owner/repo parameter (gh: "owner/repo"; others: empty)
#   tracker_view <id> [<owner_repo>]   dispatches the view command and emits normalised JSON on stdout
#                                      Exit 0 = ticket exists; non-zero = doesn't, or CLI errored.
#                                      JSON shape: {"state":..., "title":..., "url":..., "labels":[...]}
#
# Normalisation: each adapter parses the underlying CLI's JSON (gh / linear /
# jira / asana / custom) into the common shape above. Consumers should only
# touch the normalised fields — never reach for adapter-specific shapes.
#
# `tracker.kind = none` makes `tracker_view` a no-op that exits 1 (no
# existence check possible). Consumers should fall back to shape-only
# verification using `tracker_id_pattern`.
#
# Caching: results cached per-process in shell vars. Same pattern as
# _CONFIG_CACHE in _lib-read-config.sh and _PORTFOLIO_*_CACHE in
# _lib-portfolio-paths.sh.

# ------------------------------------------------------------------------------
# Internal: ensure _lib-read-config.sh is loaded so config_get_or works.
# ------------------------------------------------------------------------------
_tracker_load_config_lib() {
  if command -v config_get_or >/dev/null 2>&1; then
    return 0
  fi
  local root hook_dir
  hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$hook_dir/_lib-read-config.sh" ]; then
    # shellcheck source=/dev/null
    . "$hook_dir/_lib-read-config.sh"
    return 0
  fi
  root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$root" ] && [ -f "$root/.claude/hooks/_lib-read-config.sh" ]; then
    # shellcheck source=/dev/null
    . "$root/.claude/hooks/_lib-read-config.sh"
  fi
}

# ------------------------------------------------------------------------------
# Public: tracker_kind
#   Echoes the configured tracker kind. Default "gh" (GitHub Issues).
# ------------------------------------------------------------------------------
_TRACKER_KIND_CACHE=""
tracker_kind() {
  if [ -n "$_TRACKER_KIND_CACHE" ]; then
    echo "$_TRACKER_KIND_CACHE"
    return 0
  fi
  _tracker_load_config_lib
  local k
  k=$(config_get_or '.tracker.kind' 'gh' 2>/dev/null)
  if [ -z "$k" ] || [ "$k" = "null" ]; then
    k="gh"
  fi
  _TRACKER_KIND_CACHE="$k"
  echo "$k"
}

# ------------------------------------------------------------------------------
# Public: tracker_id_pattern
#   Echoes the configured regex for valid ticket IDs. Default covers GitHub
#   shapes (`#123`, `GH-123`) AND most enterprise prefixes (`ABC-123`,
#   `LIN-456`) so a fork that hasn't touched config still validates Linear
#   and Jira IDs at the shape level. Adopters who want stricter shape
#   validation override `.tracker.id_pattern`.
# ------------------------------------------------------------------------------
_TRACKER_ID_PATTERN_CACHE=""
tracker_id_pattern() {
  if [ -n "$_TRACKER_ID_PATTERN_CACHE" ]; then
    echo "$_TRACKER_ID_PATTERN_CACHE"
    return 0
  fi
  _tracker_load_config_lib
  local p
  p=$(config_get_or '.tracker.id_pattern' '^(#[0-9]+|GH-[0-9]+|[A-Z]{2,10}-[0-9]+)$' 2>/dev/null)
  if [ -z "$p" ] || [ "$p" = "null" ]; then
    p='^(#[0-9]+|GH-[0-9]+|[A-Z]{2,10}-[0-9]+)$'
  fi
  _TRACKER_ID_PATTERN_CACHE="$p"
  echo "$p"
}

# ------------------------------------------------------------------------------
# Internal: read the configured view_command template. Default matches today's
# behaviour exactly (GH CLI shape).
# ------------------------------------------------------------------------------
_TRACKER_VIEW_TPL_CACHE=""
_tracker_view_template() {
  if [ -n "$_TRACKER_VIEW_TPL_CACHE" ]; then
    echo "$_TRACKER_VIEW_TPL_CACHE"
    return 0
  fi
  _tracker_load_config_lib
  local tpl
  tpl=$(config_get_or '.tracker.view_command' 'gh issue view {id} --repo {owner_repo} --json state,title,url,labels' 2>/dev/null)
  if [ -z "$tpl" ] || [ "$tpl" = "null" ]; then
    tpl='gh issue view {id} --repo {owner_repo} --json state,title,url,labels'
  fi
  _TRACKER_VIEW_TPL_CACHE="$tpl"
  echo "$tpl"
}

# ------------------------------------------------------------------------------
# Public: tracker_owner_repo_param <owner/repo>
#   Formats the owner/repo argument for the active tracker. For the gh kind,
#   echoes the slug as-is (so `--repo owner/repo` works in the template). For
#   trackers without per-repo scoping (Linear / Jira / Asana — usually one
#   workspace at a time), echoes the slug unchanged but the template is
#   expected not to reference {owner_repo}.
# ------------------------------------------------------------------------------
tracker_owner_repo_param() {
  local slug="$1"
  echo "$slug"
}

# ------------------------------------------------------------------------------
# Internal: substitute {id} and {owner_repo} placeholders in the view template.
# ------------------------------------------------------------------------------
_tracker_substitute() {
  local tpl="$1" id="$2" owner_repo="$3"
  # Use POSIX parameter expansion — portable across bash 3.2 (macOS default).
  tpl="${tpl//\{id\}/$id}"
  tpl="${tpl//\{owner_repo\}/$owner_repo}"
  echo "$tpl"
}

# ------------------------------------------------------------------------------
# Internal adapter: gh → normalised JSON.
#
# Reads `gh issue view` JSON. The default view_command requests state, title,
# url, labels — labels comes back as an array of objects with .name keys, so
# we flatten to a string array.
# ------------------------------------------------------------------------------
_tracker_normalise_gh() {
  local raw="$1"
  if [ -z "$raw" ]; then
    return 1
  fi
  # If raw isn't valid JSON, bail.
  if ! echo "$raw" | jq -e . >/dev/null 2>&1; then
    return 1
  fi
  echo "$raw" | jq -c '{
    state:  (.state // ""),
    title:  (.title // ""),
    url:    (.url // ""),
    labels: ((.labels // []) | map(if type == "object" then .name else . end))
  }' 2>/dev/null
}

# ------------------------------------------------------------------------------
# Internal adapter: linear → normalised JSON.
#
# Documented assumption: `linear issue view <ID> --json` emits a JSON object
# with .state (or .state.name), .title, .url, .labels (array of strings or
# array of {name} objects). Both shapes are handled — older linear CLI
# versions returned strings; newer return objects.
# ------------------------------------------------------------------------------
_tracker_normalise_linear() {
  local raw="$1"
  if [ -z "$raw" ]; then return 1; fi
  if ! echo "$raw" | jq -e . >/dev/null 2>&1; then return 1; fi
  echo "$raw" | jq -c '{
    state:  ((.state | if type == "object" then .name else . end) // ""),
    title:  (.title // ""),
    url:    (.url // ""),
    labels: ((.labels // []) | map(if type == "object" then .name else . end))
  }' 2>/dev/null
}

# ------------------------------------------------------------------------------
# Internal adapter: jira → normalised JSON.
#
# Documented assumption: `jira issue view <ID> --raw` emits Jira's REST JSON
# with .fields.{summary,status.name,labels} and .self for the URL. The
# `jira` CLI (ankitpokhrel/jira-cli) is the de-facto standard.
# ------------------------------------------------------------------------------
_tracker_normalise_jira() {
  local raw="$1"
  if [ -z "$raw" ]; then return 1; fi
  if ! echo "$raw" | jq -e . >/dev/null 2>&1; then return 1; fi
  echo "$raw" | jq -c '{
    state:  ((.fields.status.name // .status // "") | tostring),
    title:  ((.fields.summary // .summary // .title // "") | tostring),
    url:    ((.self // .url // "") | tostring),
    labels: ((.fields.labels // .labels // []) | map(if type == "object" then .name else . end))
  }' 2>/dev/null
}

# ------------------------------------------------------------------------------
# Internal adapter: asana → normalised JSON.
#
# Documented assumption: `asana task get <gid> --json` emits {data: {name,
# completed, permalink_url, tags}}. State is derived from .completed
# (true → "Closed", false → "Open").
# ------------------------------------------------------------------------------
_tracker_normalise_asana() {
  local raw="$1"
  if [ -z "$raw" ]; then return 1; fi
  if ! echo "$raw" | jq -e . >/dev/null 2>&1; then return 1; fi
  echo "$raw" | jq -c '
    (.data // .) as $t |
    {
      state:  (if ($t.completed == true) then "Closed" else "Open" end),
      title:  ($t.name // ""),
      url:    ($t.permalink_url // ""),
      labels: (($t.tags // []) | map(if type == "object" then .name else . end))
    }
  ' 2>/dev/null
}

# ------------------------------------------------------------------------------
# Internal adapter: custom → pass-through.
#
# For operator-supplied templates, we assume the command itself emits JSON
# already shaped as {state, title, url, labels}. If it doesn't, the operator
# can also configure `.tracker.normalise_jq` (a jq expression) to map the
# raw output. Default is identity.
# ------------------------------------------------------------------------------
_tracker_normalise_custom() {
  local raw="$1"
  if [ -z "$raw" ]; then return 1; fi
  if ! echo "$raw" | jq -e . >/dev/null 2>&1; then return 1; fi

  _tracker_load_config_lib
  local jq_expr
  jq_expr=$(config_get_or '.tracker.normalise_jq' '.' 2>/dev/null)
  if [ -z "$jq_expr" ] || [ "$jq_expr" = "null" ]; then
    jq_expr='.'
  fi
  echo "$raw" | jq -c "$jq_expr" 2>/dev/null
}

# ------------------------------------------------------------------------------
# Public: tracker_view <id> [<owner_repo>]
#   Dispatches the view command and emits normalised JSON. Exit 0 if the
#   ticket exists (and CLI succeeded). Non-zero if the ticket doesn't
#   exist, the CLI is missing / unauthenticated, or the kind is "none".
#
#   On non-zero exit, no JSON is emitted on stdout (so callers can treat
#   empty stdout as "missing").
# ------------------------------------------------------------------------------
tracker_view() {
  local id="$1"
  local owner_repo="${2:-}"
  if [ -z "$id" ]; then
    return 1
  fi

  local kind
  kind=$(tracker_kind)

  case "$kind" in
    none)
      # Existence verification disabled. Caller falls back to shape check.
      return 1
      ;;
  esac

  # jq is required for normalisation. Without it, the tracker lib can't
  # produce its contract output — exit non-zero so callers can fall back.
  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi

  local tpl cmd raw rc
  tpl=$(_tracker_view_template)
  cmd=$(_tracker_substitute "$tpl" "$id" "$owner_repo")

  # Run the command; capture stdout. Suppress stderr (CLI errors are visible
  # via exit code and absence-of-output).
  raw=$(eval "$cmd" 2>/dev/null)
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$raw" ]; then
    return 1
  fi

  local normalised
  case "$kind" in
    gh)     normalised=$(_tracker_normalise_gh "$raw") ;;
    linear) normalised=$(_tracker_normalise_linear "$raw") ;;
    jira)   normalised=$(_tracker_normalise_jira "$raw") ;;
    asana)  normalised=$(_tracker_normalise_asana "$raw") ;;
    custom) normalised=$(_tracker_normalise_custom "$raw") ;;
    *)
      # Unknown kind: try gh shape as a best-effort default.
      normalised=$(_tracker_normalise_gh "$raw")
      ;;
  esac

  if [ -z "$normalised" ] || [ "$normalised" = "null" ]; then
    return 1
  fi

  echo "$normalised"
  return 0
}

# ------------------------------------------------------------------------------
# Public: tracker_state <id> [<owner_repo>]
#   Convenience: prints just the normalised state field, or empty if the
#   ticket doesn't exist. Exit code matches tracker_view.
# ------------------------------------------------------------------------------
tracker_state() {
  local json
  json=$(tracker_view "$@") || return $?
  echo "$json" | jq -r '.state // empty' 2>/dev/null
}

# ------------------------------------------------------------------------------
# Public: tracker_clear_cache
#   Reset all per-process caches. Used by tests; rarely needed elsewhere.
# ------------------------------------------------------------------------------
tracker_clear_cache() {
  _TRACKER_KIND_CACHE=""
  _TRACKER_ID_PATTERN_CACHE=""
  _TRACKER_VIEW_TPL_CACHE=""
}
