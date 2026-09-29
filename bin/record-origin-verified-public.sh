#!/usr/bin/env bash
# bin/record-origin-verified-public.sh — record offline proof that origin is public.
#
# /setup and /update call this once while network access is available. The
# staged and runtime leak hooks stay offline and read
# leak_protection.origin_verified_public from .claude/project-config.json.
# See AgDR-0190 and me2resh/apexyard#1477.
#
# Usage:
#   bin/record-origin-verified-public.sh [--repo-dir <path>]
#
# Options:
#   --repo-dir <path>  Git repo whose origin to check (default: cwd).
#
# Exit codes:
#   0 — wrote leak_protection.origin_verified_public (visibility PUBLIC)
#   1 — no PUBLIC proof (private, non-PUBLIC, gh missing/failed, no origin slug)
#   2 — usage error or target is not a git repository
#
# When GitHub answers that origin is not PUBLIC, the script removes an
# existing key, because the earlier proof is now wrong. When the check
# itself fails (no gh, no network, no auth), the script keeps an existing
# key. A key that no longer matches origin is ignored by the hooks
# (exact-match only).

set -u

REPO_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-dir)
      [ $# -ge 2 ] || {
        echo "usage: $0 [--repo-dir <path>]" >&2
        exit 2
      }
      REPO_DIR=$2
      shift 2
      ;;
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *)
      echo "usage: $0 [--repo-dir <path>]" >&2
      exit 2
      ;;
  esac
done

if [ -n "$REPO_DIR" ]; then
  cd "$REPO_DIR" || {
    echo "record-origin-verified-public: cannot cd to --repo-dir: $REPO_DIR" >&2
    exit 2
  }
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "record-origin-verified-public: not inside a git repository." >&2
  exit 2
}
cd "$ROOT" || exit 2

origin_url=$(git remote get-url origin 2>/dev/null || true)
slug=$(printf '%s' "$origin_url" | sed -nE 's|.*github\.com[:/]([^/]+/[^/]+)(\.git)?$|\1|p' | sed 's/\.git$//')
if [ -z "$slug" ]; then
  echo "Origin exemption is OFF: could not parse an owner/repo slug from the origin remote."
  echo "Hooks will not exempt origin identity until /setup or /update records a public origin."
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Origin exemption is OFF for $slug: gh is not on PATH, so visibility could not be checked."
  echo "Install GitHub CLI, then re-run /setup or /update (or this script) while online."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Origin exemption is OFF for $slug: jq is required to write .claude/project-config.json."
  exit 1
fi

config_path=".claude/project-config.json"
recorded=""
if [ -f "$config_path" ]; then
  recorded=$(jq -r '.leak_protection.origin_verified_public // empty' "$config_path" 2>/dev/null)
fi

view_json=$(gh repo view "$slug" --json visibility,isFork 2>/dev/null) || {
  if [ -n "$recorded" ] && [ "$recorded" = "$slug" ]; then
    echo "Could not check $slug: gh repo view failed (auth, network, or missing repo)."
    echo "The earlier proof for $slug stays in place. Re-run /update when gh works."
  else
    echo "Origin exemption is OFF for $slug: gh repo view failed (auth, network, or missing repo)."
    echo "Hooks stay fail-closed. Fix gh access and re-run /setup or /update."
  fi
  exit 1
}

visibility=$(printf '%s' "$view_json" | jq -r '.visibility // empty')
if [ "$visibility" != "PUBLIC" ]; then
  echo "Origin exemption is OFF for $slug: visibility is ${visibility:-unknown} (not PUBLIC)."
  echo "A private origin is normal for many ops repos. Hooks will not exempt its identity."
  if [ -n "$recorded" ]; then
    # GitHub answered, and origin is not public. An earlier proof is now
    # wrong (for example, the repo was made private), so remove it.
    tmp=$(mktemp) || exit 1
    if jq 'if .leak_protection then .leak_protection |= del(.origin_verified_public) else . end' \
         "$config_path" > "$tmp"; then
      mv "$tmp" "$config_path"
      echo "Removed the earlier leak_protection.origin_verified_public=$recorded."
    else
      rm -f "$tmp"
      echo "Could not remove the earlier leak_protection.origin_verified_public from $config_path." >&2
    fi
  else
    echo "Did not write leak_protection.origin_verified_public."
  fi
  exit 1
fi

mkdir -p .claude
config_path=".claude/project-config.json"
if [ -f "$config_path" ]; then
  tmp=$(mktemp) || exit 1
  if ! jq --arg slug "$slug" \
    '.leak_protection = ((.leak_protection // {}) + {origin_verified_public: $slug})' \
    "$config_path" > "$tmp"; then
    rm -f "$tmp"
    echo "Origin exemption is OFF for $slug: failed to update $config_path." >&2
    exit 1
  fi
  mv "$tmp" "$config_path"
else
  jq -n --arg slug "$slug" \
    '{leak_protection: {origin_verified_public: $slug}}' > "$config_path" || {
    echo "Origin exemption is OFF for $slug: failed to create $config_path." >&2
    exit 1
  }
fi

echo "Recorded leak_protection.origin_verified_public=$slug (origin is PUBLIC)."
echo "Staged and runtime leak hooks will exempt this origin identity offline."
exit 0
