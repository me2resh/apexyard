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
#                                      `body` is populated for the gh and glab adapters (the kinds
#                                      that have a consumer needing it — the migration gate reads it
#                                      to find the linked AgDR, #755). Other adapters omit the body
#                                      key entirely (consumers read it as `.body // empty`) until one
#                                      needs it (jira `.description` is ADF, not a grep-able string;
#                                      linear/asana bodies have no consumer yet).
#   tracker_create <owner/repo> <title> [<body_file>] [<labels_csv>]
#                                      creates a ticket via the per-project CLI; emits {ref,url}.
#   tracker_review_submit <owner/repo> <pr> <verdict> [<body_file>]  (#758)
#                                      submits a PR/MR review to the git host. verdict is one of
#                                      approve|comment|request-changes (default comment). gh + glab
#                                      adapters built in, `custom` review_command template, `none`
#                                      no-op (returns 3, echoes body). Exit 0 = submitted; non-zero
#                                      = CLI errored; 3 = shape-only (kind=none, nothing to call).
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
# array of {name} objects). Both shapes are handled — older linear CLI
# versions returned strings; newer return objects.
# ------------------------------------------------------------------------------
_tracker_normalise_linear() {
  local raw="$1"
  if [ -z "$raw" ]; then return 1; fi
  if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then return 1; fi
  printf '%s' "$raw" | jq -c '{
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
  if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then return 1; fi
  printf '%s' "$raw" | jq -c '{
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
  if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then return 1; fi
  printf '%s' "$raw" | jq -c '
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
