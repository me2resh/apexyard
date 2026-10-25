#!/usr/bin/env bash
# _lib-migrate.sh — keep CLI or move fork to init layout. Source from bin/apexyard.
# Bash 3.2. Reuses _lib-migration-chain.sh. Never deletes, archives, or force-pushes.
#
# Architecture evolution (#1886): safe keep (symlink only) or move (new empty
# repo + full history push). Chain walk stays shared with /update.

set -u

migrate_usage() {
  cat <<'EOF'
Usage: apexyard migrate [--path keep|move] [--new-repo OWNER/NAME] [--public]
                        [--target vN.N.N] [--run-migrations] [--dry-run] [--yes]

  keep  Symlink bin/apexyard into ${APEXYARD_BIN_DIR:-$HOME/.local/bin}.
  move  Create --new-repo, push full history, keep upstream. Archive old fork by hand.

Without --path, print both paths and exit 0. Never prompts.
EOF
}

migrate_die() { printf '%s\n' "apexyard migrate: $1" >&2; return 1; }
migrate_say() { printf '%s\n' "$1"; }
migrate_gh() { local b="${APEXYARD_GH:-gh}"; "$b" "$@"; }

migrate_resolve_root() {
  local r="${OPS_ROOT:-}"
  if [ -z "$r" ] || [ ! -d "$r" ]; then
    r=$(git rev-parse --show-toplevel 2>/dev/null) || r=""
  fi
  [ -n "$r" ] && [ -d "$r" ] || { migrate_die "not inside a git repo (set OPS_ROOT or cd into the fork)"; return 1; }
  MIGRATE_ROOT="$r"
  export OPS_ROOT="$MIGRATE_ROOT"
}

migrate_detect() {
  local json upstream_url
  MIGRATE_IS_FORK="unknown"; MIGRATE_PARENT=""; MIGRATE_HAS_UPSTREAM="no"; MIGRATE_VERSION="unknown"
  json=$(migrate_gh repo view --json isFork,parent 2>/dev/null) || json=""
  if [ -n "$json" ]; then
    printf '%s' "$json" | grep -q '"isFork"[[:space:]]*:[[:space:]]*true' && MIGRATE_IS_FORK="yes"
    printf '%s' "$json" | grep -q '"isFork"[[:space:]]*:[[:space:]]*false' && MIGRATE_IS_FORK="no"
    MIGRATE_PARENT=$(printf '%s' "$json" | sed -n 's/.*"nameWithOwner"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$MIGRATE_PARENT" ] || MIGRATE_PARENT=$(printf '%s' "$json" | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  fi
  upstream_url=$(git -C "$MIGRATE_ROOT" remote get-url upstream 2>/dev/null) || upstream_url=""
  [ -n "$upstream_url" ] && MIGRATE_HAS_UPSTREAM="yes"
  # shellcheck source=/dev/null
  . "$MIGRATE_ROOT/.claude/hooks/_lib-migration-chain.sh"
  MIGRATE_VERSION=$(migration_current_version)
  migrate_say "Detect:"
  migrate_say "  fork:     $MIGRATE_IS_FORK${MIGRATE_PARENT:+ (parent: $MIGRATE_PARENT)}"
  migrate_say "  upstream: $MIGRATE_HAS_UPSTREAM${upstream_url:+ ($upstream_url)}"
  migrate_say "  version:  $MIGRATE_VERSION"
}

migrate_print_paths() {
  cat <<'EOF'

Paths (pass --path keep|move; no prompt):
  (a) keep  Install the CLI only. Symlink bin/apexyard into
            ${APEXYARD_BIN_DIR:-$HOME/.local/bin}. Updates then run
            through `apexyard update`. Repo files stay unchanged.
  (b) move  Require --new-repo OWNER/NAME. Create that repo, rename
            origin to old-fork, push full history, keep upstream.
            You archive the old fork by hand after.
EOF
}

migrate_ownership_sanity() {
  local lib="$MIGRATE_ROOT/bin/_lib-ownership.sh"
  if [ -f "$lib" ]; then
    # shellcheck source=/dev/null
    . "$lib"
    if command -v ownership_class >/dev/null 2>&1; then
      migrate_say "ownership: $(ownership_class .claude/hooks/x || echo unmatched)"
    else
      migrate_say "ownership: library present but ownership_class missing"
    fi
  else
    migrate_say "ownership library not present yet"
  fi
}

migrate_highest_version() {
  local dir="$MIGRATE_ROOT/.claude/migrations" f base to highest=""
  [ -d "$dir" ] || { printf '%s' ""; return 0; }
  for f in "$dir"/v*-to-v*.sh; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .sh)
    to=$(printf '%s' "$base" | sed -E 's/^v[0-9]+\.[0-9]+\.[0-9]+-to-(v[0-9]+\.[0-9]+\.[0-9]+)$/\1/')
    [ -n "$to" ] || continue
    if [ -z "$highest" ] || _migration_semver_gt "$to" "$highest" 2>/dev/null; then
      highest="$to"
    fi
  done
  printf '%s' "$highest"
}

migrate_print_or_run_chain() {
  local target="$1" run_flag="$2" dry_run="$3" current chain pair rc old_ifs
  # shellcheck source=/dev/null
  . "$MIGRATE_ROOT/.claude/hooks/_lib-migration-chain.sh"
  current=$(migration_current_version)
  [ "$current" = "unknown" ] && migrate_say "Note: version is unknown. Set .claude/framework-version first."
  [ -n "$target" ] || target=$(migrate_highest_version)
  if [ -z "$target" ]; then
    migrate_say "Chain: (no migration pairs found; empty)"; return 0
  fi
  chain=$(migration_chain "$current" "$target") || chain=""
  migrate_say "Chain ($current -> $target):"
  if [ -z "$chain" ]; then migrate_say "  (empty)"
  else printf '%s\n' "$chain" | while IFS= read -r pair; do [ -n "$pair" ] && migrate_say "  $pair"; done
  fi
  [ "$run_flag" = "yes" ] || return 0
  if [ "$dry_run" = "yes" ]; then
    migrate_say "[dry-run] would run each pair, then write anchor $target"; return 0
  fi
  if [ -z "$chain" ]; then
    [ "$current" != "unknown" ] && [ "$current" = "$target" ] && migrate_say "Already at $target; nothing to run."
    return 0
  fi
  old_ifs="$IFS"; IFS='
'; set -- $chain; IFS="$old_ifs"
  for pair in "$@"; do
    [ -n "$pair" ] || continue
    migrate_say "Running $pair ..."
    migration_run "$pair"; rc=$?
    if [ "$rc" -ne 0 ]; then
      migrate_die "migration $pair exited $rc; stopped"; return "$rc"
    fi
  done
  migration_write_anchor "$target" || return 1
  migrate_say "Anchor written: $target"
}

migrate_path_keep() {
  local dry_run="$1" src dest dest_dir current
  src="$MIGRATE_ROOT/bin/apexyard"
  dest_dir="${APEXYARD_BIN_DIR:-$HOME/.local/bin}"
  dest="$dest_dir/apexyard"
  [ -f "$src" ] || { migrate_die "missing $src"; return 1; }
  migrate_say "Path keep: install CLI symlink $dest -> $src"
  if [ "$dry_run" = "yes" ]; then
    migrate_say "[dry-run] would mkdir -p $dest_dir and ln -s when safe"
    migrate_say "Updates then run through: apexyard update"; return 0
  fi
  mkdir -p "$dest_dir" || return 1
  if [ -L "$dest" ]; then
    current=$(readlink "$dest") || current=""
    if [ "$current" = "$src" ]; then
      migrate_say "Symlink already points here."
    else
      migrate_die "refusing to overwrite existing symlink at $dest (points to $current)"; return 1
    fi
  elif [ -e "$dest" ]; then
    migrate_die "refusing to overwrite existing file at $dest"; return 1
  else
    ln -s "$src" "$dest" || return 1
    migrate_say "Installed symlink: $dest"
  fi
  migrate_say "Updates then run through: apexyard update"
}

migrate_print_archive_instructions() {
  printf '%s\n' '  Archive the old fork by hand (Settings > Archive), or run:'
  printf '%s\n' '  gh repo archive OWNER/OLD-NAME --yes'
}

migrate_path_move() {
  local new_repo="$1" public="$2" dry_run="$3" visibility new_url parent_url ref
  [ -n "$new_repo" ] || { migrate_die "path move requires --new-repo OWNER/NAME"; return 1; }
  case "$new_repo" in */*) ;; *) migrate_die "--new-repo must be OWNER/NAME"; return 1 ;; esac
  if migrate_gh repo view "$new_repo" >/dev/null 2>&1; then
    migrate_die "repo $new_repo already exists; refuse to overwrite"; return 1
  fi
  if [ "$public" = "yes" ]; then visibility="--public"; else visibility="--private"; fi
  migrate_say "Path move: create $new_repo ($visibility), remotes, push history"
  if [ "$dry_run" = "yes" ]; then
    migrate_say "[dry-run] would: gh repo create $new_repo $visibility"
    migrate_say "[dry-run] would: rename origin -> old-fork; add new origin; ensure upstream"
    migrate_say "[dry-run] would: git push origin --all; git push origin --tags"
    migrate_print_archive_instructions; return 0
  fi
  # shellcheck disable=SC2086
  migrate_gh repo create "$new_repo" $visibility || { migrate_die "gh repo create failed for $new_repo"; return 1; }
  new_url=$(migrate_gh repo view "$new_repo" --json url -q .url 2>/dev/null) || new_url=""
  [ -n "$new_url" ] || { migrate_die "could not read url for $new_repo"; return 1; }
  if git -C "$MIGRATE_ROOT" remote get-url origin >/dev/null 2>&1; then
    git -C "$MIGRATE_ROOT" remote rename origin old-fork || return 1
  fi
  git -C "$MIGRATE_ROOT" remote add origin "$new_url" || return 1
  if ! git -C "$MIGRATE_ROOT" remote get-url upstream >/dev/null 2>&1; then
    parent_url=""
    if [ -n "$MIGRATE_PARENT" ]; then
      case "$MIGRATE_PARENT" in
        http*|git@*|ssh*) parent_url="$MIGRATE_PARENT" ;;
        */*)
          parent_url=$(migrate_gh repo view "$MIGRATE_PARENT" --json url -q .url 2>/dev/null) || parent_url=""
          [ -n "$parent_url" ] || parent_url="https://github.com/${MIGRATE_PARENT}.git"
          ;;
      esac
    fi
    if [ -n "$parent_url" ]; then
      git -C "$MIGRATE_ROOT" remote add upstream "$parent_url" || return 1
    else
      migrate_say "Warning: no parent url; upstream not set"
    fi
  fi
  git -C "$MIGRATE_ROOT" push origin --all || return 1
  # Branches that exist only on the old fork: copy them, never overwrite.
  for ref in $(git -C "$MIGRATE_ROOT" for-each-ref --format='%(refname:strip=3)' refs/remotes/old-fork/); do
    [ "$ref" = "HEAD" ] && continue
    git -C "$MIGRATE_ROOT" show-ref --verify --quiet "refs/heads/$ref" && continue
    git -C "$MIGRATE_ROOT" push origin "refs/remotes/old-fork/$ref:refs/heads/$ref" || return 1
  done
  git -C "$MIGRATE_ROOT" push origin --tags || return 1
  migrate_say "Pushed full history to $new_repo"
  migrate_print_archive_instructions
}

apexyard_migrate() {
  local path="" new_repo="" public="no" target="" run_migrations="no" dry_run="no"
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help|help) migrate_usage; return 0 ;;
      --path) shift; path="${1:-}"; [ -n "$path" ] || { migrate_die "--path needs keep|move"; return 1; } ;;
      --new-repo) shift; new_repo="${1:-}"; [ -n "$new_repo" ] || { migrate_die "--new-repo needs OWNER/NAME"; return 1; } ;;
      --public) public="yes" ;;
      --target) shift; target="${1:-}"; [ -n "$target" ] || { migrate_die "--target needs vN.N.N"; return 1; } ;;
      --run-migrations) run_migrations="yes" ;;
      --dry-run) dry_run="yes" ;;
      --yes) ;; # accepted; flow never prompts
      *) migrate_die "unknown flag '$1'"; migrate_usage >&2; return 2 ;;
    esac
    shift
  done
  migrate_resolve_root || return 1
  migrate_detect || return 1
  if [ -z "$path" ]; then
    migrate_print_paths
    migrate_print_or_run_chain "$target" "$run_migrations" "$dry_run" || return 1
    return 0
  fi
  case "$path" in
    keep) migrate_path_keep "$dry_run" || return 1 ;;
    move) migrate_path_move "$new_repo" "$public" "$dry_run" || return 1 ;;
    *) migrate_die "--path must be keep or move"; return 1 ;;
  esac
  migrate_print_or_run_chain "$target" "$run_migrations" "$dry_run" || return 1
}
