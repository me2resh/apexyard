#!/bin/bash
# link-custom-skills.sh — SessionStart hook
#
# Surfaces company-private custom skills (stored in the split-portfolio
# private sibling repo at <private>/custom-skills/<name>/) to Claude Code
# via the public fork's .claude/skills/ discovery path.
#
# Implementation: gitignored symlinks at .claude/skills/<name>/ pointing to
# <private>/custom-skills/<name>/. Claude Code's skill discovery walks
# .claude/skills/*/SKILL.md, so the symlink makes the private skill
# transparently visible without copying or moving anything.
#
# Behaviour summary (advisory hook — exit 0 always; this is plumbing, not
# a gate):
#
#   - No private custom-skills dir resolved or directory missing → no-op,
#     silent. Single-fork adopters and split-portfolio adopters who haven't
#     created custom-skills/ yet see nothing.
#   - For each subdirectory under <private>/custom-skills/<name>/ that
#     contains SKILL.md, ensure a symlink exists at .claude/skills/<name>.
#       * If a framework skill of the same name exists at .claude/skills/<name>
#         AS A REAL DIRECTORY (not a symlink we created previously), the custom
#         skill WINS — we replace it with the symlink and emit a one-line
#         visible warning naming the override.
#       * If the existing entry is already a symlink to the same target, no-op.
#       * If the existing entry is a symlink to a different target, replace
#         it (operator may have changed the private dir).
#   - On Windows: decline gracefully — print a one-line manual-install
#     pointer and skip. Mirrors the LSP-on-Windows behaviour from /setup.
#
# All output goes to stderr so it shows up in the SessionStart banner stream
# without polluting stdout that other hooks/skills might consume.

set -u

# Detect Windows. Same shape as /setup Step 2c.5(a).
case "${OSTYPE:-}" in
  msys*|cygwin*|win32*)
    IS_WINDOWS=1
    ;;
  *)
    IS_WINDOWS=0
    ;;
esac
if [ "$IS_WINDOWS" -eq 0 ]; then
  case "$(uname -s 2>/dev/null)" in
    MINGW*|CYGWIN*|Windows*) IS_WINDOWS=1 ;;
  esac
fi

# Resolve the ops-fork root by walking up from $PWD. Cheaper than the full
# helper for the no-op cases (no helper sourced, no jq fork). The helper
# walks the same path; we replicate that minimal logic here so the hook
# stays useful even if the lib hasn't been installed yet on a fresh fork.
ops_root=""
cur="$PWD"
while [ -n "$cur" ] && [ "$cur" != "/" ]; do
  if [ -f "$cur/.apexyard-fork" ]; then
    ops_root="$cur"; break
  fi
  if [ -f "$cur/onboarding.yaml" ] && [ -f "$cur/apexyard.projects.yaml" ]; then
    ops_root="$cur"; break
  fi
  cur=$(dirname "$cur")
done

# Outside any apexyard fork → nothing to do.
[ -z "$ops_root" ] && exit 0

LIB_PORTFOLIO="$ops_root/.claude/hooks/_lib-portfolio-paths.sh"
LIB_CONFIG="$ops_root/.claude/hooks/_lib-read-config.sh"

# Helpers missing → no-op silently. The hook can't resolve paths without
# them, and complaining loudly on every session start would be noise during
# a botched install.
[ ! -f "$LIB_PORTFOLIO" ] && exit 0
[ ! -f "$LIB_CONFIG" ] && exit 0

# shellcheck source=/dev/null
. "$LIB_CONFIG"
# shellcheck source=/dev/null
. "$LIB_PORTFOLIO"

custom_skills_dir=$(portfolio_custom_skills_dir 2>/dev/null)

# Helper failure → no-op silently.
[ -z "$custom_skills_dir" ] && exit 0

# No custom-skills dir on disk → no-op silently. This is the most common
# case (every fork that hasn't opted in to private custom skills).
[ ! -d "$custom_skills_dir" ] && exit 0

# Found a custom-skills dir. Now, if we're on Windows, decline gracefully.
# We hit this AFTER detecting a configured custom-skills dir so adopters
# who don't use custom skills don't see Windows-specific output.
if [ "$IS_WINDOWS" -eq 1 ]; then
  echo "ApexYard: detected $custom_skills_dir but symlink-based skill linking is not supported on Windows in this release." >&2
  echo "  Manual workaround: copy each subdir of custom-skills/ into .claude/skills/ on this machine." >&2
  echo "  See docs/multi-project.md § 'Private custom skills + handbooks' for the full pointer." >&2
  exit 0
fi

skills_target_dir="$ops_root/.claude/skills"
mkdir -p "$skills_target_dir"

# Iterate every direct child of custom_skills_dir that is itself a directory
# AND contains SKILL.md (skip README.md / accidental files).
linked_count=0
collision_warnings=""
for src in "$custom_skills_dir"/*/; do
  # Glob with no matches expands to the literal pattern — guard.
  [ -d "$src" ] || continue
  src="${src%/}"
  name=$(basename "$src")

  # Skip if the source dir doesn't contain a SKILL.md — nothing for Claude
  # Code to discover.
  [ -f "$src/SKILL.md" ] || continue

  target="$skills_target_dir/$name"

  # If target is already a symlink, check where it points. Idempotent path:
  # already pointing at this src → nothing to do.
  if [ -L "$target" ]; then
    existing=$(readlink "$target" 2>/dev/null || echo "")
    # Resolve relative existing → absolute for fair comparison.
    case "$existing" in
      /*) ;;
      *)  existing="$skills_target_dir/$existing" ;;
    esac
    # Canonicalise both sides for comparison. We use cd+pwd because
    # `realpath` isn't always present on macOS.
    canon_existing=$(cd "$(dirname "$existing")" 2>/dev/null && pwd -P)/$(basename "$existing")
    canon_src=$(cd "$(dirname "$src")" 2>/dev/null && pwd -P)/$(basename "$src")
    if [ "$canon_existing" = "$canon_src" ]; then
      # Already linked correctly. No-op.
      continue
    fi
    # Symlink points elsewhere — operator may have re-pointed the private
    # dir. Replace.
    rm -f "$target"
    ln -s "$src" "$target"
    linked_count=$((linked_count + 1))
    continue
  fi

  # If a real directory exists at the target → name collision with a
  # framework skill (or a previously-installed adopter copy). Custom wins;
  # warn visibly.
  if [ -d "$target" ]; then
    # Move the existing dir aside as a backup so we don't lose it. The
    # backup name is deterministic (no timestamp) so re-runs converge.
    backup="${target}.framework.bak"
    if [ ! -e "$backup" ]; then
      mv "$target" "$backup"
    else
      # Backup already exists from a previous run — just remove the dir.
      rm -rf "$target"
    fi
    ln -s "$src" "$target"
    linked_count=$((linked_count + 1))
    collision_warnings="${collision_warnings}  - $name (custom override; framework version moved to $(basename "$backup"))\n"
    continue
  fi

  # Nothing at the target — create the symlink.
  ln -s "$src" "$target"
  linked_count=$((linked_count + 1))
done

# Surface a one-line summary if we did anything, plus any collision
# warnings. Stay silent when there's nothing to report.
if [ "$linked_count" -gt 0 ]; then
  echo "ApexYard: linked $linked_count custom skill(s) from $custom_skills_dir into .claude/skills/." >&2
fi

if [ -n "$collision_warnings" ]; then
  echo "ApexYard: custom skill(s) override framework skill(s):" >&2
  printf "%b" "$collision_warnings" >&2
fi

exit 0
