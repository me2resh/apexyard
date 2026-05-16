#!/usr/bin/env bash
# /process cross-repo.sh
#
# Resolve a cross-repo handoff candidate against apexyard.projects.yaml.
#
# Inputs (env or args):
#   --target=<name|owner/repo|url>   the handoff target as detected by discover.sh
#   --registry=<path>                override registry path (default: portfolio_registry)
#
# Outputs (single line on stdout):
#   registered:<name>:cloned         the target is a registered project AND its workspace clone exists
#   registered:<name>:missing        registered but workspace/<name>/ doesn't exist (offer to clone)
#   external                         not in the registry — render as external participant pool
#
# Exit codes: 0 on resolution (any of the three outputs), 2 on bad input.

set -euo pipefail

TARGET=""
REGISTRY_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --target=*)   TARGET="${1#--target=}";   shift ;;
    --registry=*) REGISTRY_OVERRIDE="${1#--registry=}"; shift ;;
    --help|-h)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *)
      echo "cross-repo.sh: unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "cross-repo.sh: --target is required" >&2
  exit 2
fi

# Normalise the target: strip URL prefix + .git suffix.
target_norm="$TARGET"
target_norm="${target_norm#https://github.com/}"
target_norm="${target_norm#git@github.com:}"
target_norm="${target_norm%.git}"

# Extract a candidate short-name: if target is `owner/repo`, use `repo`;
# if it's a bare name, use as-is; if it's a URL with a path, use the last segment.
short_name="$target_norm"
case "$target_norm" in
  */*) short_name="${target_norm##*/}" ;;
esac

# ---------------------------------------------------------------------------
# Resolve registry path. Prefer the framework helper; fall back to literal.
# ---------------------------------------------------------------------------
REGISTRY=""
if [ -n "$REGISTRY_OVERRIDE" ]; then
  REGISTRY="$REGISTRY_OVERRIDE"
else
  if command -v git >/dev/null 2>&1; then
    toplevel=$(git rev-parse --show-toplevel 2>/dev/null || true)
  else
    toplevel=""
  fi
  if [ -n "$toplevel" ] && [ -f "$toplevel/.claude/hooks/_lib-portfolio-paths.sh" ]; then
    # shellcheck source=/dev/null
    . "$toplevel/.claude/hooks/_lib-read-config.sh"
    # shellcheck source=/dev/null
    . "$toplevel/.claude/hooks/_lib-portfolio-paths.sh"
    REGISTRY=$(portfolio_registry)
  fi
fi

if [ -z "$REGISTRY" ] || [ ! -f "$REGISTRY" ]; then
  # No registry → can't resolve — treat as external.
  echo "external"
  exit 0
fi

# ---------------------------------------------------------------------------
# Look up by name OR by repo slug. Two strategies: yq if available, awk fallback.
# Same fallback shape as /start-ticket's registry lookup.
# ---------------------------------------------------------------------------
project_name=""
project_workspace=""

lookup_with_yq() {
  local query
  # Match by either name or repo slug (case-insensitive on name).
  query=$(cat <<EOF
.projects[] | select(
  (.name | downcase) == "$(echo "$short_name" | tr '[:upper:]' '[:lower:]')"
  or .repo == "$target_norm"
  or .repo == "$short_name"
) | .name + "\t" + (.workspace // "")
EOF
)
  yq eval "$query" "$REGISTRY" 2>/dev/null | head -1
}

lookup_with_awk() {
  # Greppy fallback — handles bare AND quoted scalars; tolerates leading whitespace.
  # Assumes `- name:` is the first key in each entry (same assumption as
  # /start-ticket — see that skill's SKILL.md for the assumption notes).
  #
  # Logic: when we hit a new `- name:` line, flush the previous entry's
  # accumulated (name, repo, ws) tuple — if it matches the lookup, print
  # and exit. Then start accumulating the new entry. END block handles
  # the final entry (no subsequent `- name:` to trigger its flush).
  #
  # A `done` sentinel suppresses the END-block flush after we've already
  # printed (awk's `exit` still runs END, which would otherwise print the
  # next-entry name once that name is read by the time END fires).
  awk -v t="$target_norm" -v s="$short_name" '
    function unquote(x) { gsub(/^["\x27]|["\x27]$/, "", x); return x }
    function value_after_colon(line) {
      sub(/^[^:]*:[[:space:]]*/, "", line);
      return unquote(line);
    }
    /^[[:space:]]*-[[:space:]]+name:/ {
      # Flush the PREVIOUS entry first, then start the new one.
      if (name && (name == s || repo == t || repo == s)) {
        print name "\t" ws;
        done = 1;
        exit;
      }
      name = value_after_colon($0);
      ws = "";
      repo = "";
      next;
    }
    /^[[:space:]]+repo:/      { repo = value_after_colon($0); next }
    /^[[:space:]]+workspace:/ { ws   = value_after_colon($0); next }
    END {
      if (done) exit;
      if (name && (name == s || repo == t || repo == s)) {
        print name "\t" ws;
      }
    }
  ' "$REGISTRY"
}

if command -v yq >/dev/null 2>&1; then
  match=$(lookup_with_yq || true)
else
  match=$(lookup_with_awk || true)
fi

if [ -z "$match" ]; then
  echo "external"
  exit 0
fi

project_name=$(printf '%s\n' "$match" | awk -F'\t' '{print $1}')
project_workspace=$(printf '%s\n' "$match" | awk -F'\t' '{print $2}')

# Default workspace path if the field is empty: workspace/<name>.
if [ -z "$project_workspace" ]; then
  project_workspace="workspace/$project_name"
fi

# Resolve the workspace dir.
#
# Two cases:
#   1. --registry was passed explicitly (test mode, or operator overriding):
#      resolve workspace relative to the registry's parent dir. This matches
#      the convention that the registry and its referenced paths live in
#      the same root (single-fork: ops fork; split-portfolio: private repo).
#   2. No override — defer to portfolio_workspace_dir helper if loaded,
#      which respects split-portfolio v2's `workspace_dir` config. Workspace
#      field may already be absolute (then use as-is).
if [ -n "$REGISTRY_OVERRIDE" ]; then
  reg_dir=$(dirname "$REGISTRY")
  case "$project_workspace" in
    /*) abs_ws="$project_workspace" ;;
    *)  abs_ws="$reg_dir/$project_workspace" ;;
  esac
elif command -v portfolio_workspace_dir >/dev/null 2>&1; then
  ws_root=$(portfolio_workspace_dir)
  case "$project_workspace" in
    /*) abs_ws="$project_workspace" ;;
    *)  abs_ws="$ws_root/$(basename "$project_workspace")" ;;
  esac
else
  reg_dir=$(dirname "$REGISTRY")
  case "$project_workspace" in
    /*) abs_ws="$project_workspace" ;;
    *)  abs_ws="$reg_dir/$project_workspace" ;;
  esac
fi

if [ -d "$abs_ws" ] && [ -d "$abs_ws/.git" ]; then
  echo "registered:${project_name}:cloned:${abs_ws}"
else
  echo "registered:${project_name}:missing:${abs_ws}"
fi

exit 0
