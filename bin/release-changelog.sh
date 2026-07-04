#!/usr/bin/env bash
# bin/release-changelog.sh — Generate a CHANGELOG section from git log between two refs.
#
# Used by the /release skill (AgDR-0076) to automate the changelog-generation
# step. Emits markdown to stdout; never writes files (callers decide where to put it).
#
# Environment variables (all required):
#   PREV_TAG   — the previous release tag (e.g. v3.2.0); used as the start of
#                git log range. Pass "NONE" if there is no previous tag.
#   HEAD_REF   — the end of the git log range (e.g. upstream/dev or a branch name)
#   VERSION    — the new version string (e.g. v3.3.0)
#   DATE       — the release date in YYYY-MM-DD format
#
# Optional:
#   REPO_REMOTE — the git remote to use for upstream refs (default: upstream)
#
# Output format (matches the existing CHANGELOG.md convention):
#
#   ## [VERSION] — DATE
#
#   <release description line> (omitted if empty)
#
#   ### Added (feat)
#   - (#NN) <subject> — <short-sha>
#   ...
#   ### Fixed (fix)
#   - (#NN) <subject> — <short-sha>
#   ...
#   ### Changed (refactor / chore / docs / style / perf / build / ci / test)
#   - (#NN) <subject> — <short-sha>
#   ...
#   ### Breaking
#   - <subject> — <short-sha>
#   ...
#   ### Closes
#   - Closes #N, #M, ...
#
# Exit codes:
#   0 — success (even if the commit list is empty; that is a valid patch release)
#   1 — missing required env var or git command failure

set -euo pipefail

# ── Validate required env vars ──────────────────────────────────────────────

for var in PREV_TAG HEAD_REF VERSION DATE; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is required but not set." >&2
    echo "Usage: PREV_TAG=v3.2.0 HEAD_REF=upstream/dev VERSION=v3.3.0 DATE=2026-06-21 bash bin/release-changelog.sh" >&2
    exit 1
  fi
done

REPO_REMOTE="${REPO_REMOTE:-upstream}"

# ── Build the git log range ──────────────────────────────────────────────────

if [ "$PREV_TAG" = "NONE" ]; then
  LOG_RANGE="${HEAD_REF}"
else
  # #737: PREV_TAG is a *squash* commit on main. Under the release-cut model the
  # individual commits it squashed live on HEAD_REF (dev) but are NOT ancestors
  # of the tag — so a naive PREV_TAG..HEAD_REF range (and even
  # merge-base(PREV_TAG,dev)..dev) surfaces EVERY already-released commit,
  # massively over-counting (v4.1.0 reported 102 feats / 263 commits for a
  # ~1-feature delta). The correct start is the POST-SYNC BOUNDARY: after each
  # release, `/release-sync` lands a "sync: merge main into dev after <ver>"
  # commit (and its "...sync/main-to-dev-after-<ver>" PR merge) on dev. Commits
  # AFTER the most recent such marker are exactly the unreleased delta.
  # Patterns are VERSION-ANCHORED so they only match real sync commits, never a
  # prose mention of the convention in some other commit body (e.g. this very
  # fix's commit, or a doc PR) — an unanchored 'sync/main-to-dev-after' would
  # let a later commit hijack the boundary and DROP unreleased work (#749 review).
  SYNC=$(git log "$HEAD_REF" --max-count=1 --pretty=format:'%H' \
           --grep='^sync: merge main into dev after v[0-9]' \
           --grep='sync/main-to-dev-after-v[0-9]' 2>/dev/null || true)
  if [ -n "$SYNC" ]; then
    LOG_RANGE="${SYNC}..${HEAD_REF}"
  else
    # No sync boundary on dev (first release under the model, or sync skipped):
    # best available fallback is the merge-base, then the raw tag range.
    BASE=$(git merge-base "$PREV_TAG" "$HEAD_REF" 2>/dev/null || true)
    LOG_RANGE="${BASE:-$PREV_TAG}..${HEAD_REF}"
  fi
fi

# ── Extract commits ──────────────────────────────────────────────────────────
# Format: <short-sha> <subject>
# We use %h (abbreviated sha) and %s (subject) so merge commits are included.

COMMITS=$(git log "$LOG_RANGE" --pretty=format:'%h %s' 2>/dev/null || true)

# ── Classify commits ─────────────────────────────────────────────────────────

added_lines=()
fixed_lines=()
changed_lines=()
breaking_lines=()
closes_nums=()

# Extract PR number from subject: "Merge pull request #NN from ..." or "(#NN)" in subject
extract_pr_num() {
  local subject="$1"
  # Merge commit format: "Merge pull request #NNN from ..."
  if echo "$subject" | grep -qE 'Merge pull request #[0-9]+'; then
    echo "$subject" | grep -oE '#[0-9]+' | head -1
    return
  fi
  # Conventional commit with PR ref: "feat(#NNN): ..." or "feat: something (#NNN)"
  if echo "$subject" | grep -qE '\(#[0-9]+\)'; then
    echo "$subject" | grep -oE '#[0-9]+' | head -1
    return
  fi
  echo ""
}

# Strip conventional-commit prefix from a subject for cleaner display
strip_cc_prefix() {
  local subject="$1"
  # Remove "type(scope): " or "type: " prefix
  echo "$subject" | sed -E 's/^[a-z]+(\([^)]*\))?!?: //'
}

while IFS= read -r line; do
  [ -z "$line" ] && continue

  short_sha="${line%% *}"
  subject="${line#* }"

  # Skip merge commits for "Merge branch" (sync commits) — only keep "Merge pull request"
  if echo "$subject" | grep -qE '^Merge branch '; then
    continue
  fi

  # Skip release commits themselves
  if echo "$subject" | grep -qE '^release(\([^)]*\))?!?:'; then
    continue
  fi

  # Skip sync commits
  if echo "$subject" | grep -qE '^sync(\([^)]*\))?!?:'; then
    continue
  fi

  pr_num=$(extract_pr_num "$subject")
  display_subject=$(strip_cc_prefix "$subject")

  # Remove trailing PR reference like "(#NNN)" from end of display subject
  display_subject=$(echo "$display_subject" | sed -E 's/ \(#[0-9]+\)$//')

  # Build the display line
  if [ -n "$pr_num" ]; then
    entry="- ($pr_num) $display_subject — $short_sha"
    # Collect PR number for Closes section
    num_only="${pr_num#\#}"
    closes_nums+=("$num_only")
  else
    entry="- $display_subject — $short_sha"
  fi

  # Classify by conventional-commit type
  if echo "$subject" | grep -qE '^[a-z]+(\([^)]*\))?!:'; then
    # Breaking change (any type with !)
    breaking_lines+=("$entry")
  elif echo "$subject" | grep -qE '^feat(\([^)]*\))?:'; then
    added_lines+=("$entry")
  elif echo "$subject" | grep -qE '^fix(\([^)]*\))?:'; then
    fixed_lines+=("$entry")
  elif echo "$subject" | grep -qE '^(refactor|chore|docs|style|perf|build|ci|test)(\([^)]*\))?:'; then
    changed_lines+=("$entry")
  elif echo "$subject" | grep -qE '^Merge pull request'; then
    # Merge commits for PRs are captured above via pr_num extraction;
    # the commit itself shows up under the type of the PR's own commit.
    # Skip duplicate merge-commit entries.
    continue
  else
    # Unknown type — put in Changed
    changed_lines+=("$entry")
  fi

done <<< "$COMMITS"

# ── Infer release description ─────────────────────────────────────────────────

if [ "${#breaking_lines[@]}" -gt 0 ]; then
  bump_type="Major release"
elif [ "${#added_lines[@]}" -gt 0 ]; then
  bump_type="Minor release"
else
  bump_type="Patch release"
fi

feat_count="${#added_lines[@]}"
fix_count="${#fixed_lines[@]}"
desc_parts=()
[ "$feat_count" -gt 0 ] && desc_parts+=("${feat_count} feature$([ "$feat_count" -gt 1 ] && echo 's' || echo '')")
[ "$fix_count" -gt 0 ] && desc_parts+=("${fix_count} fix$([ "$fix_count" -gt 1 ] && echo 'es' || echo '')")
[ "${#changed_lines[@]}" -gt 0 ] && desc_parts+=("${#changed_lines[@]} improvement$([ "${#changed_lines[@]}" -gt 1 ] && echo 's' || echo '')")

if [ "${#desc_parts[@]}" -gt 0 ]; then
  IFS=', '; release_desc="$bump_type — ${desc_parts[*]}."
  IFS=$' \t\n'
else
  release_desc="$bump_type."
fi

# ── Emit the CHANGELOG section ───────────────────────────────────────────────

echo "## [$VERSION] — $DATE"
echo ""
echo "$release_desc"

if [ "${#added_lines[@]}" -gt 0 ]; then
  echo ""
  echo "### Added (feat)"
  echo ""
  for l in "${added_lines[@]}"; do echo "$l"; done
fi

if [ "${#fixed_lines[@]}" -gt 0 ]; then
  echo ""
  echo "### Fixed (fix)"
  echo ""
  for l in "${fixed_lines[@]}"; do echo "$l"; done
fi

if [ "${#changed_lines[@]}" -gt 0 ]; then
  echo ""
  echo "### Changed (refactor / chore / docs)"
  echo ""
  for l in "${changed_lines[@]}"; do echo "$l"; done
fi

if [ "${#breaking_lines[@]}" -gt 0 ]; then
  echo ""
  echo "### Breaking"
  echo ""
  for l in "${breaking_lines[@]}"; do echo "$l"; done
fi

if [ "${#closes_nums[@]}" -gt 0 ]; then
  echo ""
  echo "### Closes"
  echo ""
  # Deduplicate and sort
  unique_nums=$(printf '%s\n' "${closes_nums[@]}" | sort -un | tr '\n' ' ' | sed 's/ $//')
  closes_str=""
  for n in $unique_nums; do closes_str="${closes_str}#${n}, "; done
  closes_str="${closes_str%, }"  # trim trailing comma+space
  echo "- Closes $closes_str"
fi
