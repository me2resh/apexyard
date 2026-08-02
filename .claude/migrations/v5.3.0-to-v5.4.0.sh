#!/bin/bash
# v5.3.0 → v5.4.0 migration: untrack .claude/project-config.json (data-loss fix)
#
# v5.4.0 carries the adopter-side completion of #1065 (fix(#1031)). The root
# cause #1065 found: .gitignore listed .claude/project-config.json, but the
# file was ALSO tracked in the index — and git ignores .gitignore for
# already-tracked files, so the ignore rule was inert for every adopter fork.
#
# Because the file was tracked, a plain `git checkout <branch>` writes the
# indexed version straight over the working copy, with no warning. For a
# split-portfolio adopter that silently DESTROYS the private `portfolio` block,
# which is load-bearing (path resolution is config-only, there is no
# convention-based sibling discovery) and never in git to restore from. This
# happened on a real fork.
#
# #1065 fixed the framework side: it untracked the file and shipped a tracked
# project-config.example.json. But an adopter on v5.3.0 STILL has the file
# tracked in their own fork — the data-loss window stays open for them until
# the file is untracked there too. That is what this migration does.
#
# What it does: if .claude/project-config.json is currently tracked in the ops
# fork, `git rm --cached` it — removing it from the index while leaving the
# working-tree file (and the adopter's customisations in it) exactly in place.
# The existing .gitignore entry then finally applies. Nothing is committed; the
# untrack is staged for the operator to commit, matching the rest of /update's
# "operator owns each material change" stance.
#
# Idempotent: if the file is already untracked (e.g. the sync merge already
# resolved it that way, or the migration already ran), this is a no-op. Never
# forces — if the file has staged content that differs from both HEAD and the
# working tree, it defers to the operator (exit 1) rather than risk discarding
# a staged change.
#
# Exit codes:
#   0 — applied or skipped (success either way — untracked, or already untracked)
#   1 — conflict requires operator (unexpected staged state on the file)
#   2 — hard error (not in a git repo / ops root unresolvable)
#
# Env knobs:
#   APEXYARD_MIGRATION_QUIET  1 to suppress informational stdout (real errors
#                             still go to stderr)

set -u

QUIET="${APEXYARD_MIGRATION_QUIET:-0}"
info() { [ "$QUIET" = "1" ] || echo "$@"; }
warn() { echo "$@" >&2; }

# --- find the ops fork root --------------------------------------------------
# Anchored by EITHER .apexyard-fork (split-portfolio v2 — onboarding.yaml and
# apexyard.projects.yaml live in the sibling private repo, not the fork) OR the
# legacy v1 pair (onboarding.yaml AND apexyard.projects.yaml in one dir).
# .claude/project-config.json lives at the ops fork root in BOTH modes.
find_ops_root() {
  local r cur
  r=$(git rev-parse --show-toplevel 2>/dev/null) || r=""
  [ -z "$r" ] && { echo ""; return 1; }
  cur="$r"
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    [ -f "$cur/.apexyard-fork" ] && { echo "$cur"; return 0; }
    if [ -f "$cur/onboarding.yaml" ] && [ -f "$cur/apexyard.projects.yaml" ]; then
      echo "$cur"; return 0
    fi
    cur=$(dirname "$cur")
  done
  # No anchor found — fall back to the git toplevel. project-config.json is
  # root-relative there too; the tracked-guard below stays the real safety net.
  echo "$r"
}

ops_root=$(find_ops_root)
if [ -z "$ops_root" ]; then
  warn "migration v5.3.0→v5.4.0: not inside a git repository — cannot resolve the ops fork. Skipping."
  exit 2
fi
cd "$ops_root" || { warn "migration v5.3.0→v5.4.0: cannot cd to ops root '$ops_root'."; exit 2; }

target=".claude/project-config.json"

# --- idempotency guard: only act if the file is currently TRACKED ------------
if ! git ls-files --error-unmatch "$target" >/dev/null 2>&1; then
  info "migration v5.3.0→v5.4.0: $target is already untracked — nothing to do."
  exit 0
fi

# --- untrack, preserving the working-tree file -------------------------------
# `git rm --cached` removes the index entry only; the on-disk file (and the
# adopter's customisations in it) is untouched. It refuses (non-zero) ONLY when
# the staged content matches neither HEAD nor the working-tree file — a rare
# state we deliberately do NOT force past.
if rm_err=$(git rm --cached --quiet "$target" 2>&1); then
  info "migration v5.3.0→v5.4.0: untracked $target (working-tree file preserved; untrack staged for commit)."
  info "  Your customisations stay in the on-disk file, now correctly ignored by .gitignore."
  info "  This closes the #1065 data-loss window (a git checkout can no longer overwrite it)."
  exit 0
fi

warn "migration v5.3.0→v5.4.0: could not untrack $target — it has staged content that differs from both HEAD and the working tree."
[ -n "$rm_err" ] && warn "  git: $rm_err"
warn "  Resolve manually (commit or reset the staged change), then run: git rm --cached $target"
exit 1
