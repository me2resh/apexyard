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
#   tracker_kind [<owner/repo>]        echoes the configured tracker kind
#   tracker_id_pattern [<owner/repo>]  echoes the configured ID regex
#   tracker_owner_repo_param <slug>    formats the owner/repo parameter (gh: "owner/repo"; others: empty)
#   tracker_view <id> [<owner_repo>]   dispatches the view command and emits normalised JSON on stdout
#                                      Exit 0 = ticket exists; non-zero = doesn't, or CLI errored.
#                                      JSON shape: {"state":..., "title":..., "url":..., "labels":[...], "body":...}
#                                      `body` is populated for the gh, glab, jira, linear, and asana
#                                      adapters — every built-in kind the migration gate (which reads
#                                      the body to find the linked AgDR, #755/#761) can query. jira's
#                                      `.fields.description` may be ADF (a JSON object, not a string)
#                                      on Jira Cloud; the adapter flattens ADF text nodes to plain
#                                      text so the body stays grep-able (Jira Server/DC returns a
#                                      plain string, passed through). The `custom` adapter still omits
#                                      body unless the operator's `normalise_jq` emits one (consumers
#                                      read it as `.body // empty`).
#   tracker_create <owner/repo> <title> [<body_file>] [<labels_csv>]
#                                      creates a ticket via the per-project CLI; emits {ref,url}.
#   tracker_review_submit <owner/repo> <pr> <verdict> [<body_file>]  (#758)
#                                      submits a PR/MR review to the git host. verdict is one of
#                                      approve|comment|request-changes (default comment). gh + glab
#                                      adapters built in, `custom` review_command template, `none`
#                                      no-op (returns 3, echoes body). Exit 0 = submitted; non-zero
#                                      = CLI errored; 3 = shape-only (kind=none, nothing to call).
#   tracker_pr_merge <owner/repo> <pr> <strategy> [<delete_branch>]  (#759)
#                                      merges a PR/MR via the git host. strategy is one of
#                                      squash|merge|rebase (default squash, normalised — never
#                                      eval'd raw); delete_branch is true|false (default true). gh +
#                                      glab adapters built in, `custom` merge_command template,
#                                      `none` no-op (returns 3). Exit 0 = merged, emits normalised
#                                      JSON {"sha":...} (the merge commit, best-effort — empty for
#                                      `custom`); non-zero = CLI errored / blocked; 3 = shape-only
#                                      (kind=none, nothing to call).
#
# Per-project resolution (#670 / AgDR-0072): tracker_kind / tracker_id_pattern /
# tracker_view take an OPTIONAL owner/repo. When supplied, a `tracker:` block on
# that project's apexyard.projects.yaml entry overrides the global config block
# (per key); when omitted, the global block is used — byte-for-byte the original
# behaviour. The project is chosen by the OPERATION'S TARGET REPO the caller
# already holds — never by cwd or a session-global marker.
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
# Internal: ensure _lib-portfolio-paths.sh is loaded so portfolio_registry works.
# ------------------------------------------------------------------------------
_tracker_load_portfolio_lib() {
  if command -v portfolio_registry >/dev/null 2>&1; then
    return 0
  fi
  local hook_dir
  hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$hook_dir/_lib-portfolio-paths.sh" ]; then
    # shellcheck source=/dev/null
    . "$hook_dir/_lib-portfolio-paths.sh"
  fi
}

# ------------------------------------------------------------------------------
# Internal: _tracker_project_value <owner/repo> <key>
#   Reads `.projects[] | select(.repo == <owner/repo>) | .tracker.<key>` from the
#   portfolio registry (apexyard.projects.yaml) — the per-project override for
#   one tracker key (kind / id_pattern / view_command / create_command).
#
#   The project is selected by the OPERATION'S TARGET REPO passed in by the
#   caller — never by cwd or a session-global marker (see AgDR-0072 / #670).
#
#   Echoes the value and exits 0 when a non-empty override exists; exits 1
#   (empty stdout) otherwise — so callers fall back to the global config block.
#
#   YAML is read via `yq` (mikefarah, matching _lib-portfolio-paths.sh) with a
#   `python3`+PyYAML fallback. If neither can parse, the lookup returns 1 and the
#   caller degrades to the global tracker config — single-tracker forks unaffected.
# ------------------------------------------------------------------------------
_tracker_project_value() {
  local repo="$1" key="$2"
  [ -n "$repo" ] && [ -n "$key" ] || return 1
  _tracker_load_portfolio_lib
  command -v portfolio_registry >/dev/null 2>&1 || return 1
  local registry
  registry=$(portfolio_registry 2>/dev/null)
  [ -n "$registry" ] && [ -f "$registry" ] || return 1

  local val=""
  if command -v yq >/dev/null 2>&1; then
    # Pass the repo via env + strenv() so an odd repo value can never break out
    # of the yq expression (defense-in-depth — a real owner/repo can't contain a
    # quote, but the python3 path below is argv-safe, so match it here). $key is
    # always a hardcoded literal from callers (kind / id_pattern / view_command),
    # so substituting it into the path is safe.
    val=$(REPO="$repo" yq eval ".projects[] | select(.repo == strenv(REPO)) | .tracker.$key // \"\"" "$registry" 2>/dev/null | head -1)
  fi
  if { [ -z "$val" ] || [ "$val" = "null" ]; } && command -v python3 >/dev/null 2>&1; then
    val=$(python3 - "$registry" "$repo" "$key" <<'PY' 2>/dev/null
import sys
try:
    import yaml
except Exception:
    sys.exit(0)
reg, repo, key = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    doc = yaml.safe_load(open(reg)) or {}
except Exception:
    sys.exit(0)
for p in (doc.get("projects") or []):
    if p.get("repo") == repo:
        v = (p.get("tracker") or {}).get(key)
        if v is not None:
            print(v)
        break
PY
)
  fi

  if [ -z "$val" ] || [ "$val" = "null" ]; then
    return 1
  fi
  echo "$val"
}

# ------------------------------------------------------------------------------
# Public: tracker_kind [<owner/repo>]
#   Echoes the configured tracker kind. With an optional <owner/repo>, a
#   per-project `tracker.kind` override in the registry wins; otherwise the
#   global config block (default "gh"). The no-arg path is byte-for-byte the
#   original behaviour (cached).
# ------------------------------------------------------------------------------
_TRACKER_KIND_CACHE=""
tracker_kind() {
  local repo="${1:-}"
  if [ -n "$repo" ]; then
    local pv
    if pv=$(_tracker_project_value "$repo" kind) && [ -n "$pv" ]; then
      echo "$pv"
      return 0
    fi
  fi
  if [ -z "$repo" ] && [ -n "$_TRACKER_KIND_CACHE" ]; then
    echo "$_TRACKER_KIND_CACHE"
    return 0
  fi
  _tracker_load_config_lib
  local k
  k=$(config_get_or '.tracker.kind' 'gh' 2>/dev/null)
  if [ -z "$k" ] || [ "$k" = "null" ]; then
    k="gh"
  fi
  if [ -z "$repo" ]; then
    _TRACKER_KIND_CACHE="$k"
  fi
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
  local repo="${1:-}"
  if [ -n "$repo" ]; then
    local pv
    if pv=$(_tracker_project_value "$repo" id_pattern) && [ -n "$pv" ]; then
      echo "$pv"
      return 0
    fi
  fi
  if [ -z "$repo" ] && [ -n "$_TRACKER_ID_PATTERN_CACHE" ]; then
    echo "$_TRACKER_ID_PATTERN_CACHE"
    return 0
  fi
  _tracker_load_config_lib
  local p
  p=$(config_get_or '.tracker.id_pattern' '^(#[0-9]+|GH-[0-9]+|[A-Z]{2,10}-[0-9]+)$' 2>/dev/null)
  if [ -z "$p" ] || [ "$p" = "null" ]; then
    p='^(#[0-9]+|GH-[0-9]+|[A-Z]{2,10}-[0-9]+)$'
  fi
  if [ -z "$repo" ]; then
    _TRACKER_ID_PATTERN_CACHE="$p"
  fi
  echo "$p"
}

# ------------------------------------------------------------------------------
# Internal: read the configured view_command template. Default matches today's
# behaviour exactly (GH CLI shape).
# ------------------------------------------------------------------------------
_TRACKER_VIEW_TPL_CACHE=""
_tracker_view_template() {
  local repo="${1:-}" kind="${2:-}"
  if [ -n "$repo" ]; then
    local pv
    if pv=$(_tracker_project_value "$repo" view_command) && [ -n "$pv" ]; then
      echo "$pv"
      return 0
    fi
  fi
  if [ -z "$repo" ] && [ -n "$_TRACKER_VIEW_TPL_CACHE" ]; then
    echo "$_TRACKER_VIEW_TPL_CACHE"
    return 0
  fi
  _tracker_load_config_lib
  local tpl
  # An explicit .tracker.view_command (registry per-project or config) always
  # wins. With none set, fall back to a per-KIND built-in default: glab gets a
  # first-class GitLab command (parity with _tracker_create_glab, #755); every
  # other kind gets the gh shape. linear/jira/asana adopters still supply their
  # own view_command (unchanged contract) — they only land on the gh default if
  # they forgot to set one. The default view_command is deliberately NOT pinned
  # in project-config.defaults.json, so this kind-aware fallback can fire (a
  # pinned default would deep-merge over a glab adopter's `kind: glab` and force
  # the gh command — the exact #755 bug at the config layer).
  tpl=$(config_get_or '.tracker.view_command' '' 2>/dev/null)
  if [ -z "$tpl" ] || [ "$tpl" = "null" ]; then
    case "$kind" in
      glab) tpl='glab issue view {id} -R {owner_repo} --output json' ;;
      *)    tpl='gh issue view {id} --repo {owner_repo} --json state,title,url,labels,body' ;;
    esac
  fi
  if [ -z "$repo" ]; then
    _TRACKER_VIEW_TPL_CACHE="$tpl"
  fi
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
#
# The substituted string is run via `eval` in tracker_view, so the {id} /
# {owner_repo} values must not be able to inject command syntax. Both are
# shell-quoted with `printf %q` before substitution — a no-op for legitimate
# ticket IDs / owner-repo slugs, and a neutraliser for anything containing shell
# metacharacters. This is defence-in-depth behind each caller's own shape check:
# validate-pr-create.sh / require-migration-ticket.sh validate before calling in,
# but quoting here guarantees a future caller that forwards unvalidated input into
# tracker_view can't reopen the injection hole. (#755 security review — Rex/Hakim.)
# ------------------------------------------------------------------------------
_tracker_substitute() {
  local tpl="$1" id="$2" owner_repo="$3"
  local q_id q_owner_repo
  # printf -v is available in bash 3.2 (macOS default); %q shell-escapes.
  printf -v q_id '%q' "$id"
  printf -v q_owner_repo '%q' "$owner_repo"
  # Use POSIX parameter expansion — portable across bash 3.2 (macOS default).
  tpl="${tpl//\{id\}/$q_id}"
  tpl="${tpl//\{owner_repo\}/$q_owner_repo}"
  echo "$tpl"
}

# ------------------------------------------------------------------------------
# Internal adapter: gh → normalised JSON.
#
# Reads `gh issue view` JSON. The default view_command requests state, title,
# url, labels, body — labels comes back as an array of objects with .name keys,
# so we flatten to a string array; body is passed through verbatim.
# ------------------------------------------------------------------------------
_tracker_normalise_gh() {
  local raw="$1"
  if [ -z "$raw" ]; then
    return 1
  fi
  # If raw isn't valid JSON, bail.
  if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    return 1
  fi
  printf '%s' "$raw" | jq -c '{
    state:  (.state // ""),
    title:  (.title // ""),
    url:    (.url // ""),
    labels: ((.labels // []) | map(if type == "object" then .name else . end)),
    body:   (.body // "")
  }' 2>/dev/null
}

# ------------------------------------------------------------------------------
# Internal adapter: glab (GitLab) → normalised JSON.
#
# `glab issue view <id> -R <repo> --output json` emits the GitLab REST issue
# object: .state is "opened"/"closed", .web_url is the URL, .description is the
# body, and .labels is already an array of strings. State is normalised to
# OPEN/CLOSED for contract parity with the gh adapter (downstream closed-state
# classification is case-insensitive, so either casing works — parity is for
# consumers that read .state directly). glab is a first-class view kind
# alongside gh, mirroring the existing _tracker_create_glab creation adapter.
# ------------------------------------------------------------------------------
_tracker_normalise_glab() {
  local raw="$1"
  if [ -z "$raw" ]; then return 1; fi
  if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then return 1; fi
  printf '%s' "$raw" | jq -c '{
    state:  ((.state // "") | if . == "opened" then "OPEN" elif . == "closed" then "CLOSED" else (. | ascii_upcase) end),
    title:  (.title // ""),
    url:    (.web_url // .url // ""),
    labels: ((.labels // []) | map(if type == "object" then .name else . end)),
    body:   (.description // .body // "")
  }' 2>/dev/null
}

# ------------------------------------------------------------------------------
# Internal adapter: linear → normalised JSON.
#
# Documented assumption: `linear issue view <ID> --json` emits a JSON object
# with .state (or .state.name), .title, .url, .labels (array of strings or
# array of {name} objects), and .description (a markdown string). Both label
# shapes are handled — older linear CLI versions returned strings; newer return
# objects. body maps to .description so the migration gate can read the linked
# AgDR (#761).
# ------------------------------------------------------------------------------
_tracker_normalise_linear() {
  local raw="$1"
  if [ -z "$raw" ]; then return 1; fi
  if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then return 1; fi
  printf '%s' "$raw" | jq -c '{
    state:  ((.state | if type == "object" then .name else . end) // ""),
    title:  (.title // ""),
    url:    (.url // ""),
    labels: ((.labels // []) | map(if type == "object" then .name else . end)),
    body:   (.description // "")
  }' 2>/dev/null
}

# ------------------------------------------------------------------------------
# Internal adapter: jira → normalised JSON.
#
# Documented assumption: `jira issue view <ID> --raw` emits Jira's REST JSON
# with .fields.{summary,status.name,labels,description} and .self for the URL.
# The `jira` CLI (ankitpokhrel/jira-cli) is the de-facto standard.
#
# body maps to .fields.description (#761). Jira Cloud returns the description as
# ADF — Atlassian Document Format, a JSON object ({type:"doc",content:[…]}), not
# a string — so a naive pass-through would emit an unusable object and the
# migration gate could never grep an AgDR link out of it. The `if type` branch
# below flattens ADF: it recursively collects every `text` leaf from the content
# tree (`[.. | .text? // empty]`) and joins them with newlines, yielding
# grep-able plain text. Jira Server / Data Center returns description as a plain
# string, which the string branch passes through verbatim. A missing/null
# description degrades to "".
# ------------------------------------------------------------------------------
_tracker_normalise_jira() {
  local raw="$1"
  if [ -z "$raw" ]; then return 1; fi
  if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then return 1; fi
  printf '%s' "$raw" | jq -c '{
    state:  ((.fields.status.name // .status // "") | tostring),
    title:  ((.fields.summary // .summary // .title // "") | tostring),
    url:    ((.self // .url // "") | tostring),
    labels: ((.fields.labels // .labels // []) | map(if type == "object" then .name else . end)),
    body:   (
      (.fields.description // .description // "") as $d |
      if ($d | type) == "string" then $d
      elif ($d | type) == "object" then ([$d | .. | .text? // empty] | join("\n"))
      else "" end
    )
  }' 2>/dev/null
}

# ------------------------------------------------------------------------------
# Internal adapter: asana → normalised JSON.
#
# Documented assumption: `asana task get <gid> --json` emits {data: {name,
# completed, permalink_url, tags, notes}}. State is derived from .completed
# (true → "Closed", false → "Open"). body maps to .notes (Asana's plain-text
# task description), falling back to .html_notes when only the rich-text form is
# present, so the migration gate can read the linked AgDR (#761).
# ------------------------------------------------------------------------------
_tracker_normalise_asana() {
  local raw="$1"
  if [ -z "$raw" ]; then return 1; fi
  if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then return 1; fi
  printf '%s' "$raw" | jq -c '
    (.data // .) as $t |
    {
      state:  (if ($t.completed == true) then "Closed" else "Open" end),
      title:  ($t.name // ""),
      url:    ($t.permalink_url // ""),
      labels: (($t.tags // []) | map(if type == "object" then .name else . end)),
      body:   ($t.notes // $t.html_notes // "")
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
  if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then return 1; fi

  _tracker_load_config_lib
  local jq_expr
  jq_expr=$(config_get_or '.tracker.normalise_jq' '.' 2>/dev/null)
  if [ -z "$jq_expr" ] || [ "$jq_expr" = "null" ]; then
    jq_expr='.'
  fi
  printf '%s' "$raw" | jq -c "$jq_expr" 2>/dev/null
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

  # Per-project resolution: when an owner_repo is supplied, the tracker kind
  # and view_command come from that project's registry override (if any),
  # falling back to the global config block. See AgDR-0072 / #670.
  local kind
  kind=$(tracker_kind "$owner_repo")

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
  tpl=$(_tracker_view_template "$owner_repo" "$kind")
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
    glab)   normalised=$(_tracker_normalise_glab "$raw") ;;
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
  printf '%s' "$json" | jq -r '.state // empty' 2>/dev/null
}

# ==============================================================================
# Creation (tracker_create) — the #670 / AgDR-0072 creation abstraction.
#
# tracker_create is the creation analog of tracker_view. Unlike view (which only
# substitutes the simple {id}/{owner_repo} tokens), create carries an ARBITRARY
# title + body. So tracker_create is a FUNCTION taking args — title/labels pass
# as proper `--flag "$val"` arguments and the body via `--body-file` — NEVER a
# string-templated eval of the title/body. Built-in adapters cover gh + glab;
# the `create_command` TEMPLATE is reserved for the trusted `custom` kind (same
# trust class as view_command's custom adapter).
#
# Contract: tracker_create <owner/repo> <title> [<body_file>] [<labels_csv>]
#   On success: emits normalised JSON {"ref":..., "url":...} on stdout, exit 0.
#     - ref is the tracker's issue reference as a STRING (callers must not do
#       arithmetic on it — a future tracker may return a key like LIN-42). The
#       built-in gh/glab adapters below emit the trailing NUMBER; trackers with
#       non-numeric keys supply their own adapter + extractor (Part C).
#   On failure (CLI missing/errored, kind=none, no parseable result): exit 1,
#     empty stdout — callers treat empty as "not created".
# ------------------------------------------------------------------------------

# Internal: parse a gh/glab create output into {ref, url}. gh prints just the
# issue URL; glab prints several lines including it. Finds the issue URL and
# derives the ref from its trailing NUMERIC path segment — sufficient for gh and
# glab. Trackers with non-numeric keys (Linear LIN-42, Jira PROJ-789) need a
# dedicated extractor in their own adapter (Part C), not this numeric helper.
_tracker_extract_ref_url() {
  local raw="$1" url ref
  url=$(printf '%s\n' "$raw" | grep -oE 'https?://[^[:space:]]+' | grep -E '/issues/[0-9]+' | head -1)
  if [ -z "$url" ]; then
    return 1
  fi
  ref=$(printf '%s' "$url" | grep -oE '[0-9]+$')
  jq -nc --arg ref "$ref" --arg url "$url" '{ref:$ref, url:$url}' 2>/dev/null
}

# Internal adapter: gh → run `gh issue create` with safe arg passing.
_tracker_create_gh() {
  local repo="$1" title="$2" body_file="$3" labels="$4"
  local -a args
  args=(issue create --repo "$repo" --title "$title")
  if [ -n "$body_file" ] && [ -f "$body_file" ]; then
    args+=(--body-file "$body_file")
  fi
  if [ -n "$labels" ]; then
    local l
    local IFS=','
    for l in $labels; do
      [ -n "$l" ] && args+=(--label "$l")
    done
  fi
  gh "${args[@]}" 2>/dev/null
}

# Internal adapter: glab (GitLab) → `glab issue create`. GitLab's CLI has no
# --body-file, so the body is passed via --description with the file contents
# as a single quoted arg (injection-safe — not re-evaluated). Labels are a
# single comma-separated --label value. --yes skips the interactive prompt.
_tracker_create_glab() {
  local repo="$1" title="$2" body_file="$3" labels="$4"
  local -a args
  args=(issue create -R "$repo" --title "$title")
  if [ -n "$body_file" ] && [ -f "$body_file" ]; then
    args+=(--description "$(cat "$body_file")")
  fi
  if [ -n "$labels" ]; then
    args+=(--label "$labels")
  fi
  args+=(--yes)
  glab "${args[@]}" 2>/dev/null
}

# Internal: resolve the create_command template for the `custom` kind — the
# per-project override (registry) wins over a global .tracker.create_command.
# Empty when neither is set (custom kind without a template can't create).
_tracker_create_template() {
  local repo="${1:-}"
  if [ -n "$repo" ]; then
    local pv
    if pv=$(_tracker_project_value "$repo" create_command) && [ -n "$pv" ]; then
      echo "$pv"
      return 0
    fi
  fi
  _tracker_load_config_lib
  local tpl
  tpl=$(config_get_or '.tracker.create_command' '' 2>/dev/null)
  if [ -n "$tpl" ] && [ "$tpl" != "null" ]; then
    echo "$tpl"
  fi
}

# Internal adapter: custom → operator-supplied create_command template.
#
# Injection model (deliberate): this is the ONE eval path in tracker_create, and
# it is scoped to the trusted, operator-authored `custom` template. Only the
# {owner_repo} placeholder — a safe slug — is substituted into the command
# string. The arbitrary values (title / body file / labels) are exposed as
# ENVIRONMENT VARIABLES ($TRACKER_TITLE / $TRACKER_BODY_FILE / $TRACKER_LABELS)
# that the operator references with double-quoted expansions — so they are
# quoted VALUES at eval time, never re-tokenised as command syntax. A title full
# of `; rm -rf …` is inert. The custom command is expected to emit the issue URL
# on stdout (parsed like gh/glab).
#
# Note: {owner_repo} IS substituted into the eval'd string. This is the same
# trust model as view_command — owner_repo is a registry-sourced slug (trusted
# config authored by the maintainer), not agent/user-supplied free text. Only
# the arbitrary, untrusted values (title/body/labels) go via env.
_tracker_create_custom() {
  local repo="$1" title="$2" body_file="$3" labels="$4"
  local tpl
  tpl=$(_tracker_create_template "$repo")
  if [ -z "$tpl" ]; then
    return 1
  fi
  local cmd="$tpl"
  cmd="${cmd//\{owner_repo\}/$repo}"
  TRACKER_REPO="$repo" TRACKER_TITLE="$title" TRACKER_BODY_FILE="$body_file" TRACKER_LABELS="$labels" \
    eval "$cmd" 2>/dev/null
}

# Public: tracker_create <owner/repo> <title> [<body_file>] [<labels_csv>]
tracker_create() {
  local repo="$1" title="$2" body_file="${3:-}" labels="${4:-}"
  if [ -z "$repo" ] || [ -z "$title" ]; then
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi

  local kind
  kind=$(tracker_kind "$repo")
  case "$kind" in
    none)
      # Shape-only mode (tracker.kind=none): no tracker CLI to call. Emit the
      # rendered ticket body to stdout so the operator can file it in their
      # external system, and return 3 (a documented "shape-only / file
      # externally" code) so callers don't misreport it as a CLI/auth error.
      if [ -n "$body_file" ] && [ -f "$body_file" ]; then
        cat "$body_file"
      fi
      return 3
      ;;
  esac

  local raw rc
  case "$kind" in
    gh)     raw=$(_tracker_create_gh     "$repo" "$title" "$body_file" "$labels"); rc=$? ;;
    glab)   raw=$(_tracker_create_glab   "$repo" "$title" "$body_file" "$labels"); rc=$? ;;
    custom) raw=$(_tracker_create_custom "$repo" "$title" "$body_file" "$labels"); rc=$? ;;
    *)      raw=$(_tracker_create_gh     "$repo" "$title" "$body_file" "$labels"); rc=$? ;;  # best-effort default
  esac
  if [ $rc -ne 0 ] || [ -z "$raw" ]; then
    return 1
  fi

  local result
  result=$(_tracker_extract_ref_url "$raw")
  if [ -z "$result" ] || [ "$result" = "null" ]; then
    return 1
  fi
  echo "$result"
}

# ==============================================================================
# Listing (tracker_list) — the #710 / AgDR-0093 read/triage abstraction.
#
# tracker_list is the listing analog of tracker_view: it lists a SET of issues
# from a project's tracker via that tracker's CLI adapter. The read-side skills
# (/inbox, /tasks, /stakeholder-update) call it instead of hardcoding
# `gh issue list`, so they work on GitLab-tracked projects too.
#
# Design (AgDR-0093): callers express intent in a small GENERIC filter
# vocabulary; each per-kind adapter renders those generic filters into its own
# native CLI flags. We do NOT parse GitHub's search string and translate it —
# that would couple the model to GitHub's DSL. Filters with no cross-tracker
# equivalent (mentions:, commenter:) stay OUT of this model; skills that want
# them keep a gh-only path (documented) or filter client-side.
#
# Contract: tracker_list <owner/repo> [key=value ...]
#   Filter keys (all optional): state | assignee | author | labels | search |
#                               since | limit
#     state    = open (default) | closed | all
#     assignee = @me | none | <user>   (none: gh via no:assignee; glab degrades)
#     author   = @me | <user>
#     labels   = comma-separated (AND semantics, per each CLI's native behaviour)
#     search   = free text
#     since    = ISO date (gh: search qualifier; others: client-side updatedAt)
#     limit    = max items
#   On success: emits a JSON ARRAY on stdout, exit 0. Each element:
#     {"ref":str, "number":num, "state":str, "title":str, "url":str,
#      "labels":[str], "updatedAt":str}
#     - ref is the issue reference AS A STRING (callers must not do arithmetic —
#       a future tracker may key LIN-42). number is the numeric convenience.
#     - PR-only fields (mergeable/statusCheckRollup/reviewDecision) are excluded
#       by design — those are the forge axis (#711), not the issue axis.
#     - An empty result set is `[]` with exit 0 (success, nothing matched).
#   On failure (CLI missing/errored, kind=none, unparseable): emits `[]` and
#     exits 1 — callers treat empty output as "nothing / unavailable" uniformly.
#
# Filter args are parsed via a `case` statement into plain locals — bash 3.2-safe
# (no `declare -A`), matching the POSIX-parameter-expansion constraint elsewhere
# in this file. linear/jira/asana list adapters are a documented follow-up (the
# #710 parent stack targets GitHub↔GitLab); until then they fall through to the
# gh best-effort default (consistent with `tracker_view` / `tracker_create`).
# ------------------------------------------------------------------------------

# Internal: resolve the list_command template for the `custom` kind — the
# per-project override (registry) wins over a global .tracker.list_command.
# Empty when neither is set (custom kind without a template can't list).
_tracker_list_template() {
  local repo="${1:-}"
  if [ -n "$repo" ]; then
    local pv
    if pv=$(_tracker_project_value "$repo" list_command) && [ -n "$pv" ]; then
      echo "$pv"
      return 0
    fi
  fi
  _tracker_load_config_lib
  local tpl
  tpl=$(config_get_or '.tracker.list_command' '' 2>/dev/null)
  if [ -n "$tpl" ] && [ "$tpl" != "null" ]; then
    echo "$tpl"
  fi
}

# Internal adapter: gh → run `gh issue list --json …` with safe argv.
# Structured filters map to gh's native flags; `assignee=none` and `since` have
# no dedicated flag, so they append `no:assignee` / `closed:>=`|`updated:>=`
# qualifiers to the --search string (gh merges --search with the other flags).
_tracker_list_gh() {
  local repo="$1" state="$2" assignee="$3" author="$4" labels="$5" search="$6" since="$7" limit="$8"
  local -a args
  # Quote the comma-separated field list so shellcheck doesn't read the commas as
  # array-element separators (SC2054); gh takes it as a single argument either way.
  args=(issue list --repo "$repo" --json "number,title,url,labels,state,updatedAt")
  case "$state" in
    open|closed|all) args+=(--state "$state") ;;
    *)               args+=(--state open) ;;
  esac
  if [ -n "$assignee" ]; then
    case "$assignee" in
      none) search="${search:+$search }no:assignee" ;;
      *)    args+=(--assignee "$assignee") ;;
    esac
  fi
  [ -n "$author" ] && args+=(--author "$author")
  [ -n "$labels" ] && args+=(--label "$labels")
  if [ -n "$since" ]; then
    if [ "$state" = "closed" ]; then
      search="${search:+$search }closed:>=$since"
    else
      search="${search:+$search }updated:>=$since"
    fi
  fi
  [ -n "$search" ] && args+=(--search "$search")
  [ -n "$limit" ]  && args+=(--limit "$limit")
  gh "${args[@]}" 2>/dev/null
}

# Internal adapter: glab (GitLab) → `glab issue list -O json`. Flags verified
# against `glab issue list --help`: --assignee/--author/--label(repeatable)/
# --search+--in/--opened|--closed|--all/--per-page. `assignee=none` has no clean
# glab flag → degrades (dropped); `since` is applied CLIENT-SIDE by tracker_list.
_tracker_list_glab() {
  local repo="$1" state="$2" assignee="$3" author="$4" labels="$5" search="$6" since="$7" limit="$8"
  local -a args
  args=(issue list -R "$repo" -O json)
  case "$state" in
    closed) args+=(--closed) ;;
    all)    args+=(--all) ;;
    *)      args+=(--opened) ;;
  esac
  if [ -n "$assignee" ]; then
    case "$assignee" in
      none) : ;;  # no clean glab flag — documented degradation (AgDR-0093)
      *)    args+=(--assignee "$assignee") ;;
    esac
  fi
  [ -n "$author" ] && args+=(--author "$author")
  if [ -n "$labels" ]; then
    local l
    local IFS=','
    for l in $labels; do
      [ -n "$l" ] && args+=(--label "$l")
    done
  fi
  if [ -n "$search" ]; then
    args+=(--search "$search" --in "title,description")
  fi
  [ -n "$limit" ] && args+=(--per-page "$limit")
  glab "${args[@]}" 2>/dev/null
}

# Internal adapter: custom → operator-supplied list_command template. Same trust
# model as create: only {owner_repo} is substituted into the eval'd string; the
# filter values pass via ENV ($TRACKER_STATE / $TRACKER_ASSIGNEE / … ) that the
# operator references with quoted expansions — inert as command syntax. The
# custom command is expected to emit a JSON array (normalised via identity, or a
# configured .tracker.list_normalise_jq).
_tracker_list_custom() {
  local repo="$1" state="$2" assignee="$3" author="$4" labels="$5" search="$6" since="$7" limit="$8"
  local tpl
  tpl=$(_tracker_list_template "$repo")
  if [ -z "$tpl" ]; then
    return 1
  fi
  local cmd="$tpl"
  cmd="${cmd//\{owner_repo\}/$repo}"
  TRACKER_REPO="$repo" TRACKER_STATE="$state" TRACKER_ASSIGNEE="$assignee" TRACKER_AUTHOR="$author" \
    TRACKER_LABELS="$labels" TRACKER_SEARCH="$search" TRACKER_SINCE="$since" TRACKER_LIMIT="$limit" \
    eval "$cmd" 2>/dev/null
}

# Internal: normalise a gh `issue list --json` array → common array shape.
_tracker_normalise_list_gh() {
  local raw="$1"
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s' "$raw" | jq -c 'map({
    ref:       (.number | tostring),
    number:    .number,
    state:     (.state // ""),
    title:     (.title // ""),
    url:       (.url // ""),
    labels:    ((.labels // []) | map(if type == "object" then .name else . end)),
    updatedAt: (.updatedAt // "")
  })' 2>/dev/null
}

# Internal: normalise a glab `issue list -O json` array → common array shape.
# GitLab's REST JSON uses iid / web_url / updated_at, and labels as a string
# array. state is "opened"/"closed" — normalised to that string verbatim.
_tracker_normalise_list_glab() {
  local raw="$1"
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s' "$raw" | jq -c 'map({
    ref:       ((.iid // .id) | tostring),
    number:    (.iid // .id),
    state:     (.state // ""),
    title:     (.title // ""),
    url:       (.web_url // .url // ""),
    labels:    ((.labels // []) | map(if type == "object" then .name else . end)),
    updatedAt: (.updated_at // .updatedAt // "")
  })' 2>/dev/null
}

# Internal: normalise a custom list output. The operator's command is expected
# to emit an already-shaped JSON array; an optional .tracker.list_normalise_jq
# maps a different raw shape. Default is identity.
_tracker_normalise_list_custom() {
  local raw="$1"
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | jq -e . >/dev/null 2>&1 || return 1
  _tracker_load_config_lib
  local jq_expr
  jq_expr=$(config_get_or '.tracker.list_normalise_jq' '.' 2>/dev/null)
  if [ -z "$jq_expr" ] || [ "$jq_expr" = "null" ]; then
    jq_expr='.'
  fi
  printf '%s' "$raw" | jq -c "$jq_expr" 2>/dev/null
}

# Public: tracker_list <owner/repo> [key=value ...]
tracker_list() {
  local repo="$1"
  shift 2>/dev/null || true
  if [ -z "$repo" ]; then
    printf '[]\n'
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '[]\n'
    return 1
  fi

  # Parse key=value filter args into plain locals (bash 3.2-safe).
  local f_state="" f_assignee="" f_author="" f_labels="" f_search="" f_since="" f_limit=""
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    case "$key" in
      state)        f_state="$val" ;;
      assignee)     f_assignee="$val" ;;
      author)       f_author="$val" ;;
      labels|label) f_labels="$val" ;;
      search)       f_search="$val" ;;
      since)        f_since="$val" ;;
      limit)        f_limit="$val" ;;
    esac
  done

  # Per-project resolution: the target repo selects the project's tracker
  # override, else the global block (never cwd, never a session marker).
  local kind
  kind=$(tracker_kind "$repo")
  case "$kind" in
    none)
      printf '[]\n'
      return 1
      ;;
  esac

  local raw rc
  case "$kind" in
    gh)     raw=$(_tracker_list_gh     "$repo" "$f_state" "$f_assignee" "$f_author" "$f_labels" "$f_search" "$f_since" "$f_limit"); rc=$? ;;
    glab)   raw=$(_tracker_list_glab   "$repo" "$f_state" "$f_assignee" "$f_author" "$f_labels" "$f_search" "$f_since" "$f_limit"); rc=$? ;;
    custom) raw=$(_tracker_list_custom "$repo" "$f_state" "$f_assignee" "$f_author" "$f_labels" "$f_search" "$f_since" "$f_limit"); rc=$? ;;
    *)      raw=$(_tracker_list_gh     "$repo" "$f_state" "$f_assignee" "$f_author" "$f_labels" "$f_search" "$f_since" "$f_limit"); rc=$? ;;  # best-effort default
  esac
  if [ $rc -ne 0 ] || [ -z "$raw" ]; then
    printf '[]\n'
    return 1
  fi

  local normalised
  case "$kind" in
    gh)     normalised=$(_tracker_normalise_list_gh     "$raw") ;;
    glab)   normalised=$(_tracker_normalise_list_glab   "$raw") ;;
    custom) normalised=$(_tracker_normalise_list_custom "$raw") ;;
    *)      normalised=$(_tracker_normalise_list_gh     "$raw") ;;
  esac
  if [ -z "$normalised" ] || [ "$normalised" = "null" ]; then
    printf '[]\n'
    return 1
  fi

  # Client-side `since` for adapters that don't apply it server-side (glab /
  # custom). gh already handled it via the search qualifier above. Items with no
  # `updatedAt` are KEPT (not silently dropped) — recency is unknowable for them,
  # and hiding an item the user can't date is worse than surfacing it. Only items
  # with a known, older `updatedAt` are filtered out.
  if [ -n "$f_since" ] && [ "$kind" != "gh" ]; then
    normalised=$(printf '%s' "$normalised" | jq -c --arg since "$f_since" \
      'map(select((.updatedAt // "") == "" or (.updatedAt >= $since)))' 2>/dev/null)
    [ -z "$normalised" ] && normalised='[]'
  fi

  printf '%s\n' "$normalised"
  return 0
}

# ------------------------------------------------------------------------------
# Label ensure (tracker_label_ensure) — #709 creator-sweep companion to
# tracker_create.
#
# A few creator skills (/spike, /prototype, /investigation) depend on a trigger
# label (spike / prototype / investigation) existing on the target repo so
# downstream hooks can read it and apply their workflow exemptions. On GitHub
# that label must be created explicitly; tracker_label_ensure is the
# tracker-agnostic analog of that inline `gh label create` step.
#
# Contract: tracker_label_ensure <owner/repo> <name> [<color>] [<description>]
#   BEST-EFFORT by design — ALWAYS returns 0. A missing/duplicate/errored label
#   must never abort the subsequent tracker_create (the same "swallow the
#   duplicate" semantics the inline `gh label create … || true` calls had).
#   Color is accepted as a bare hex ("FBCA04", the gh convention); the glab
#   adapter normalises it to "#FBCA04" (GitLab wants the leading #).
#
# Adapters: gh + glab do a real create. jira / linear / asana / none have no
#   built-in gh/glab label CLI here, and `custom` files issues via the operator's
#   own create_command (which handles labels its own way) — so all of them are
#   no-ops; a generic label-ensure step doesn't apply. (GitLab additionally
#   auto-creates a label when it is first applied on issue-create, so even the
#   glab path is a convenience, not a correctness requirement.)
# ------------------------------------------------------------------------------

# Internal adapter: gh → `gh label create <name>` (name is positional).
_tracker_label_ensure_gh() {
  local repo="$1" name="$2" color="$3" desc="$4"
  local -a args
  args=(label create "$name" --repo "$repo")
  [ -n "$color" ] && args+=(--color "$color")
  [ -n "$desc" ]  && args+=(--description "$desc")
  gh "${args[@]}" >/dev/null 2>&1 || true
}

# Internal adapter: glab → `glab label create --name <name>`. GitLab wants the
# colour as "#RRGGBB"; normalise a bare-hex input by prepending '#'.
_tracker_label_ensure_glab() {
  local repo="$1" name="$2" color="$3" desc="$4"
  local -a args
  args=(label create --name "$name" -R "$repo")
  if [ -n "$color" ]; then
    case "$color" in \#*) : ;; *) color="#$color" ;; esac
    args+=(--color "$color")
  fi
  [ -n "$desc" ] && args+=(--description "$desc")
  glab "${args[@]}" >/dev/null 2>&1 || true
}

# Public: tracker_label_ensure <owner/repo> <name> [<color>] [<description>]
tracker_label_ensure() {
  local repo="$1" name="${2:-}" color="${3:-}" desc="${4:-}"
  # Nothing actionable without a repo + name — never abort the caller.
  if [ -z "$repo" ] || [ -z "$name" ]; then
    return 0
  fi
  local kind
  kind=$(tracker_kind "$repo")
  case "$kind" in
    gh)   _tracker_label_ensure_gh   "$repo" "$name" "$color" "$desc" ;;
    glab) _tracker_label_ensure_glab "$repo" "$name" "$color" "$desc" ;;
    *)    : ;;  # jira / linear / asana / custom / none — no-op
  esac
  return 0
}

# ------------------------------------------------------------------------------
# PR/MR review submission (#758) — tracker/git-host-agnostic review posting.
#
# Mirrors tracker_create's shape: kind-dispatched adapters for gh + glab, a
# `custom` review_command template, and a `none` no-op. The code-reviewer agent
# (Rex) / /code-review call tracker_review_submit instead of shelling out to
# `gh pr review` directly, so a GitLab-hosted adopter's review lands on the MR
# rather than silently assuming GitHub.
#
# ORTHOGONAL to the merge gate. This function only posts the HUMAN-VISIBLE review
# to the git host. The load-bearing `*-rex.approved` marker is a plain local file
# (already tracker-agnostic) written separately by the agent — a failed submit
# here does NOT touch it. See .claude/agents/code-reviewer.md § "Approval marker".
#
# Verdict vocabulary (faithful to gh's three verbs): approve | comment |
# request-changes. This is a thin wrapper — the POLICY of "prefer --comment over
# --approve on single-account self-review" lives in the agent (which passes
# `comment`), not here.
# ------------------------------------------------------------------------------

# Internal adapter: gh → `gh pr review`. Args passed as an array (never an eval'd
# string) so a body full of shell metacharacters is inert. 2>/dev/null hides the
# expected self-approval refusal noise; gh's exit status still propagates.
_tracker_review_gh() {
  local repo="$1" pr="$2" verdict="$3" body_file="$4"
  local -a args
  args=(pr review "$pr" --repo "$repo")
  case "$verdict" in
    approve)         args+=(--approve) ;;
    request-changes) args+=(--request-changes) ;;
    comment|*)       args+=(--comment) ;;
  esac
  if [ -n "$body_file" ] && [ -f "$body_file" ]; then
    args+=(--body-file "$body_file")
  fi
  gh "${args[@]}" 2>/dev/null
}

# Internal adapter: glab (GitLab) → `glab mr approve` / `glab mr note create`.
#
# GitLab has NO "request-changes" review state, so that verdict posts the review
# body as an MR note (the verdict is stated in the body — same shape as gh's
# --comment happy path). `approve` posts the approval and, when a body is given,
# adds it as a note too (glab mr approve carries no message). `glab mr note
# create` is the non-deprecated replacement for the old top-level `glab mr note
# -m` (GitLab prints a deprecation notice steering to `create`); it is flagged
# EXPERIMENTAL in glab 1.103.x — verified by CLI surface, not a live MR.
_tracker_review_glab() {
  local repo="$1" pr="$2" verdict="$3" body_file="$4"
  local body=""
  [ -n "$body_file" ] && [ -f "$body_file" ] && body="$(cat "$body_file")"
  case "$verdict" in
    approve)
      glab mr approve "$pr" -R "$repo" 2>/dev/null || return 1
      if [ -n "$body" ]; then
        glab mr note create "$pr" -R "$repo" -m "$body" 2>/dev/null || return 1
      fi
      ;;
    comment|request-changes|*)
      [ -n "$body" ] || return 1   # a comment/notes verdict needs a body
      glab mr note create "$pr" -R "$repo" -m "$body" 2>/dev/null || return 1
      ;;
  esac
}

# Internal: resolve the review_command template for the `custom` kind — the
# per-project override (registry) wins over a global .tracker.review_command.
# Empty when neither is set (custom kind without a template can't submit).
_tracker_review_template() {
  local repo="${1:-}"
  if [ -n "$repo" ]; then
    local pv
    if pv=$(_tracker_project_value "$repo" review_command) && [ -n "$pv" ]; then
      echo "$pv"
      return 0
    fi
  fi
  _tracker_load_config_lib
  local tpl
  tpl=$(config_get_or '.tracker.review_command' '' 2>/dev/null)
  if [ -n "$tpl" ] && [ "$tpl" != "null" ]; then
    echo "$tpl"
  fi
}

# Internal adapter: custom → operator-supplied review_command template.
#
# Injection model (identical to _tracker_create_custom): only the SAFE
# placeholders — {owner_repo} (registry slug), {pr} (numeric), {verdict}
# (validated enum) — are substituted into the eval'd template. The one arbitrary,
# untrusted value (the review body) is exposed as an ENVIRONMENT VARIABLE
# ($TRACKER_REVIEW_BODY_FILE, a path) that the operator references with a
# double-quoted expansion — so a body full of `; rm -rf …` is inert.
_tracker_review_custom() {
  local repo="$1" pr="$2" verdict="$3" body_file="$4"
  local tpl
  tpl=$(_tracker_review_template "$repo")
  if [ -z "$tpl" ]; then
    return 1
  fi
  local cmd="$tpl"
  cmd="${cmd//\{owner_repo\}/$repo}"
  cmd="${cmd//\{pr\}/$pr}"
  cmd="${cmd//\{verdict\}/$verdict}"
  TRACKER_REPO="$repo" TRACKER_PR="$pr" TRACKER_VERDICT="$verdict" \
    TRACKER_REVIEW_BODY_FILE="$body_file" \
    eval "$cmd" 2>/dev/null
}

# Public: tracker_review_submit <owner/repo> <pr> <verdict> [<body_file>]
#
# NOTE on the tracker.kind axis: kind describes the ISSUE tracker, but a review
# targets the PR/MR HOST (the git remote). For gh+github and glab+gitlab they
# coincide, which is exactly the pair this ticket (#758) covers. The wildcard
# default below assumes a non-gh/glab issue tracker (jira/linear/asana) is paired
# with a GitHub code host — correct for the common jira-issues+github-code setup,
# but a jira-issues+gitlab-code adopter would need `tracker.kind=custom` with a
# review_command (or a future dedicated review-host config).
tracker_review_submit() {
  local repo="$1" pr="$2" verdict="${3:-comment}" body_file="${4:-}"
  if [ -z "$repo" ] || [ -z "$pr" ]; then
    return 1
  fi
  # {pr} is documented numeric and is substituted into the custom adapter's
  # eval'd template — reject a non-numeric value as defense-in-depth (gh/glab
  # require numeric PR/MR ids anyway).
  case "$pr" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$verdict" in
    approve|comment|request-changes) ;;
    *) verdict="comment" ;;   # normalise anything unexpected to the safe default
  esac

  local kind
  kind=$(tracker_kind "$repo")
  case "$kind" in
    none)
      # Shape-only mode: no git-host CLI to call. Emit the review body (if given)
      # so the operator can post it manually, and return 3 (documented
      # "shape-only" code) so callers don't misreport it as a CLI/auth error.
      if [ -n "$body_file" ] && [ -f "$body_file" ]; then
        cat "$body_file"
      fi
      return 3
      ;;
    gh)     _tracker_review_gh     "$repo" "$pr" "$verdict" "$body_file" ;;
    glab)   _tracker_review_glab   "$repo" "$pr" "$verdict" "$body_file" ;;
    custom) _tracker_review_custom "$repo" "$pr" "$verdict" "$body_file" ;;
    *)      _tracker_review_gh     "$repo" "$pr" "$verdict" "$body_file" ;;  # see NOTE above
  esac
}

# ==============================================================================
# Merge (tracker_pr_merge) — the #711/#759 merge-command abstraction.
#
# `/approve-merge`'s final step used to shell out to a literal `gh pr merge <pr>
# --squash --delete-branch`. On a GitLab-hosted project there is no `gh`, so the
# CEO-approval marker could be written but the merge itself had to happen
# outside the skill (and outside the mechanical gates it's meant to run
# through). tracker_pr_merge closes that gap the same way #758's
# tracker_review_submit closed it for review *submission* — a kind-dispatched
# function (gh/glab/custom/none), never a re-derived inline command.
#
# ORTHOGONAL to the merge-*gate* hooks (block-unreviewed-merge.sh,
# block-merge-on-red-ci.sh, require-design-review-for-ui.sh,
# require-architecture-review.sh). Those already fire on both the `gh pr merge`
# and `glab mr merge`/`glab api .../merge` shapes (#764/#767/#793) — this
# function is what /approve-merge calls AFTER the gates have already had their
# chance to block the command. Nothing here weakens or bypasses them; the
# actual `gh`/`glab` command this function shells out to is the exact same
# command text the gates already recognise.
#
# strategy is one of squash|merge|rebase — normalised BEFORE it ever reaches an
# eval'd string (unlike the review body, there is no free-text value here at
# all: strategy and delete_branch are both closed enums, so a hostile input is
# neutralised by the normalisation step itself, not by env-indirection).
# ------------------------------------------------------------------------------

# Internal: normalise an arbitrary strategy string to squash|merge|rebase,
# defaulting to squash (today's /approve-merge default) for anything else.
_tracker_merge_normalise_strategy() {
  case "${1:-}" in
    squash|merge|rebase) echo "$1" ;;
    *) echo "squash" ;;
  esac
}

# Internal: normalise an arbitrary delete-branch flag to true|false, defaulting
# to true (today's /approve-merge default — it always passes --delete-branch).
_tracker_merge_normalise_delete_branch() {
  case "${1:-true}" in
    false|False|FALSE|0|no|No) echo "false" ;;
    *) echo "true" ;;
  esac
}

# Internal adapter: gh → `gh pr merge`. Flags built as an array (never an
# eval'd string), so the PR/repo/strategy values can't be mistaken for shell
# syntax even though they're already-validated enums/numerics.
#
# Stdout is discarded (`>/dev/null`), stderr is NOT: `gh pr merge` prints a
# human-readable confirmation line to stdout on success ("✓ Squashed and
# merged pull request #42 …") — if that reached tracker_pr_merge's own
# stdout uncaught, it would land BEFORE the `{"sha":...}` JSON the public
# function returns, breaking every caller's `jq -r '.sha'` parse. We don't
# need that confirmation text (the SHA is independently resolved via a
# follow-up `gh pr view` in _tracker_merge_resolve_sha), so it's discarded;
# gh's error output on FAILURE goes to stderr, which is left to propagate so
# the operator actually sees why a merge failed (matching the documented
# contract in `/approve-merge`'s SKILL.md — the failure message the operator
# sees is meant to be the CLI's own, not silently swallowed).
_tracker_merge_gh() {
  local repo="$1" pr="$2" strategy="$3" delete_branch="$4"
  local -a args
  args=(pr merge "$pr" --repo "$repo")
  case "$strategy" in
    squash) args+=(--squash) ;;
    merge)  args+=(--merge)  ;;
    rebase) args+=(--rebase) ;;
  esac
  [ "$delete_branch" = "true" ] && args+=(--delete-branch)
  gh "${args[@]}" >/dev/null
}

# Internal adapter: glab (GitLab) → `glab mr merge`. glab's default merge (no
# --squash/--rebase flag) IS a plain merge commit, so strategy=merge passes no
# extra flag — the nearest glab equivalent of gh's --merge. --remove-source-
# branch is glab's --delete-branch analog. --yes skips the interactive prompt
# (matches the --yes convention already used by _tracker_create_glab /
# _tracker_label_ensure_glab).
#
# Same stdout/stderr split as _tracker_merge_gh above: stdout discarded
# (glab also prints a confirmation line on success), stderr left to
# propagate so a failure reason is visible.
_tracker_merge_glab() {
  local repo="$1" pr="$2" strategy="$3" delete_branch="$4"
  local -a args
  args=(mr merge "$pr" -R "$repo")
  case "$strategy" in
    squash) args+=(--squash) ;;
    rebase) args+=(--rebase) ;;
    merge)  : ;;  # glab's default merge action — no flag needed
  esac
  [ "$delete_branch" = "true" ] && args+=(--remove-source-branch)
  args+=(--yes)
  glab "${args[@]}" >/dev/null
}

# Internal: resolve the merge_command template for the `custom` kind — the
# per-project override (registry) wins over a global .tracker.merge_command.
# Empty when neither is set (custom kind without a template can't merge).
_tracker_merge_template() {
  local repo="${1:-}"
  if [ -n "$repo" ]; then
    local pv
    if pv=$(_tracker_project_value "$repo" merge_command) && [ -n "$pv" ]; then
      echo "$pv"
      return 0
    fi
  fi
  _tracker_load_config_lib
  local tpl
  tpl=$(config_get_or '.tracker.merge_command' '' 2>/dev/null)
  if [ -n "$tpl" ] && [ "$tpl" != "null" ]; then
    echo "$tpl"
  fi
}

# Internal adapter: custom → operator-supplied merge_command template.
#
# Injection model: unlike _tracker_review_custom / _tracker_create_custom,
# there is no arbitrary/untrusted free-text value in a merge call at all — pr
# is numeric-guarded and repo is charset-guarded by the public function below
# (both checked BEFORE any adapter, not just this one), and strategy/
# delete_branch are both normalised to a closed enum before this function
# ever sees them. So all four placeholders — {owner_repo} (registry slug,
# charset-guarded), {pr} (numeric-guarded), {strategy} (squash|merge|rebase),
# {delete_branch} (true|false) — are safe to substitute directly into the
# eval'd template; none of them can carry shell metacharacters by the time
# they arrive here.
#
# Stdout discarded, stderr left to propagate — same rationale as
# _tracker_merge_gh/_tracker_merge_glab above: the operator-supplied CLI's
# own confirmation text on stdout must not contaminate the `{"sha":...}`
# JSON the public function returns, but its failure output on stderr should
# still be visible.
_tracker_merge_custom() {
  local repo="$1" pr="$2" strategy="$3" delete_branch="$4"
  local tpl
  tpl=$(_tracker_merge_template "$repo")
  if [ -z "$tpl" ]; then
    return 1
  fi
  local cmd="$tpl"
  cmd="${cmd//\{owner_repo\}/$repo}"
  cmd="${cmd//\{pr\}/$pr}"
  cmd="${cmd//\{strategy\}/$strategy}"
  cmd="${cmd//\{delete_branch\}/$delete_branch}"
  TRACKER_REPO="$repo" TRACKER_PR="$pr" TRACKER_STRATEGY="$strategy" \
    TRACKER_DELETE_BRANCH="$delete_branch" \
    eval "$cmd" >/dev/null
}

# Internal: best-effort merge-commit SHA lookup after a successful merge.
# gh:   `gh pr view --json mergeCommit` → .mergeCommit.oid
# glab: `glab mr view --output json`    → .merge_commit_sha (fallback
#       .squash_commit_sha for a squash merge on older glab)
# custom: no generic way to know the custom CLI's output shape — emits empty.
# Any failure (CLI missing, network, unparseable) degrades to an empty sha;
# the merge itself already succeeded by the time this runs, so a SHA-lookup
# failure must never be reported as a merge failure.
_tracker_merge_resolve_sha() {
  local kind="$1" repo="$2" pr="$3" sha=""
  case "$kind" in
    gh)
      sha=$(gh pr view "$pr" --repo "$repo" --json mergeCommit --jq '.mergeCommit.oid // empty' 2>/dev/null)
      ;;
    glab)
      sha=$(glab mr view "$pr" -R "$repo" --output json 2>/dev/null | jq -r '.merge_commit_sha // .squash_commit_sha // empty' 2>/dev/null)
      ;;
    *)
      sha=""
      ;;
  esac
  jq -nc --arg sha "${sha:-}" '{sha:$sha}' 2>/dev/null
}

# Public: tracker_pr_merge <owner/repo> <pr> <strategy> [<delete_branch>]
#
# NOTE on the tracker.kind axis: same caveat as tracker_review_submit — kind
# describes the ISSUE tracker, but a merge targets the PR/MR HOST. For gh+github
# and glab+gitlab they coincide (this ticket's covered pair). A jira-issues+
# gitlab-code adopter needs `tracker.kind=custom` with a merge_command.
tracker_pr_merge() {
  local repo="$1" pr="$2" strategy delete_branch
  if [ -z "$repo" ] || [ -z "$pr" ]; then
    return 1
  fi
  # {owner_repo} is substituted into the custom adapter's eval'd template too
  # (same trust model as tracker_create/tracker_review_submit — a registry-
  # sourced slug, not free-text). Reject anything outside the safe owner/repo
  # (or nested-subgroup, e.g. GitLab `group/subgroup/repo`) charset as
  # defense-in-depth, BEFORE dispatching to any adapter — not just `custom`.
  # A real owner/repo slug never contains `;`, `|`, `&`, `$`, backticks,
  # parens, quotes, or whitespace, so this cannot reject a legitimate value.
  case "$repo" in
    *[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  # {pr} is documented numeric and is substituted into the custom adapter's
  # eval'd template — reject a non-numeric value as defense-in-depth (gh/glab
  # require numeric PR/MR ids anyway; matches tracker_review_submit's guard).
  case "$pr" in
    ''|*[!0-9]*) return 1 ;;
  esac
  strategy=$(_tracker_merge_normalise_strategy "${3:-}")
  delete_branch=$(_tracker_merge_normalise_delete_branch "${4:-}")

  local kind
  kind=$(tracker_kind "$repo")
  case "$kind" in
    none)
      # Shape-only mode: no git-host CLI to call. Nothing to echo (unlike
      # tracker_create/tracker_review_submit there's no body/artifact to hand
      # back) — just the documented shape-only exit code.
      return 3
      ;;
  esac

  local rc
  case "$kind" in
    gh)     _tracker_merge_gh     "$repo" "$pr" "$strategy" "$delete_branch"; rc=$? ;;
    glab)   _tracker_merge_glab   "$repo" "$pr" "$strategy" "$delete_branch"; rc=$? ;;
    custom) _tracker_merge_custom "$repo" "$pr" "$strategy" "$delete_branch"; rc=$? ;;
    *)      _tracker_merge_gh     "$repo" "$pr" "$strategy" "$delete_branch"; rc=$? ;;  # see NOTE above
  esac
  if [ $rc -ne 0 ]; then
    return $rc
  fi

  _tracker_merge_resolve_sha "$kind" "$repo" "$pr"
  return 0
}

# ------------------------------------------------------------------------------
# GitHub-Issues-enabled detection (#653, AgDR-0071)
#
# GitHub disables Issues on forks by default, so a fresh github-kind fork will
# fail every issue-creating skill with a cryptic `gh` error. These helpers let
# /setup + /handover detect that early and offer to fix it — gated on
# tracker.kind so linear/jira/none adopters (who legitimately have GH Issues
# off) are never warned.
# ------------------------------------------------------------------------------

# Public: tracker_issues_verdict <kind> <has_issues_enabled>
#   PURE decision (no I/O) — the unit-testable core. Echoes one of:
#     skip      — non-github tracker; the GH-Issues state is irrelevant
#     disabled  — github tracker AND issues are off → warn
#     ok        — github tracker with issues on, OR unknown (don't false-alarm)
tracker_issues_verdict() {
  local kind="$1" has="$2"
  case "$kind" in
    gh|github) ;;
    *) echo "skip"; return 0 ;;
  esac
  case "$has" in
    false|False|FALSE) echo "disabled" ;;
    *) echo "ok" ;;   # true / unknown / empty → never false-alarm
  esac
}

# Public: tracker_issues_enabled_raw <owner_repo>
#   Echoes gh's hasIssuesEnabled ("true"/"false"), or "" when gh is missing or
#   the call fails (network/auth) — callers treat "" as "unknown, don't warn".
tracker_issues_enabled_raw() {
  local repo="$1"
  command -v gh >/dev/null 2>&1 || { echo ""; return 0; }
  gh repo view "$repo" --json hasIssuesEnabled -q '.hasIssuesEnabled' 2>/dev/null || echo ""
}

# Public: tracker_issues_enable_hint <owner_repo>
#   Echoes the one-line command to enable Issues on <owner_repo>.
tracker_issues_enable_hint() {
  echo "gh repo edit $1 --enable-issues"
}

# Public: tracker_check_issues <owner_repo>
#   For a github-kind tracker, print a warning + enable hint to STDERR when
#   Issues are disabled on <owner_repo>. No-op (return 0) for non-github
#   trackers, enabled repos, or when gh can't answer. Returns 1 ONLY when
#   issues are confirmed disabled — so a caller can branch on it to offer the
#   fix. Never mutates anything (enabling is the caller's explicit, opt-in step).
tracker_check_issues() {
  local repo="$1"
  [ -n "$repo" ] || return 0
  local kind has verdict
  kind=$(tracker_kind)
  # Short-circuit: skip the gh round-trip entirely for non-github trackers.
  case "$kind" in gh|github) ;; *) return 0 ;; esac
  has=$(tracker_issues_enabled_raw "$repo")
  verdict=$(tracker_issues_verdict "$kind" "$has")
  if [ "$verdict" = "disabled" ]; then
    {
      echo "⚠ GitHub Issues is DISABLED on $repo, but tracker.kind is \"$kind\"."
      echo "  Issue-creating skills (/feature, /bug, /task, /tickets-batch, /idea, …) will fail."
      echo "  Enable it (needs admin):  $(tracker_issues_enable_hint "$repo")"
      echo "  Or: Settings → General → Features → Issues."
      echo "  (Tracking elsewhere? Set tracker.kind to linear/jira/none in .claude/project-config.json.)"
    } >&2
    return 1
  fi
  return 0
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
