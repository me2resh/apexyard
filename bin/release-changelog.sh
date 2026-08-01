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
#   - Closes #N
#   - Closes #M
#   ...
#
# Closes resolution (#1056, #1076):
#   GitHub's `Closes` keyword only auto-closes the reference IMMEDIATELY
#   FOLLOWING it — a single "Closes #A, #B, #C" line only ever closes #A, so
#   the section above emits one "- Closes #N" bullet per reference instead.
#
#   Governing rule (#1076): PREFER A MISSING CLOSE OVER A WRONG CLOSE. A
#   `- Closes #N` bullet is emitted ONLY when the commit subject carries a
#   recognised, SAME-REPO conventional-commit SCOPE holding the issue number
#   — `fix(#1042): ...` — by apexyard convention the scope IS the issue
#   number, used directly, no lookup needed.
#
#   Everything else emits NO Closes line at all:
#     - an UNSCOPED subject (`docs: ... (#1045)`) — the only "(#N)" present
#       is GitHub's squash-appended trailing PR number, which is not an
#       issue and is never resolved into one (#1076; previously resolved via
#       a best-effort `gh pr view` lookup of the PR's own body — removed
#       because that lookup could itself resolve to a WRONG close: a PR body
#       that merely *mentions* a closing keyword in prose, e.g. discussing
#       but not fixing #N, would still match)
#     - a CROSS-REPO scope (`docs(owner/repo#148): ...`) — the scope names an
#       issue in a DIFFERENT repo; a bare "Closes #148" would auto-close the
#       WRONG repo's issue #148 if this repo happens to have one too (the
#       #207 lesson, reintroduced by treating a cross-repo ref as local)
#     - a REVERT commit (`Revert "fix(#1042): ..."`) — closing the same issue
#       the reverted commit closed would re-close something the revert just
#       undid
#     - a "Merge pull request #NN from ..." merge commit whose OWN subject
#       has no scope — same unscoped rule as above
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

# ── Build the git log range ──────────────────────────────────────────────────

if [ "$PREV_TAG" = "NONE" ]; then
  LOG_RANGE="${HEAD_REF}"
else
  # AgDR-0094 (#872): prefer the RECORDED cut point over inferring one. Since
  # the fix landed, `/release` writes a `Released-From: <dev-sha>` trailer into
  # the release squash commit — that sha IS the exact dev tip the release was
  # cut from, so TRAILER..HEAD_REF is deterministic and immune to both the
  # #737 over-count and the #872 late-sync under-count (a late `/release-sync`
  # merge can no longer mis-anchor the boundary, because we're not inferring
  # it from sync-commit position anymore). Only look at PREV_TAG's own commit
  # message — that's the squash commit the trailer was written into.
  TRAILER_SHA=$(git log -1 --pretty=format:'%(trailers:key=Released-From,valueonly,separator=%x0A)' "$PREV_TAG" 2>/dev/null \
                  | tail -n 1 | tr -d '[:space:]' || true)

  if [ -n "$TRAILER_SHA" ] && git cat-file -e "${TRAILER_SHA}^{commit}" 2>/dev/null; then
    LOG_RANGE="${TRAILER_SHA}..${HEAD_REF}"
  else
    # No trailer (pre-AgDR-0094 release, or a mangled/unknown sha) — fall back
    # to the #737 sync-boundary heuristic below, unchanged.
    #
    # #737: PREV_TAG is a *squash* commit on main. Under the release-cut model
    # the individual commits it squashed live on HEAD_REF (dev) but are NOT
    # ancestors of the tag — so a naive PREV_TAG..HEAD_REF range (and even
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
    #
    # KNOWN LIMITATION this heuristic cannot fix (why AgDR-0094 exists): if the
    # matching `/release-sync` merges LATE — landing near dev's tip, after many
    # newer commits — this still anchors on that late marker and silently drops
    # everything merged before it (#872). The trailer above is the real fix;
    # this stays as the fallback for releases cut before it existed.
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
fi

# ── Expose the resolved range to the caller (#1002) ──────────────────────────
# The /release skill's count-mismatch guard used to compare the changelog's
# entry count against `git rev-list --count upstream/main..upstream/dev` —
# structurally wrong under the release-cut squash model, where main..dev never
# shrinks (see #1002). The guard should compare against the SAME range this
# script actually generated the changelog from. Printed to stderr (not
# stdout) so it never pollutes the changelog markdown callers capture.
echo "RELEASE_CHANGELOG_RANGE=${LOG_RANGE}" >&2

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

# Extract the conventional-commit SCOPE's issue ref, if any — the ONLY
# source a Closes bullet is ever derived from (#1076):
#   "fix(#1042): ..."                    -> "#1042"
#   "docs(me2resh/apexyard#148): ..."    -> "me2resh/apexyard#148"
#   anything without a `type(...):` scope at the very start -> "" (empty)
# Accepting the "owner/repo#N" shape (#1076) lets the caller recognise a
# cross-repo scope explicitly, rather than falling through to the unscoped
# path and misreading it as a bare, same-repo issue number (the #207 lesson).
#
# NB: the "no match" case is the COMMON case (most commits carry no scope at
# all), and under `set -euo pipefail` a grep pipeline that finds nothing
# exits non-zero. The trailing `|| true` is load-bearing, not decorative —
# without it, `scope_ref=$(extract_scope_ref "$subject")` at a top-level call
# site (not nested inside another function) aborts the whole script the
# first time it hits an unscoped commit, because the command substitution's
# exit status becomes the assignment's exit status under `set -e`.
extract_scope_ref() {
  local subject="$1"
  echo "$subject" \
    | grep -oE '^[a-z]+\(([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+\)!?:' \
    | grep -oE '\(([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+\)' \
    | sed -E 's/^\(//; s/\)$//' \
    || true
}

# Extract the DISPLAY ref shown in "($N) <subject>" — anchored, never "the
# first #N anywhere in the subject" (#1076). In priority order:
#   1. "Merge pull request #NNN from ..." — the number immediately following
#      that fixed phrase
#   2. a trailing "(#NNN)" at the very END of the subject — GitHub's
#      squash-merge append position
#   3. the conventional-commit SCOPE ref (extract_scope_ref), for a scoped
#      commit that carries no separate trailing squash number (e.g. a single,
#      un-squashed "fix(#1042): ..." commit) — this is DISPLAY only; it does
#      NOT change which numbers are eligible for a Closes bullet
# A "#N" appearing anywhere else in the subject (e.g. prose incidentally
# mentioning another issue, or a cross-repo "other-repo#12" reference) is
# NEVER picked up — that was the root cause of #1076's wrong-close shapes.
extract_pr_num() {
  local subject="$1"
  if echo "$subject" | grep -qE 'Merge pull request #[0-9]+'; then
    echo "$subject" | grep -oE 'Merge pull request #[0-9]+' | grep -oE '#[0-9]+' | head -1
    return
  fi
  if echo "$subject" | grep -qE '\(#[0-9]+\)$'; then
    echo "$subject" | grep -oE '\(#[0-9]+\)$' | grep -oE '#[0-9]+'
    return
  fi
  local scope_ref
  scope_ref=$(extract_scope_ref "$subject")
  if [ -n "$scope_ref" ]; then
    echo "#${scope_ref##*#}"
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

  # #1076 — a revert commit must never re-derive a Closes from the subject it
  # reverted: closing the issue the reverted commit closed would re-close
  # something the revert just undid. Detected before any Closes decision
  # below; the commit itself still gets a display entry (in whichever bucket
  # its own subject classifies into further down), it just never gets a
  # closes_num.
  is_revert=0
  if echo "$subject" | grep -qE '^Revert '; then
    is_revert=1
  fi

  pr_num=$(extract_pr_num "$subject")
  display_subject=$(strip_cc_prefix "$subject")

  # Remove trailing PR reference like "(#NNN)" from end of display subject
  display_subject=$(echo "$display_subject" | sed -E 's/ \(#[0-9]+\)$//')

  # Build the display line
  if [ -n "$pr_num" ]; then
    entry="- ($pr_num) $display_subject — $short_sha"
  else
    entry="- $display_subject — $short_sha"
  fi

  # #1076 — Closes decision. Governing rule: prefer a MISSING close over a
  # WRONG close. A Closes bullet is emitted ONLY when the subject carries a
  # recognised, SAME-REPO conventional-commit scope. Every other case —
  # unscoped, cross-repo scoped, or a revert — emits nothing.
  if [ "$is_revert" -eq 0 ]; then
    scope_ref=$(extract_scope_ref "$subject")
    if [ -n "$scope_ref" ]; then
      case "$scope_ref" in
        */*)
          # Cross-repo scope (owner/repo#N) — never emit a bare #N derived
          # from a foreign-repo reference (#207 lesson, reintroduced).
          ;;
        *)
          closes_nums+=("${scope_ref#\#}")
          ;;
      esac
    fi
    # No scope at all -> no Closes line, regardless of any trailing "(#N)"
    # squash-merge PR number — that number is a PR, not an issue, and is
    # never resolved into one anymore (#1076).
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
  # NB: `${arr[*]}` only joins on the FIRST character of IFS, even when IFS is
  # set to a multi-char string like ', ' — that dropped the space and produced
  # "2 features,13 fixes,14 improvements." on the v5.2.0 cut (#1002). Join
  # explicitly instead of relying on IFS-based array expansion.
  joined=""
  for part in "${desc_parts[@]}"; do
    if [ -z "$joined" ]; then
      joined="$part"
    else
      joined="$joined, $part"
    fi
  done
  release_desc="$bump_type — ${joined}."
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
  # #1056 — one "- Closes #N" bullet per reference, deduplicated and sorted.
  # GitHub only honours the reference IMMEDIATELY FOLLOWING a closing
  # keyword, so the old single "Closes #A, #B, #C" line auto-closed at most
  # #A — every reference after the first was silently inert. Repeating the
  # keyword (one bullet each) makes every reference its own closing directive.
  unique_nums=$(printf '%s\n' "${closes_nums[@]}" | sort -un)
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    echo "- Closes #${n}"
  done <<< "$unique_nums"
fi
