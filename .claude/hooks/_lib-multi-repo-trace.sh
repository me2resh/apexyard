#!/bin/bash
# _lib-multi-repo-trace.sh — shared cross-repo trace helpers for the
# anchor-scoped multi-repo discovery skills (/dfd, /process).
#
# Source this library from any skill that follows an outbound call from
# one registered project into another, using `apexyard.projects.yaml` as
# the registry. See AgDR-0026 (DFD skill) for design rationale; the same
# discovery shape applies to /process (#256).
#
# Usage:
#   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
#   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
#   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-multi-repo-trace.sh"
#
#   target=$(mrt_resolve_target "https://billing.internal.example.com/charge")
#   if [ -n "$target" ]; then
#     # registered project — follow into its source
#     ws=$(mrt_workspace_for "$target")
#   else
#     vendor=$(mrt_is_third_party "https://api.stripe.com/v1/charges")
#     # → "stripe" — render as external entity, don't follow
#   fi
#
# All resolvers are READ-ONLY against the registry + filesystem. None of
# them clone, none of them write — the caller decides what to do with
# the answer.
#
# Bash 3.2 compatible (no associative arrays, no `${var,,}` syntax) so
# the helper works under the system bash on stock macOS.

# ------------------------------------------------------------------------------
# Internal: parse projects from the registry. Outputs one line per project:
#   <name>|<primary_repo>|<workspace>|<hostnames>|<topics>|<all_repos>
# where <hostnames> and <topics> are comma-lists of optional `hostnames:` /
# `topics:` fields the project entry may declare for cross-repo matching, and
# <all_repos> is a comma-list of EVERY repo the project declares.
#
# me2resh/apexyard#1123 — a project may declare a PLURAL `repos:` list (a
# product split across several repos, governed as one thing) instead of the
# singular `repo:`. <primary_repo> (field 2, UNCHANGED position from before
# this fix) is the explicit `primary:` field if set, else the singular
# `repo:` value, else the first entry of `repos:` — so every existing caller
# reading field 2 as "the repo" keeps working unchanged for a project that
# still uses `repo:`. <all_repos> (the new field 6, additive) is what a
# caller that must not miss a non-primary repo — e.g. cross-repo URL/slug
# matching in mrt_resolve_target's tier 4 below — should iterate instead.
# Singular `repo: X` is exactly equivalent to `repos: [X]` with no `primary:`
# set: both produce primary=X and all_repos=X.
#
# Tolerant of missing fields — only `name` is required to produce a line.
# ------------------------------------------------------------------------------
_mrt_parse_registry() {
  local registry
  registry=$(portfolio_registry)
  [ -f "$registry" ] || return 0

  if command -v yq >/dev/null 2>&1; then
    # yq path: structured extraction, handles both bare and quoted scalars.
    # `.repos // [.repo]` normalises singular `repo:` to a one-element list
    # so $all_repos is always "every repo" regardless of which form the
    # project entry uses (verified against mikefarah yq v4.53.3 — its `//`
    # operator falls through on a missing/null LHS the same way jq's does).
    yq eval '
      .projects[]? |
        (.repos // [.repo]) as $all_repos |
        (.primary // .repo // ($all_repos[0] // "")) as $primary |
        [
          .name // "",
          $primary,
          .workspace // "",
          (.hostnames // [] | join(",")),
          (.topics // [] | join(",")),
          ($all_repos | join(","))
        ] | join("|")
    ' "$registry" 2>/dev/null
  else
    # Greppy fallback — same shape as start-ticket's awk fallback. Assumes
    # `- name:` is the first key in each entry; `repo:`, `primary:`,
    # `workspace:`, `hostnames:` (inline list), `topics:` (inline list),
    # `repos:` (block list OR inline list) follow.
    #
    # `current_list` distinguishes a `repos:` BLOCK list from any OTHER
    # block list the entry may also declare (`tags:`, `roles:`) — a bare
    # `repos:` header (no inline value) arms it; any other `key:` line,
    # scalar or list-header alike, disarms it. Without this a project's
    # `tags:\n  - customer-facing` would be misread as a repo.
    awk '
      function unquote(s) { gsub(/^["\x27]|["\x27]$/, "", s); return s }
      function inline_list(line,    out, n, i, parts) {
        sub(/^[^\[]*\[/, "", line); sub(/\].*$/, "", line)
        gsub(/[[:space:]]/, "", line)
        n = split(line, parts, ",")
        out = ""
        for (i = 1; i <= n; i++) {
          if (parts[i] != "") {
            out = (out == "" ? "" : out ",") unquote(parts[i])
          }
        }
        return out
      }
      function flush(   all_repos, primary, rp_n, rp_parts) {
        if (name == "") return
        all_repos = repos_list
        if (all_repos == "" && repo != "") all_repos = repo
        primary = primary_field
        if (primary == "") primary = repo
        if (primary == "" && all_repos != "") {
          rp_n = split(all_repos, rp_parts, ",")
          primary = rp_parts[1]
        }
        print name "|" primary "|" workspace "|" hostnames "|" topics "|" all_repos
      }
      BEGIN { current_list = "" }
      /^[[:space:]]*-[[:space:]]*name:/ {
        flush()
        name = unquote($3); repo = ""; workspace = ""; hostnames = ""; topics = ""
        primary_field = ""; repos_list = ""
        current_list = ""
        next
      }
      /^[[:space:]]*repo:/      { repo = unquote($2); current_list = ""; next }
      /^[[:space:]]*primary:/   { primary_field = unquote($2); current_list = ""; next }
      /^[[:space:]]*workspace:/ { workspace = unquote($2); current_list = ""; next }
      /^[[:space:]]*hostnames:[[:space:]]*\[/ { hostnames = inline_list($0); current_list = ""; next }
      /^[[:space:]]*topics:[[:space:]]*\[/    { topics    = inline_list($0); current_list = ""; next }
      /^[[:space:]]*repos:[[:space:]]*\[/     { repos_list = inline_list($0); current_list = ""; next }
      /^[[:space:]]*repos:[[:space:]]*(#.*)?$/      { current_list = "repos"; next }
      /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_-]*:/  { current_list = ""; next }
      /^[[:space:]]*-[[:space:]]+/ {
        if (current_list == "repos") {
          item = $0
          sub(/^[[:space:]]*-[[:space:]]+/, "", item)
          gsub(/[[:space:]]+$/, "", item)
          repos_list = (repos_list == "" ? unquote(item) : repos_list "," unquote(item))
        }
        next
      }
      END { flush() }
    ' "$registry"
  fi
}

# Lowercase a string portably (bash 3.2 has no ${var,,}).
_mrt_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# ------------------------------------------------------------------------------
# Public: mrt_resolve_target <hostname-or-url-or-topic>
#
# Returns the registered project name (one line on stdout) if the input
# matches a registered project. Empty output + nonzero exit otherwise.
#
# Matching tiers (first wins):
#   1. Exact match against a project's declared `hostnames:` entries
#   2. Exact match against a project's declared `topics:` entries
#      (for message-broker topic strings)
#   3. Substring match of the project name in the hostname
#      (so `https://billing.internal.example.com/foo` matches a project
#       named `billing`)
#   4. Repo-slug match in the URL path (so `github.com/me2resh/billing-api`
#      matches a project with `repo: me2resh/billing-api` — OR, for a
#      multi-repo project (#1123), ANY of its `repos:` entries, not only
#      the `primary:` one. A cross-repo call landing on a project's
#      gateway/worker repo must resolve just as reliably as one landing on
#      its primary repo.)
# ------------------------------------------------------------------------------
mrt_resolve_target() {
  local input="$1"
  [ -z "$input" ] && return 1

  # Extract hostname from a URL if input looks like one
  local host="$input"
  case "$input" in
    http://*|https://*)
      host="${input#*://}"
      host="${host%%/*}"
      ;;
  esac

  local input_lc host_lc
  input_lc=$(_mrt_lower "$input")
  host_lc=$(_mrt_lower "$host")

  local name repo workspace hostnames topics all_repos
  local name_lc
  local IFS_save="$IFS"
  while IFS='|' read -r name repo workspace hostnames topics all_repos; do
    [ -z "$name" ] && continue
    name_lc=$(_mrt_lower "$name")

    # Tier 1: declared hostnames (comma-separated)
    if [ -n "$hostnames" ]; then
      IFS=',' read -r -a h_array <<EOF
$hostnames
EOF
      local h h_lc
      for h in "${h_array[@]}"; do
        h_lc=$(_mrt_lower "$h")
        if [ "$host_lc" = "$h_lc" ]; then
          IFS="$IFS_save"
          echo "$name"
          return 0
        fi
      done
    fi

    # Tier 2: declared topics
    if [ -n "$topics" ]; then
      IFS=',' read -r -a t_array <<EOF
$topics
EOF
      local t t_lc
      for t in "${t_array[@]}"; do
        t_lc=$(_mrt_lower "$t")
        if [ "$input_lc" = "$t_lc" ]; then
          IFS="$IFS_save"
          echo "$name"
          return 0
        fi
      done
    fi

    # Tier 3: project name substring in hostname (guard against short generic names)
    if [ ${#name_lc} -ge 4 ]; then
      case "$host_lc" in
        *"$name_lc"*)
          IFS="$IFS_save"
          echo "$name"
          return 0
          ;;
      esac
    fi

    # Tier 4: repo slug in URL — checked against EVERY repo the project
    # declares (all_repos), not only its primary repo (#1123).
    if [ -n "$all_repos" ]; then
      IFS=',' read -r -a r_array <<EOF
$all_repos
EOF
      local r r_lc
      for r in "${r_array[@]}"; do
        r_lc=$(_mrt_lower "$r")
        case "$input_lc" in
          *"$r_lc"*)
            IFS="$IFS_save"
            echo "$name"
            return 0
            ;;
        esac
      done
    fi
  done < <(_mrt_parse_registry)

  IFS="$IFS_save"
  return 1
}

# ------------------------------------------------------------------------------
# Public: mrt_workspace_for <project-name>
#
# Returns the absolute path to the project's workspace clone (if it
# exists and is readable). Empty + nonzero exit otherwise.
#
# Reads the registry's `workspace:` field for the project first; falls
# back to <workspace_dir>/<name> via portfolio_workspace_dir.
# ------------------------------------------------------------------------------
mrt_workspace_for() {
  local target="$1"
  [ -z "$target" ] && return 1

  local name repo workspace hostnames topics all_repos
  while IFS='|' read -r name repo workspace hostnames topics all_repos; do
    if [ "$name" = "$target" ]; then
      local candidate=""
      if [ -n "$workspace" ]; then
        case "$workspace" in
          /*) candidate="$workspace" ;;
          *)
            local root
            root=$(_portfolio_root 2>/dev/null) || root=""
            [ -n "$root" ] && candidate="$root/$workspace"
            ;;
        esac
      fi
      if [ -z "$candidate" ]; then
        local ws_dir
        ws_dir=$(portfolio_workspace_dir 2>/dev/null) || ws_dir=""
        [ -n "$ws_dir" ] && candidate="$ws_dir/$name"
      fi
      if [ -n "$candidate" ] && [ -d "$candidate" ]; then
        echo "$candidate"
        return 0
      fi
      return 1
    fi
  done < <(_mrt_parse_registry)

  return 1
}

# ------------------------------------------------------------------------------
# Public: mrt_is_third_party <hostname-or-url>
#
# Detects well-known third-party SaaS / API hostnames. Returns the
# vendor identifier on stdout (lowercase short name) if matched.
# Empty + nonzero exit otherwise.
#
# The default signature set is conservative; adopters extend by editing
# the case statement below. Order: most-specific patterns first so a
# substring like `stripe.com` doesn't accidentally match an unrelated
# host that happens to contain those letters.
# ------------------------------------------------------------------------------
mrt_is_third_party() {
  local input="$1"
  [ -z "$input" ] && return 1

  local host="$input"
  case "$input" in
    http://*|https://*)
      host="${input#*://}"
      host="${host%%/*}"
      ;;
  esac
  host=$(_mrt_lower "$host")

  case "$host" in
    *api.stripe.com*|*checkout.stripe.com*)               echo "stripe";     return 0 ;;
    *api.sendgrid.com*|*sendgrid.com*)                    echo "sendgrid";   return 0 ;;
    *api.mailgun.net*|*mailgun.net*)                      echo "mailgun";    return 0 ;;
    *api.postmarkapp.com*|*postmarkapp.com*)              echo "postmark";   return 0 ;;
    *api.twilio.com*|*twilio.com*)                        echo "twilio";     return 0 ;;
    *api.openai.com*|*openai.com*)                        echo "openai";     return 0 ;;
    *api.anthropic.com*|*anthropic.com*)                  echo "anthropic";  return 0 ;;
    *bedrock*.amazonaws.com*)                             echo "bedrock";    return 0 ;;
    *cognito*.amazonaws.com*)                             echo "cognito";    return 0 ;;
    *.auth0.com*)                                         echo "auth0";      return 0 ;;
    *.clerk.accounts.dev*|*.clerk.dev*)                   echo "clerk";      return 0 ;;
    *.supabase.co*)                                       echo "supabase";   return 0 ;;
    *sentry.io*)                                          echo "sentry";     return 0 ;;
    *datadoghq.com*|*datadoghq.eu*)                       echo "datadog";    return 0 ;;
    *posthog.com*)                                        echo "posthog";    return 0 ;;
    *amplitude.com*)                                      echo "amplitude";  return 0 ;;
    *mixpanel.com*)                                       echo "mixpanel";   return 0 ;;
    *segment.com*|*segment.io*)                           echo "segment";    return 0 ;;
    *salesforce.com*|*.force.com*)                        echo "salesforce"; return 0 ;;
    *github.com*)                                         echo "github";     return 0 ;;
    *.googleapis.com*)                                    echo "google-api"; return 0 ;;
    *.googletagmanager.com*)                              echo "gtm";        return 0 ;;
    *.algolia.net*|*.algolianet.com*)                     echo "algolia";    return 0 ;;
    *meilisearch.com*)                                    echo "meilisearch"; return 0 ;;
    *)                                                     return 1 ;;
  esac
}

# ------------------------------------------------------------------------------
# Public: mrt_list_projects
#
# Outputs one line per registered project: `<name>`. Used by skills that
# want to iterate every project (e.g. `/dfd --scope-all` for a
# system-wide DFD).
# ------------------------------------------------------------------------------
mrt_list_projects() {
  _mrt_parse_registry | awk -F'|' '{ if ($1 != "") print $1 }'
}

# ------------------------------------------------------------------------------
# Public: mrt_offer_clone <project-name>
#
# Prints a suggested clone command on stdout for the caller to either
# show to the operator or execute after confirmation. Caller is
# responsible for actually running `git clone` (this helper is read-only).
#
# For a multi-repo project (#1123) this clones the PRIMARY repo — the one
# tracker/board operations default to — not the whole set. Cloning every
# repo of a multi-repo project is a caller-level decision (see
# mrt_repos_for below to enumerate the rest), not this helper's job.
# ------------------------------------------------------------------------------
mrt_offer_clone() {
  local target="$1"
  [ -z "$target" ] && return 1

  local name repo workspace hostnames topics all_repos
  while IFS='|' read -r name repo workspace hostnames topics all_repos; do
    if [ "$name" = "$target" ]; then
      [ -z "$repo" ] && return 1
      local ws_dir candidate
      ws_dir=$(portfolio_workspace_dir 2>/dev/null) || ws_dir="./workspace"
      candidate="$ws_dir/$name"
      echo "git clone https://github.com/$repo $candidate"
      return 0
    fi
  done < <(_mrt_parse_registry)
  return 1
}

# ------------------------------------------------------------------------------
# Public: mrt_primary_repo_for <project-name>
#
# Echoes the project's primary repo (#1123) — explicit `primary:` if set,
# else the singular `repo:`, else the first entry of `repos:`. Empty +
# exit 1 if the project isn't found or declares no repo at all.
#
# This is the resolver a caller should use when it has a project NAME and
# needs to pick ONE repo to act on by default (tracker/board operations,
# for instance) without the caller having to know the multi-repo schema.
# ------------------------------------------------------------------------------
mrt_primary_repo_for() {
  local target="$1"
  [ -z "$target" ] && return 1

  local name repo workspace hostnames topics all_repos
  while IFS='|' read -r name repo workspace hostnames topics all_repos; do
    if [ "$name" = "$target" ]; then
      [ -z "$repo" ] && return 1
      echo "$repo"
      return 0
    fi
  done < <(_mrt_parse_registry)
  return 1
}

# ------------------------------------------------------------------------------
# Public: mrt_repos_for <project-name>
#
# Echoes EVERY repo the project declares, one per line (singular `repo:`
# normalises to a single line, same as `repos: [X]`). Empty + exit 1 if the
# project isn't found or declares no repo at all.
# ------------------------------------------------------------------------------
mrt_repos_for() {
  local target="$1"
  [ -z "$target" ] && return 1

  local name repo workspace hostnames topics all_repos
  while IFS='|' read -r name repo workspace hostnames topics all_repos; do
    if [ "$name" = "$target" ]; then
      [ -z "$all_repos" ] && return 1
      printf '%s\n' "$all_repos" | tr ',' '\n'
      return 0
    fi
  done < <(_mrt_parse_registry)
  return 1
}
