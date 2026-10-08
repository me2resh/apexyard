#!/usr/bin/env bash
# briefing.sh — compact 4-line "where am I" snapshot for /status --briefing
# and the bin/apexyard status CLI shim.
#
# Output (slide 6 reality, me2resh/apexyard#182):
#
#   Active workspace:  <name|(ops)|(unknown)>
#   Active ticket:     <#N — title|(none)>
#   Branch:            <git branch --show-current|(no branch)>
#   Role set:          <role-from-labels|<none — inferred per task>>
#
# Inputs (env, all optional — used by tests to bypass the real filesystem
# and the real `gh` binary):
#
#   APEXYARD_OPS_ROOT     Override ops-fork root (skip the walk-up search).
#   APEXYARD_CWD          Override the current working dir (workspace inference).
#   APEXYARD_GH           Path to a `gh` shim (test-only). Defaults to `gh`.
#
# Exit codes:
#   0 — output written. Even an empty / unknown briefing is a successful
#       run; the briefing's job is to print "where you are right now" and
#       a row of (none) is itself useful information.

set -u

# ---------------------------------------------------------------------------
# 1. Resolve the ops-fork root.
#
# Same algorithm as _lib-portfolio-paths.sh (_portfolio_root) and as the
# /start-ticket skill: walk up from the cwd / git toplevel until we find a
# directory satisfying one of the apexyard-fork anchors:
#
#   - the v2 `.apexyard-fork` marker file (split-portfolio v2, where
#     onboarding.yaml + apexyard.projects.yaml live in the private
#     sibling repo and aren't present at the public fork root); OR
#   - both onboarding.yaml AND apexyard.projects.yaml (legacy v1 layout —
#     single-fork OR un-migrated split-portfolio).
#
# Symlinked registry / projects (split-portfolio v1 mode) is fine — the
# `apexyard.projects.yaml` symlink in the fork still satisfies the test.
# ---------------------------------------------------------------------------
ops_root="${APEXYARD_OPS_ROOT:-}"
if [ -z "$ops_root" ]; then
  start=""
  if [ -n "${APEXYARD_CWD:-}" ]; then
    start="$APEXYARD_CWD"
  elif r=$(git rev-parse --show-toplevel 2>/dev/null); then
    start="$r"
  else
    start="$(pwd)"
  fi

  cur="$start"
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    # v2 anchor (cheap presence test).
    if [ -e "$cur/.apexyard-fork" ]; then
      ops_root="$cur"
      break
    fi
    # Legacy v1 anchor.
    if [ -e "$cur/onboarding.yaml" ] && [ -e "$cur/apexyard.projects.yaml" ]; then
      ops_root="$cur"
      break
    fi
    cur=$(dirname "$cur")
  done
fi

# ---------------------------------------------------------------------------
# 2. Active workspace from the cwd.
#
# Rules (from #182 AC):
#   - cwd under <workspace_dir>/<name>/...         → workspace = "<name>"
#   - cwd == <ops_root>                            → workspace = "(ops)"
#   - anything else (or no ops_root)               → workspace = "(unknown)"
#
# In split-portfolio v2 mode the workspace dir lives in the private sibling
# repo (e.g. ../<fork>-portfolio/workspace) — resolve via the portfolio
# helper so v2 cwds map to the right workspace name. The literal
# $ops_root/workspace/ shape stays as a belt-and-suspenders fallback for
# legacy v1 forks.
# ---------------------------------------------------------------------------
cwd="${APEXYARD_CWD:-$(pwd)}"
workspace="(unknown)"

# Resolve workspace_dir via the portfolio helper if available.
workspace_dir=""
if [ -n "$ops_root" ] && [ -f "$ops_root/.claude/hooks/_lib-portfolio-paths.sh" ] && [ -f "$ops_root/.claude/hooks/_lib-read-config.sh" ]; then
  # shellcheck source=/dev/null
  . "$ops_root/.claude/hooks/_lib-read-config.sh" 2>/dev/null
  # shellcheck source=/dev/null
  . "$ops_root/.claude/hooks/_lib-portfolio-paths.sh" 2>/dev/null
  if command -v portfolio_workspace_dir >/dev/null 2>&1; then
    workspace_dir=$(portfolio_workspace_dir 2>/dev/null)
  fi
fi
[ -z "$workspace_dir" ] && [ -n "$ops_root" ] && workspace_dir="$ops_root/workspace"

if [ -n "$ops_root" ]; then
  if [ "$cwd" = "$ops_root" ]; then
    workspace="(ops)"
  elif [ -n "$workspace_dir" ]; then
    case "$cwd" in
      "$workspace_dir"/*)
        rel="${cwd#"$workspace_dir"/}"
        workspace="${rel%%/*}"
        ;;
      "$ops_root"/workspace/*)
        # Belt-and-suspenders fallback for v1 forks where workspace_dir
        # may not be the literal $ops_root/workspace.
        rel="${cwd#"$ops_root"/workspace/}"
        workspace="${rel%%/*}"
        ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# 3. Active ticket: read the marker of the working tree you are in.
#
# Each working tree keeps its own marker in its git dir (AgDR-0222). The
# shared resolver finds and validates it. Each marker is a key=value file
# written by /start-ticket; we only need `number`, `title` and `repo` here.
#
# During the move to that layout, a tree without a new marker shows what the
# old briefing showed: the per-project marker for the workspace, then the
# ops-level one, the first that has a number. That part does not need the
# resolver, so it also works in a fork without the hooks.
# ---------------------------------------------------------------------------
read_marker_field() {
  # Reads `key=value` lines, tolerating trailing CR. Outputs the value
  # for the first matching key only. No grep/awk shell-injection risk —
  # marker files are written by /start-ticket and never user-input.
  local file="$1" key="$2" line v
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      "$key="*)
        v="${line#"$key="}"
        printf '%s' "$v"
        return 0
        ;;
    esac
  done < "$file"
  return 1
}

ticket=""
ticket_repo=""
ticket_number=""
marker_paths=()

if [ -n "$ops_root" ] && [ -f "$ops_root/.claude/hooks/_lib-active-ticket.sh" ]; then
  # The portfolio paths resolve against the process working directory, so the
  # lookup runs from the ops root. The subshell keeps this script in place.
  # Only a marker in a validated tree's git dir is taken here.
  m=$(cd "$ops_root" 2>/dev/null \
    && . "$ops_root/.claude/hooks/_lib-active-ticket.sh" \
    && active_ticket_init "$ops_root" \
    && active_ticket_lookup "$cwd" \
    && [ "$AT_SOURCE" = tree ] \
    && printf '%s' "$REPLY") || m=""
  [ -z "$m" ] || marker_paths+=("$m")
fi

if [ -n "$ops_root" ]; then
  case "$workspace" in
    "(ops)"|"(unknown)"|"")
      ;;
    *)
      marker_paths+=("$ops_root/.claude/session/tickets/$workspace")
      ;;
  esac
  marker_paths+=("$ops_root/.claude/session/current-ticket")

  for m in "${marker_paths[@]}"; do
    if [ -f "$m" ]; then
      n=$(read_marker_field "$m" number || true)
      t=$(read_marker_field "$m" title  || true)
      r=$(read_marker_field "$m" repo   || true)
      if [ -n "$n" ]; then
        ticket_number="$n"
        ticket_repo="$r"
        if [ -n "$t" ]; then
          ticket="#${n} — ${t}"
        else
          ticket="#${n}"
        fi
        break
      fi
    fi
  done
fi

if [ -z "$ticket" ]; then
  ticket="(none)"
fi

# ---------------------------------------------------------------------------
# 4. Branch — git branch --show-current in the inferred workspace dir.
#
# If workspace is a real name, run git there; otherwise run in cwd.
# Catches the "no current branch" case (detached HEAD, no git repo) and
# substitutes "(no branch)" so the briefing always has 4 aligned lines.
# ---------------------------------------------------------------------------
branch_dir="$cwd"
case "$workspace" in
  "(ops)"|"(unknown)"|"") ;;
  *)
    if [ -n "$workspace_dir" ] && [ -d "$workspace_dir/$workspace" ]; then
      branch_dir="$workspace_dir/$workspace"
    elif [ -n "$ops_root" ] && [ -d "$ops_root/workspace/$workspace" ]; then
      branch_dir="$ops_root/workspace/$workspace"
    fi
    ;;
esac

branch=$(cd "$branch_dir" 2>/dev/null && git branch --show-current 2>/dev/null || true)
[ -z "$branch" ] && branch="(no branch)"

# ---------------------------------------------------------------------------
# 5. Role set — v1 inference from active-ticket labels.
#
# Per #182 AC: v1 ships label-based inference only. (b) recent-edits and
# (c) prompt-history inference are deferred. We pick the FIRST label that
# matches one of the canonical role names; if none match, we emit the
# explicit "<none — inferred per task>" string.
# ---------------------------------------------------------------------------
gh_bin="${APEXYARD_GH:-gh}"

# Canonical role labels in priority order. The label match is exact
# (case-insensitive) against the issue's labels. `qa-engineer` etc. are
# accepted as an alternate spelling so role-files don't have to be
# renamed if a project uses the long form.
role_labels=(
  backend         backend-engineer
  frontend        frontend-engineer
  qa              qa-engineer
  security        security-auditor
  platform        platform-engineer
  sre
  data            data-engineer
  ux              ux-designer
  ui              ui-designer
  product         product-manager
  techlead        tech-lead
)

role_set="<none — inferred per task>"

if [ -n "$ticket_number" ] && [ -n "$ticket_repo" ] && command -v "$gh_bin" >/dev/null 2>&1; then
  # `gh` may not be authed / online — failure here is silent. We only
  # parse names, no shell-eval, so a malformed JSON is harmless.
  labels_json=$("$gh_bin" issue view "$ticket_number" \
                  --repo "$ticket_repo" \
                  --json labels 2>/dev/null || true)

  if [ -n "$labels_json" ]; then
    # Extract label names: the JSON is `{"labels":[{"name":"x",...},...]}`.
    # Use jq if available; otherwise fall back to a tolerant grep+sed.
    if command -v jq >/dev/null 2>&1; then
      label_lines=$(printf '%s' "$labels_json" \
                      | jq -r '.labels[]?.name // empty' 2>/dev/null || true)
    else
      # Fallback: extract every "name":"…" inside the labels array. Good
      # enough for the canonical gh output shape; jq is the supported path.
      label_lines=$(printf '%s' "$labels_json" \
                      | tr ',' '\n' \
                      | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi

    if [ -n "$label_lines" ]; then
      for candidate in "${role_labels[@]}"; do
        while IFS= read -r lbl; do
          [ -z "$lbl" ] && continue
          # Case-insensitive equality match.
          lbl_lower=$(printf '%s' "$lbl" | tr '[:upper:]' '[:lower:]')
          if [ "$lbl_lower" = "$candidate" ]; then
            role_set="$candidate"
            break 2
          fi
        done <<< "$label_lines"
      done
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 6. Print.
#
# Field width matches slide 6 (column alignment to 19 chars after the
# label) so every briefing renders identically regardless of values.
# ---------------------------------------------------------------------------
printf '%-18s %s\n' "Active workspace:" "$workspace"
printf '%-18s %s\n' "Active ticket:"    "$ticket"
printf '%-18s %s\n' "Branch:"           "$branch"
printf '%-18s %s\n' "Role set:"         "$role_set"
